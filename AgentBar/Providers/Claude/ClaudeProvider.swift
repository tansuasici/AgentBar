import Foundation

@MainActor @Observable
final class ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"
    let iconSystemName = "brain.head.profile"
    let iconAssetName: String? = "ProviderIcon-claude"

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    let loginConfig = WebLoginManager.claudeConfig
    let loginManager: WebLoginManager

    private let webClient = ClaudeWebClient()
    private let isDesktopInstalled: Bool

    var isConnected: Bool {
        loginManager.isConnected || isDesktopInstalled
    }

    init() {
        loginManager = WebLoginManager(config: WebLoginManager.claudeConfig)
        isDesktopInstalled = ChromiumCookieReader.isClaudeDesktopInstalled
    }

    func refresh() async {
        guard !isRefreshing else { return }
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
            let buckets: [UsageBucket]

            if loginManager.isConnected,
               let cookieHeader = await loginManager.getCookieHeader() {
                buckets = try await webClient.fetchUsageFromWebLogin(cookieHeader: cookieHeader)
            } else if isDesktopInstalled {
                buckets = try await webClient.fetchUsageFromDesktop()
            } else {
                usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
                isRefreshing = false
                safetyTimeout.cancel()
                return
            }

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
        loginManager.disconnect()
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }
}
