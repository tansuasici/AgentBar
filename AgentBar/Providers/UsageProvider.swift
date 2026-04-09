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
}

extension UsageProvider {
    var iconAssetName: String? { nil }
}
