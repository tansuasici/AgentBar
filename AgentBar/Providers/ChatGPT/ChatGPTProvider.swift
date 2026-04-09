import Foundation

@MainActor @Observable
final class ChatGPTProvider: UsageProvider {
    let id = "chatgpt"
    let displayName = "ChatGPT"
    let iconSystemName = "bubble.left.and.bubble.right"

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    let loginConfig = WebLoginManager.chatGPTConfig
    let loginManager: WebLoginManager

    private var webClient: ChatGPTWebClient?

    var isConnected: Bool {
        loginManager.isConnected
    }

    init() {
        loginManager = WebLoginManager(config: WebLoginManager.chatGPTConfig)
        webClient = ChatGPTWebClient(dataStore: loginManager.dataStore)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard loginManager.isConnected else {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isRefreshing = true

        // Only show loading spinner on first fetch
        if usageData.status == .needsLogin || usageData.buckets.isEmpty {
            usageData = .loading()
        }

        let safetyTimeout = Task { @MainActor in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            if isRefreshing {
                usageData = .error(message: "Request timed out")
                isRefreshing = false
            }
        }

        do {
            guard let client = webClient else {
                usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
                isRefreshing = false
                safetyTimeout.cancel()
                return
            }

            let buckets = try await client.fetchUsage()
            usageData = LiveUsageData(buckets: buckets, status: .loaded, lastUpdated: Date())
        } catch let error as ServiceError where error == .unauthorized {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
        } catch {
            usageData = .error(message: error.localizedDescription)
        }

        safetyTimeout.cancel()
        isRefreshing = false
    }

    func startLogin() {
        loginManager.startLogin()
    }

    func disconnect() {
        webClient?.invalidate()
        loginManager.disconnect()
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }
}
