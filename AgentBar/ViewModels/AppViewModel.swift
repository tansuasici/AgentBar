import Foundation
import SwiftUI
import ServiceManagement

@MainActor @Observable
final class AppViewModel {
    // MARK: - Providers

    let providers: [any UsageProvider]

    // MARK: - Selected Provider

    @ObservationIgnored
    private var _selectedProviderId: String = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""

    var selectedProviderId: String {
        get {
            if let _ = providers.first(where: { $0.id == _selectedProviderId }) {
                return _selectedProviderId
            }
            let fallback = providers.first(where: { $0.isConnected })?.id ?? providers.first?.id ?? ""
            _selectedProviderId = fallback
            return fallback
        }
        set {
            _selectedProviderId = newValue
            UserDefaults.standard.set(newValue, forKey: "selectedProvider")
        }
    }

    var selectedProvider: (any UsageProvider)? {
        providers.first { $0.id == selectedProviderId }
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
    }

    // MARK: - Helpers

    func provider(for id: String) -> (any UsageProvider)? {
        providers.first { $0.id == id }
    }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
