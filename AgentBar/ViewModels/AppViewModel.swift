import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable
final class AppViewModel {
    // MARK: - Providers

    let providers: [any UsageProvider]

    // MARK: - General State

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300
    private var hasStartedAutoRefresh = false

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
        providers = [
            ClaudeProvider(),
            ChatGPTProvider(),
        ]
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        for provider in providers {
            Task { await provider.refresh() }
        }
    }

    // MARK: - Helpers

    func provider(for id: String) -> (any UsageProvider)? {
        providers.first { $0.id == id }
    }
}
