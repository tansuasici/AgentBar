import Foundation
import WebKit

/// Manages web-based login for AI services (Claude, ChatGPT, etc.)
/// Uses a persistent WKWebsiteDataStore so cookies survive app restarts.
@MainActor @Observable
final class WebLoginManager: NSObject {

    // MARK: - Service Config

    struct ServiceConfig {
        let serviceId: String
        let displayName: String
        let loginURL: URL
        let baseURL: String
        let requiredCookies: [String]
        let loggedInURLPattern: String
        /// If set, an HTTP GET to this path must return 200 before login is confirmed.
        /// Prevents false positives from auth-flow redirects.
        let sessionValidationPath: String?
    }

    static let claudeConfig = ServiceConfig(
        serviceId: "claude",
        displayName: "Claude",
        loginURL: URL(string: "https://claude.ai/login")!,
        baseURL: "https://claude.ai",
        requiredCookies: ["sessionKey"],
        loggedInURLPattern: "claude.ai/new",
        sessionValidationPath: nil
    )

    static let chatGPTConfig = ServiceConfig(
        serviceId: "chatgpt",
        displayName: "ChatGPT",
        loginURL: URL(string: "https://chatgpt.com/auth/login")!,
        baseURL: "https://chatgpt.com",
        requiredCookies: ["__Secure-next-auth.session-token"],
        loggedInURLPattern: "chatgpt.com",
        sessionValidationPath: "/api/auth/session"
    )

    // MARK: - State

    let config: ServiceConfig
    var isConnected = false
    var isLoginWindowOpen = false

    // MARK: - Persistent Data Store

    private var _dataStore: WKWebsiteDataStore?

    init(config: ServiceConfig = WebLoginManager.claudeConfig) {
        self.config = config
        super.init()
        loadConnectedState()
    }

    var dataStore: WKWebsiteDataStore {
        if let existing = _dataStore {
            return existing
        }

        let store: WKWebsiteDataStore
        if #available(macOS 14.0, *) {
            let uuid = serviceUUID()
            store = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            store = .default()
        }

        _dataStore = store
        return store
    }

    private func serviceUUID() -> UUID {
        let key = "agentbar.weblogin.uuid.\(config.serviceId)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: saved) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }

    // MARK: - Login Flow

    func startLogin() {
        isLoginWindowOpen = true
    }

    func loginCompleted() {
        isConnected = true
        saveConnectedState()
        isLoginWindowOpen = false
    }

    func disconnect() {
        isConnected = false
        saveConnectedState()

        let store = dataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
        _dataStore = nil
    }

    // MARK: - Cookie Extraction

    func getCookieHeader() async -> String? {
        let store = dataStore
        let cookies = await store.httpCookieStore.allCookies()

        guard let baseURL = URL(string: config.baseURL),
              let domain = baseURL.host else { return nil }

        let relevant = cookies.filter { cookie in
            domain.hasSuffix(cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain)
                || cookie.domain.hasSuffix(domain)
        }

        if relevant.isEmpty { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func hasValidSession() async -> Bool {
        let store = dataStore
        let cookies = await store.httpCookieStore.allCookies()

        for requiredName in config.requiredCookies {
            // Use hasPrefix to match chunked cookies
            // e.g. __Secure-next-auth.session-token.0, .1, .2
            let found = cookies.contains { $0.name.hasPrefix(requiredName) && !$0.value.isEmpty }
            if found { return true }
        }
        return false
    }

    // MARK: - Persistence

    private func saveConnectedState() {
        UserDefaults.standard.set(isConnected, forKey: "agentbar.isConnected.\(config.serviceId)")
    }

    private func loadConnectedState() {
        // Migrate old key if exists
        let oldKey = "claudebar.isConnected"
        let newKey = "agentbar.isConnected.\(config.serviceId)"
        if config.serviceId == "claude",
           UserDefaults.standard.object(forKey: newKey) == nil,
           UserDefaults.standard.object(forKey: oldKey) != nil {
            UserDefaults.standard.set(UserDefaults.standard.bool(forKey: oldKey), forKey: newKey)
        }
        isConnected = UserDefaults.standard.bool(forKey: newKey)
    }
}
