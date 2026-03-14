import Foundation
import Security
import CommonCrypto
import SQLite3

/// Reads and decrypts cookies from Chromium-based Electron apps (Claude Desktop, ChatGPT Desktop, etc.)
enum ChromiumCookieReader {

    struct CookieInfo {
        let name: String
        let value: String
        let domain: String
    }

    enum CookieError: LocalizedError {
        case databaseNotFound(String)
        case keychainError(String, Int32)
        case decryptionError
        case sqliteError(String)
        case noCookiesFound(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                "Cookie DB not found: \(path)"
            case .keychainError(let service, let status):
                switch status {
                case -25293: "Keychain access denied for \(service). Please click 'Always Allow' when prompted."
                case -25291: "Keychain interaction not allowed for \(service). Try opening AgentBar from Finder."
                case -25300: "Keychain item '\(service)' not found."
                default: "Keychain error for \(service) (status: \(status))"
                }
            case .decryptionError:
                "Cookie decryption failed"
            case .sqliteError(let msg):
                "SQLite: \(msg)"
            case .noCookiesFound(let domain):
                "No cookies found for \(domain)"
            }
        }
    }

    // MARK: - Key Cache (memory + disk)

    /// In-memory cache for current session
    private static var keyCache: [String: [UInt8]] = [:]

    /// UserDefaults key prefix for persisted passwords
    private static let persistPrefix = "claudebar.cookieKey."

    /// Clear all cached keys (memory + disk)
    static func clearKeyCache() {
        keyCache.removeAll()
        // Also clear persisted passwords
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(persistPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Public API

    /// Read all cookies for a domain from a Chromium-based app
    static func readCookies(
        appDataDir: String,
        keychainService: String,
        keychainAccount: String,
        domain: String
    ) throws -> [CookieInfo] {
        // 1. Find and copy cookie database (to avoid lock issues)
        let cookiePath = appDataDir + "/Cookies"
        guard FileManager.default.fileExists(atPath: cookiePath) else {
            throw CookieError.databaseNotFound(cookiePath)
        }

        let tempPath = NSTemporaryDirectory() + "claudebar_\(UUID().uuidString).db"
        try FileManager.default.copyItem(atPath: cookiePath, toPath: tempPath)
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }

        // Also copy WAL and SHM files if they exist (needed for consistent reads)
        for ext in ["-wal", "-shm"] {
            let srcPath = cookiePath + ext
            if FileManager.default.fileExists(atPath: srcPath) {
                try? FileManager.default.copyItem(atPath: srcPath, toPath: tempPath + ext)
            }
        }

        // 2. Get encryption key — from cache or Keychain (only prompts once)
        let key = try getCachedKey(service: keychainService, account: keychainAccount)

        // 3. Read and decrypt cookies
        let cookies = try readFromDatabase(path: tempPath, domain: domain, key: key)

        if cookies.isEmpty {
            throw CookieError.noCookiesFound(domain)
        }

        return cookies
    }

    // MARK: - Keychain (with cache)

    private static func getCachedKey(service: String, account: String) throws -> [UInt8] {
        let cacheKey = "\(service)|\(account)"

        // 1. In-memory cache (fastest)
        if let cached = keyCache[cacheKey] {
            return cached
        }

        // 2. Persisted password on disk (no Keychain prompt)
        let persistKey = persistPrefix + cacheKey
        if let saved = UserDefaults.standard.string(forKey: persistKey) {
            let key = deriveKey(from: saved)
            keyCache[cacheKey] = key
            return key
        }

        // 3. Last resort — Keychain (prompts ONCE ever, then persists)
        let password = try getKeychainPassword(service: service, account: account)
        let key = deriveKey(from: password)

        // Save so we never hit Keychain again
        UserDefaults.standard.set(password, forKey: persistKey)
        keyCache[cacheKey] = key
        return key
    }

    private static func getKeychainPassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw CookieError.keychainError(service, status)
        }

        return password
    }

    // MARK: - Key Derivation (PBKDF2)

    private static func deriveKey(from password: String) -> [UInt8] {
        let salt = Array("saltysalt".utf8)
        let iterations: UInt32 = 1003
        let keyLength = 16

        var derivedKey = [UInt8](repeating: 0, count: keyLength)
        let passwordData = Array(password.utf8)

        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordData, passwordData.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            iterations,
            &derivedKey, keyLength
        )

        return derivedKey
    }

    // MARK: - SQLite + Decryption

    private static func readFromDatabase(path: String, domain: String, key: [UInt8]) throws -> [CookieInfo] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieError.sqliteError("Cannot open database")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT name, encrypted_value, value FROM cookies WHERE host_key LIKE ?"
        var stmt: OpaquePointer?
        let domainPattern = "%\(domain)%"

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieError.sqliteError("Cannot prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT tells SQLite to make its own copy of the string.
        // Using nil (SQLITE_STATIC) is UNSAFE because Swift's implicit String→C
        // bridging creates a temporary buffer that's freed after the call returns.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, domainPattern, -1, SQLITE_TRANSIENT)

        var cookies: [CookieInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)

            // Try encrypted value first
            let encLen = sqlite3_column_bytes(stmt, 1)
            if encLen > 3, let encBlob = sqlite3_column_blob(stmt, 1) {
                let encData = Data(bytes: encBlob, count: Int(encLen))

                if let decrypted = decrypt(data: encData, key: key) {
                    cookies.append(CookieInfo(name: name, value: decrypted, domain: domain))
                    continue
                }
            }

            // Fallback: try plaintext value
            if let valuePtr = sqlite3_column_text(stmt, 2) {
                let value = String(cString: valuePtr)
                if !value.isEmpty {
                    cookies.append(CookieInfo(name: name, value: value, domain: domain))
                }
            }
        }

        return cookies
    }

    // MARK: - AES-128-CBC Decryption

    private static func decrypt(data: Data, key: [UInt8]) -> String? {
        // Chromium encrypted cookie format (macOS):
        // - First 3 bytes: version prefix "v10" or "v11"
        // - Remaining bytes: AES-128-CBC encrypted data
        // - IV: 16 bytes of 0x20 (spaces)
        // - Key: PBKDF2(keychain_password, "saltysalt", 1003, SHA1, 16)
        //
        // The decrypted plaintext has a 32-byte binary prefix
        // (Chromium's cookie binding metadata - ties ciphertext to
        // domain/name for integrity). The actual cookie value starts
        // at byte 32 of the decrypted output.

        guard data.count > 3 else { return nil }

        let prefix = data.prefix(3)
        let prefixStr = String(data: prefix, encoding: .utf8) ?? ""

        guard prefixStr == "v10" || prefixStr == "v11" else { return nil }

        let encrypted = data.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)

        var decrypted = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let status = encrypted.withUnsafeBytes { encryptedBytes in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key, key.count,
                iv,
                encryptedBytes.baseAddress, encrypted.count,
                &decrypted, decrypted.count,
                &decryptedLength
            )
        }

        guard status == kCCSuccess else { return nil }

        // Skip 32-byte Chromium cookie binding prefix to get actual value
        let metadataPrefixLength = 32
        guard decryptedLength > metadataPrefixLength else { return nil }

        let valueData = Data(decrypted[metadataPrefixLength..<decryptedLength])
        return String(data: valueData, encoding: .utf8)
    }
}

// MARK: - App-Specific Presets

extension ChromiumCookieReader {

    struct AppConfig {
        let appDataDir: String
        let keychainService: String
        let keychainAccount: String
        let domain: String
    }

    static var claudeDesktopConfig: AppConfig {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return AppConfig(
            appDataDir: appSupport.appendingPathComponent("Claude").path,
            keychainService: "Claude Safe Storage",
            keychainAccount: "Claude Key",
            domain: "claude.ai"
        )
    }

    /// Read Claude Desktop cookies automatically
    static func readClaudeDesktopCookies() throws -> [CookieInfo] {
        let config = claudeDesktopConfig
        return try readCookies(
            appDataDir: config.appDataDir,
            keychainService: config.keychainService,
            keychainAccount: config.keychainAccount,
            domain: config.domain
        )
    }

    /// Check if Claude Desktop is installed
    static var isClaudeDesktopInstalled: Bool {
        let config = claudeDesktopConfig
        return FileManager.default.fileExists(atPath: config.appDataDir + "/Cookies")
    }
}
