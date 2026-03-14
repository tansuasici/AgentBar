import Foundation
import SQLite3

/// Reads local data from ChatGPT.app (native macOS app using WKWebView)
/// Data sources:
/// - WebKit LocalStorage (account type, cap status)
/// - UserDefaults (model info, settings)
/// - Filesystem (conversation count)
enum ChatGPTLocalReader {

    struct LocalData {
        let accountType: String    // "personal", "plus", "team", etc.
        let capExpiresAt: String?  // ISO date when rate limit cap expires (nil = no cap)
        let lastModel: String?     // e.g., "gpt-5-4-thinking"
        let conversationCount: Int
    }

    enum ReadError: LocalizedError {
        case appNotInstalled
        case localStorageNotFound
        case sqliteError(String)

        var errorDescription: String? {
            switch self {
            case .appNotInstalled: "ChatGPT not installed"
            case .localStorageNotFound: "ChatGPT local data not found. Open ChatGPT once first."
            case .sqliteError(let msg): "ChatGPT data error: \(msg)"
            }
        }
    }

    // MARK: - Public API

    static func readLocalData() throws -> LocalData {
        guard FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") else {
            throw ReadError.appNotInstalled
        }

        let account = readAccountType() ?? "unknown"
        let capExpiry = readCapExpiresAt()
        let lastModel = readLastUsedModel()
        let convCount = countConversations()

        return LocalData(
            accountType: account,
            capExpiresAt: capExpiry,
            lastModel: lastModel,
            conversationCount: convCount
        )
    }

    /// Convert local data to usage buckets for display
    static func toBuckets(_ data: LocalData) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        // Account plan
        let planLabel = data.accountType == "personal" ? "Plus" : data.accountType.capitalized
        buckets.append(UsageBucket(
            label: "Plan: \(planLabel)",
            percentUsed: 0,
            resetText: ""
        ))

        // Rate limit cap status
        if let capExpiry = data.capExpiresAt, !capExpiry.isEmpty {
            let resetText = formatCapExpiry(capExpiry)
            buckets.append(UsageBucket(
                label: "Rate Limited",
                percentUsed: 1.0,
                resetText: resetText
            ))
        } else {
            buckets.append(UsageBucket(
                label: "Rate Limit",
                percentUsed: 0,
                resetText: "No cap active"
            ))
        }

        // Conversation count
        if data.conversationCount > 0 {
            buckets.append(UsageBucket(
                label: "\(data.conversationCount) conversations",
                percentUsed: 0,
                resetText: data.lastModel ?? ""
            ))
        }

        return buckets
    }

    // MARK: - WebKit LocalStorage

    /// Find the LocalStorage SQLite database for ChatGPT
    private static func findLocalStorageDB() -> String? {
        let webkitBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/com.openai.chat/WebsiteData/Default")
            .path

        guard FileManager.default.fileExists(atPath: webkitBase) else { return nil }

        // The path has two hash directories before LocalStorage
        // Search recursively for localstorage.sqlite3
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: webkitBase),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "localstorage.sqlite3" {
                return url.path
            }
        }

        return nil
    }

    /// Read a UTF-16LE encoded value from WebKit LocalStorage
    private static func readLocalStorageValue(key: String) -> String? {
        guard let dbPath = findLocalStorageDB() else { return nil }

        // Copy to avoid lock issues
        let tempPath = NSTemporaryDirectory() + "agentbar_chatgpt_\(UUID().uuidString).db"
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath)
            for ext in ["-wal", "-shm"] {
                let src = dbPath + ext
                if FileManager.default.fileExists(atPath: src) {
                    try? FileManager.default.copyItem(atPath: src, toPath: tempPath + ext)
                }
            }
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // WebKit LocalStorage values are UTF-16LE encoded BLOBs
        let blobLen = sqlite3_column_bytes(stmt, 0)
        guard blobLen > 0, let blob = sqlite3_column_blob(stmt, 0) else { return nil }

        let data = Data(bytes: blob, count: Int(blobLen))
        return String(data: data, encoding: .utf16LittleEndian)
    }

    // MARK: - Data Extraction

    private static func readAccountType() -> String? {
        guard let value = readLocalStorageValue(key: "_account") else { return nil }
        // Value is JSON string like "personal" (with quotes)
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readCapExpiresAt() -> String? {
        guard let value = readLocalStorageValue(key: "oai/apps/capExpiresAt") else { return nil }
        // Value is JSON: {"state":{"isoDate":"2026-03-15T12:00:00Z"},"version":0}
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? [String: Any],
              let isoDate = state["isoDate"] as? String,
              !isoDate.isEmpty else {
            return nil
        }
        return isoDate
    }

    private static func readLastUsedModel() -> String? {
        // Read from UserDefaults
        guard let defaults = UserDefaults(suiteName: "com.openai.chat") else { return nil }
        let keys = defaults.dictionaryRepresentation().keys
        guard let settingsKey = keys.first(where: { $0.hasPrefix("lastAccountSettingsResponse_") }) else {
            return nil
        }

        guard let jsonString = defaults.string(forKey: settingsKey),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["settings"] as? [String: Any],
              let modelConfig = settings["lastUsedModelConfig"] as? [String: Any],
              let slugs = modelConfig["slugs"] as? [String: Any] else {
            return nil
        }

        // Prefer macosApp slug, then default
        return slugs["macosApp"] as? String ?? slugs["default"] as? String
    }

    private static func countConversations() -> Int {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.openai.chat")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var count = 0
        for dir in contents where dir.lastPathComponent.hasPrefix("conversations-v") {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                count += files.filter { $0.pathExtension == "data" }.count
            }
        }

        return count
    }

    // MARK: - Formatting

    private static func formatCapExpiry(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: isoString) else { return isoString }

        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return "Cap expired" }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        if hours > 0 {
            return "Cap resets in \(hours)h \(minutes)m"
        }
        return "Cap resets in \(minutes)m"
    }
}
