import Foundation
import SwiftUI

@MainActor @Observable
final class AppViewModel {
    // MARK: - State
    var usageData: LiveUsageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false
    var isClaudeDesktopInstalled = false

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300

    private let claudeWebClient = ClaudeWebClient()
    let loginManager = WebLoginManager()

    init() {
        isClaudeDesktopInstalled = ChromiumCookieReader.isClaudeDesktopInstalled
    }

    // MARK: - Auto Refresh

    func startAutoRefresh() {
        refreshUsage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsage()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh Usage

    func refreshUsage() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor in
            usageData = .loading()

            do {
                let buckets: [UsageBucket]

                // Try web login cookies first (primary method)
                if loginManager.isConnected,
                   let cookieHeader = await loginManager.getCookieHeader() {
                    buckets = try await claudeWebClient.fetchUsageFromWebLogin(cookieHeader: cookieHeader)
                }
                // Fallback: read Claude Desktop cookies
                else if isClaudeDesktopInstalled {
                    buckets = try await claudeWebClient.fetchUsageFromDesktop()
                }
                else {
                    usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
                    isRefreshing = false
                    return
                }

                usageData = LiveUsageData(
                    buckets: buckets,
                    status: .loaded,
                    lastUpdated: Date()
                )
            } catch let error as ServiceError where error == .unauthorized {
                usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            } catch {
                usageData = .error(message: error.localizedDescription)
            }

            isRefreshing = false
        }
    }

    // MARK: - Login

    func startLogin() {
        loginManager.startLogin()
    }

    func onLoginCompleted() {
        loginManager.loginCompleted()
        refreshUsage()
    }

    func disconnect() {
        loginManager.disconnect()
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - Helpers

    var hasUsageData: Bool {
        usageData.status == .loaded && !usageData.buckets.isEmpty
    }
}
