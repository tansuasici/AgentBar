import Foundation
import SwiftUI

@Observable
final class AppViewModel {
    // MARK: - Detected Apps
    var detectedApps: [AppPreset] = []
    var usageMap: [AppPreset: LiveUsageData] = [:]
    var isRefreshing = false

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

    private let claudeWebClient = ClaudeWebClient()

    init() {
        detectApps()
    }

    // MARK: - App Detection

    func detectApps() {
        detectedApps = AppPreset.installedApps
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

        // Re-detect apps on each refresh
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
                // Claude uses web API with auto-read cookies
                buckets = try await claudeWebClient.fetchUsageFromDesktop()

            case .chatgpt:
                // ChatGPT reads local data (WebKit, UserDefaults, filesystem)
                let data = try ChatGPTLocalReader.readLocalData()
                buckets = ChatGPTLocalReader.toBuckets(data)

            case .cursor:
                // Cursor reads from state.vscdb SQLite
                let data = try CursorLocalReader.readLocalData()
                buckets = CursorLocalReader.toBuckets(data)

            case .codex:
                // Codex reads from log files
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

    func usage(for app: AppPreset) -> LiveUsageData? {
        usageMap[app]
    }

    // MARK: - Computed

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
