import Foundation
import WebKit

/// Manages web-based login sessions for AI services.
/// Each service gets its own persistent WKWebsiteDataStore so cookies survive app restarts.
@MainActor @Observable
final class WebLoginManager: NSObject {

    // MARK: - Service Definition

    struct ServiceConfig: Identifiable {
        let id: String          // e.g., "claude"
        let displayName: String // e.g., "Claude"
        let loginURL: URL
        let baseURL: String     // e.g., "https://claude.ai"
        let requiredCookies: [String]  // cookies that indicate successful login
        let loggedInURLPattern: String // URL pattern that means login succeeded
    }

    static let services: [ServiceConfig] = [
        ServiceConfig(
            id: "claude",
            displayName: "Claude",
            loginURL: URL(string: "https://claude.ai/login")!,
            baseURL: "https://claude.ai",
            requiredCookies: ["sessionKey"],
            loggedInURLPattern: "claude.ai/new"
        ),
        ServiceConfig(
            id: "chatgpt",
            displayName: "ChatGPT",
            loginURL: URL(string: "https://chatgpt.com/auth/login")!,
            baseURL: "https://chatgpt.com",
            requiredCookies: ["__Secure-next-auth.session-token"],
            loggedInURLPattern: "chatgpt.com"
        ),
    ]

    // MARK: - State

    var connectedServices: Set<String> = []
    var isLoginWindowOpen = false
    var currentLoginService: ServiceConfig?

    // MARK: - Persistent Data Stores (one per service)

    private var dataStores: [String: WKWebsiteDataStore] = [:]

    override init() {
        super.init()
        loadConnectedServices()
    }

    // MARK: - Data Store

    /// Get or create a persistent data store for a service.
    /// Each service uses a unique identifier so cookies don't clash.
    func dataStore(for serviceId: String) -> WKWebsiteDataStore {
        if let existing = dataStores[serviceId] {
            return existing
        }

        // Create a persistent store with a unique identifier
        let store: WKWebsiteDataStore
        if #available(macOS 14.0, *) {
            let uuid = serviceUUID(for: serviceId)
            store = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            store = .default()
        }

        dataStores[serviceId] = store
        return store
    }

    /// Deterministic UUID per service so the same store is reused across launches
    private func serviceUUID(for serviceId: String) -> UUID {
        let key = "agentbar.weblogin.uuid.\(serviceId)"
        if let saved = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: saved) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }

    // MARK: - Login Flow

    func startLogin(for serviceId: String) {
        guard let config = Self.services.first(where: { $0.id == serviceId }) else { return }
        currentLoginService = config
        isLoginWindowOpen = true
    }

    func loginCompleted(for serviceId: String) {
        connectedServices.insert(serviceId)
        saveConnectedServices()
        isLoginWindowOpen = false
        currentLoginService = nil
    }

    func disconnect(serviceId: String) {
        connectedServices.remove(serviceId)
        saveConnectedServices()

        // Clear cookies for this service
        let store = dataStore(for: serviceId)
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
        dataStores.removeValue(forKey: serviceId)
    }

    // MARK: - Cookie Extraction

    /// Get cookies for API calls to a service
    func getCookieHeader(for serviceId: String) async -> String? {
        guard let config = Self.services.first(where: { $0.id == serviceId }) else { return nil }

        let store = dataStore(for: serviceId)
        let cookies = await store.httpCookieStore.allCookies()

        guard let baseURL = URL(string: config.baseURL) else { return nil }

        let relevant = cookies.filter { cookie in
            guard let domain = baseURL.host else { return false }
            return domain.hasSuffix(cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain)
                || cookie.domain.hasSuffix(domain)
        }

        if relevant.isEmpty { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Check if we have valid cookies for a service
    func hasValidSession(for serviceId: String) async -> Bool {
        guard let config = Self.services.first(where: { $0.id == serviceId }) else { return false }

        let store = dataStore(for: serviceId)
        let cookies = await store.httpCookieStore.allCookies()

        for requiredName in config.requiredCookies {
            let found = cookies.contains { $0.name == requiredName && !$0.value.isEmpty }
            if found { return true }
        }
        return false
    }

    // MARK: - Persistence

    private func saveConnectedServices() {
        UserDefaults.standard.set(Array(connectedServices), forKey: "agentbar.connectedServices")
    }

    private func loadConnectedServices() {
        if let saved = UserDefaults.standard.stringArray(forKey: "agentbar.connectedServices") {
            connectedServices = Set(saved)
        }
    }
}
