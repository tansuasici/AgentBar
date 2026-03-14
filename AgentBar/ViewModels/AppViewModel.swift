import Foundation
import SwiftUI

@MainActor @Observable
final class AppViewModel {
    // MARK: - State
    var detectedApps: [AppPreset] = []
    var usageMap: [AppPreset: LiveUsageData] = [:]
    var isRefreshing = false

    // Web login manager (shared with views)
    let loginManager = WebLoginManager()

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

    private let claudeWebClient = ClaudeWebClient()
    private let chatgptWebClient = ChatGPTWebClient()

    init() {
        detectApps()
    }

    // MARK: - App Detection

    func detectApps() {
        var apps = AppPreset.installedApps

        // Also include web-connected services even if desktop app not installed
        for serviceId in loginManager.connectedServices {
            if let preset = AppPreset(rawValue: serviceId), !apps.contains(preset) {
                apps.append(preset)
            }
        }

        detectedApps = apps
    }

    // MARK: - Auto Refresh

    func startAutoRefresh() {
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh All

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true

        detectApps()

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for app in detectedApps {
                    group.addTask {
                        await self.refreshApp(app)
                    }
                }
            }
            isRefreshing = false
        }
    }

    // MARK: - Per-App Refresh

    func refreshApp(_ app: AppPreset) async {
        await MainActor.run {
            usageMap[app] = LiveUsageData.loading(app: app)
        }

        do {
            let buckets: [UsageBucket]

            switch app {
            case .claude:
                buckets = try await fetchClaude()

            case .chatgpt:
                buckets = try await fetchChatGPT()

            case .cursor:
                let data = try CursorLocalReader.readLocalData()
                buckets = CursorLocalReader.toBuckets(data)

            case .codex:
                let data = try CodexLocalReader.readLocalData()
                buckets = CodexLocalReader.toBuckets(data)
            }

            await MainActor.run {
                usageMap[app] = LiveUsageData(
                    app: app,
                    buckets: buckets,
                    status: .loaded,
                    lastUpdated: Date()
                )
            }
        } catch {
            await MainActor.run {
                usageMap[app] = LiveUsageData.error(
                    app: app,
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Claude

    private func fetchClaude() async throws -> [UsageBucket] {
        // Primary: web login cookies (no Keychain needed)
        if loginManager.connectedServices.contains("claude") {
            if let cookieHeader = await loginManager.getCookieHeader(for: "claude") {
                do {
                    return try await claudeWebClient.fetchUsageFromWebLogin(cookieHeader: cookieHeader)
                } catch {
                    // If session expired, clear connection
                    if case ServiceError.unauthorized = error {
                        await MainActor.run { loginManager.disconnect(serviceId: "claude") }
                    }
                    throw error
                }
            }
        }

        // Fallback: desktop app cookie (if Claude Desktop installed)
        return try await claudeWebClient.fetchUsageFromDesktop()
    }

    // MARK: - ChatGPT

    private func fetchChatGPT() async throws -> [UsageBucket] {
        // Primary: web login cookies
        if loginManager.connectedServices.contains("chatgpt") {
            if let cookieHeader = await loginManager.getCookieHeader(for: "chatgpt") {
                do {
                    return try await chatgptWebClient.fetchUsage(cookieHeader: cookieHeader)
                } catch {
                    if case ChatGPTWebError.sessionExpired = error {
                        await MainActor.run { loginManager.disconnect(serviceId: "chatgpt") }
                    }
                    throw error
                }
            }
        }

        // Fallback: local data from ChatGPT.app
        let data = try ChatGPTLocalReader.readLocalData()
        return ChatGPTLocalReader.toBuckets(data)
    }

    // MARK: - Helpers

    func usage(for app: AppPreset) -> LiveUsageData? {
        usageMap[app]
    }

    func isConnected(_ app: AppPreset) -> Bool {
        loginManager.connectedServices.contains(app.rawValue)
    }

    var hasAnyDetected: Bool {
        !detectedApps.isEmpty
    }

    var lastRefreshText: String {
        let dates = usageMap.values.map(\.lastUpdated)
        guard let latest = dates.max() else { return "Never" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: latest, relativeTo: Date())
    }
}
