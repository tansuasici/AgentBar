import Foundation

@MainActor
protocol UsageProvider: AnyObject, Identifiable, Observable {
    var id: String { get }
    var displayName: String { get }
    var iconSystemName: String { get }
    var iconAssetName: String? { get }
    var usageData: LiveUsageData { get }
    var isRefreshing: Bool { get }
    var isConnected: Bool { get }

    func refresh() async
    func startLogin()
    func disconnect()

    var loginConfig: WebLoginManager.ServiceConfig { get }
    var loginManager: WebLoginManager { get }

    /// If true, the provider handles its own login flow (e.g. API key dialog).
    /// If false (default), the menu bar opens a web login window.
    var handlesOwnLogin: Bool { get }
}

extension UsageProvider {
    var iconAssetName: String? { nil }
    var handlesOwnLogin: Bool { false }
}
