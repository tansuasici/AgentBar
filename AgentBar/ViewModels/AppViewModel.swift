import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable
final class AppViewModel {
    // MARK: - Claude State
    var claudeUsageData: LiveUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isClaudeRefreshing = false
    var isClaudeDesktopInstalled = false

    // MARK: - ChatGPT State
    var chatGPTUsageData: LiveUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isChatGPTRefreshing = false

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300
    private var hasStartedAutoRefresh = false

    private let claudeWebClient = ClaudeWebClient()
    private var chatGPTWebClient: ChatGPTWebClient?

    let claudeLoginManager = WebLoginManager(config: WebLoginManager.claudeConfig)
    let chatGPTLoginManager = WebLoginManager(config: WebLoginManager.chatGPTConfig)
    let updateChecker = UpdateChecker()

    // MARK: - Launch at Login

    var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = oldValue
            }
        }
    }

    init() {
        isClaudeDesktopInstalled = ChromiumCookieReader.isClaudeDesktopInstalled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        chatGPTWebClient = ChatGPTWebClient(dataStore: chatGPTLoginManager.dataStore)
    }

    // MARK: - Auto Refresh

    func startAutoRefresh() {
        guard !hasStartedAutoRefresh else { return }
        hasStartedAutoRefresh = true

        refreshAll()
        updateChecker.checkForUpdates()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasStartedAutoRefresh = false
    }

    private func refreshAll() {
        refreshClaudeUsage()
        refreshChatGPTUsage()
    }

    // MARK: - Claude Refresh

    func refreshClaudeUsage() {
        guard !isClaudeRefreshing else { return }
        isClaudeRefreshing = true

        Task { @MainActor in
            // Only show loading spinner on first fetch
            if claudeUsageData.status == .needsLogin || claudeUsageData.buckets.isEmpty {
                claudeUsageData = .loading()
            }

            let safetyTimeout = Task { @MainActor in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                if isClaudeRefreshing {
                    claudeUsageData = .error(message: "Request timed out")
                    isClaudeRefreshing = false
                }
            }

            do {
                let buckets: [UsageBucket]

                if claudeLoginManager.isConnected,
                   let cookieHeader = await claudeLoginManager.getCookieHeader() {
                    buckets = try await claudeWebClient.fetchUsageFromWebLogin(cookieHeader: cookieHeader)
                }
                else if isClaudeDesktopInstalled {
                    buckets = try await claudeWebClient.fetchUsageFromDesktop()
                }
                else {
                    claudeUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
                    isClaudeRefreshing = false
                    safetyTimeout.cancel()
                    return
                }

                claudeUsageData = LiveUsageData(
                    buckets: buckets,
                    status: .loaded,
                    lastUpdated: Date()
                )
            } catch let error as ServiceError where error == .unauthorized {
                claudeUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            } catch {
                claudeUsageData = .error(message: error.localizedDescription)
            }

            safetyTimeout.cancel()
            isClaudeRefreshing = false
        }
    }

    // MARK: - ChatGPT Refresh

    func refreshChatGPTUsage() {
        guard !isChatGPTRefreshing else { return }
        guard chatGPTLoginManager.isConnected else {
            chatGPTUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isChatGPTRefreshing = true

        Task { @MainActor in
            // Only show loading spinner on first fetch
            if chatGPTUsageData.status == .needsLogin || chatGPTUsageData.buckets.isEmpty {
                chatGPTUsageData = .loading()
            }

            // Safety timeout: reset state after 30s even if fetch hangs
            let safetyTimeout = Task { @MainActor in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                if isChatGPTRefreshing {
                    chatGPTUsageData = .error(message: "Request timed out")
                    isChatGPTRefreshing = false
                }
            }

            do {
                guard let client = chatGPTWebClient else {
                    chatGPTUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
                    isChatGPTRefreshing = false
                    safetyTimeout.cancel()
                    return
                }

                let buckets = try await client.fetchUsage()

                chatGPTUsageData = LiveUsageData(
                    buckets: buckets,
                    status: .loaded,
                    lastUpdated: Date()
                )
            } catch let error as ServiceError where error == .unauthorized {
                chatGPTUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            } catch {
                chatGPTUsageData = .error(message: error.localizedDescription)
            }

            safetyTimeout.cancel()
            isChatGPTRefreshing = false
        }
    }

    // MARK: - Claude Login

    func startClaudeLogin() {
        claudeLoginManager.startLogin()
    }

    func onClaudeLoginCompleted() {
        claudeLoginManager.loginCompleted()
        refreshClaudeUsage()
    }

    func disconnectClaude() {
        claudeLoginManager.disconnect()
        claudeUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - ChatGPT Login

    func startChatGPTLogin() {
        chatGPTLoginManager.startLogin()
    }

    func onChatGPTLoginCompleted() {
        chatGPTLoginManager.loginCompleted()
        refreshChatGPTUsage()
    }

    func disconnectChatGPT() {
        chatGPTWebClient?.invalidate()
        chatGPTLoginManager.disconnect()
        chatGPTUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - Helpers

    var hasClaudeData: Bool {
        claudeUsageData.status == .loaded && !claudeUsageData.buckets.isEmpty
    }

    var hasChatGPTData: Bool {
        chatGPTUsageData.status == .loaded && !chatGPTUsageData.buckets.isEmpty
    }
}
