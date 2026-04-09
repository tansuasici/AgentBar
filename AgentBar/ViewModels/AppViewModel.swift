import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable
final class AppViewModel {
    // MARK: - Providers

    let providers: [any UsageProvider]

    // MARK: - Selected Provider

    var selectedProviderId: String = UserDefaults.standard.string(forKey: "selectedProvider") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedProviderId, forKey: "selectedProvider")
        }
    }

    var selectedProvider: (any UsageProvider)? {
        let id = selectedProviderId
        if let match = providers.first(where: { $0.id == id }) {
            return match
        }
        // Fallback: first connected or first overall
        return providers.first(where: { $0.isConnected }) ?? providers.first
    }

    // MARK: - General State

    private var refreshTimer: Timer?
    private var hasStartedAutoRefresh = false

    private var refreshInterval: TimeInterval {
        UserDefaults.standard.double(forKey: "refreshInterval").rounded() > 0
            ? UserDefaults.standard.double(forKey: "refreshInterval")
            : 300
    }

    let updateChecker = UpdateChecker()
    let costScanner = ClaudeCodeCostScanner()

    init() {
        providers = [
            ClaudeProvider(),
            ChatGPTProvider(),
        ]
    }

    // MARK: - Auto Refresh

    func startAutoRefresh() {
        guard !hasStartedAutoRefresh else { return }
        hasStartedAutoRefresh = true

        refreshAll()
        updateChecker.checkForUpdates()
        scheduleTimer()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasStartedAutoRefresh = false
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func refreshAll() {
        for provider in providers {
            Task { await provider.refresh() }
        }
        Task { await costScanner.scan() }
    }

    // MARK: - Helpers

    func provider(for id: String) -> (any UsageProvider)? {
        providers.first { $0.id == id }
    }
}
