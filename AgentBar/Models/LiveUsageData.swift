import Foundation

/// Live usage data fetched from a detected app
struct LiveUsageData: Equatable {
    let app: AppPreset
    let buckets: [UsageBucket]
    let status: LiveStatus
    let lastUpdated: Date

    static func loading(app: AppPreset) -> LiveUsageData {
        LiveUsageData(app: app, buckets: [], status: .loading, lastUpdated: Date())
    }

    static func error(app: AppPreset, message: String) -> LiveUsageData {
        LiveUsageData(app: app, buckets: [], status: .error(message), lastUpdated: Date())
    }

    static func notSupported(app: AppPreset) -> LiveUsageData {
        LiveUsageData(app: app, buckets: [], status: .notSupported, lastUpdated: Date())
    }
}

enum LiveStatus: Equatable {
    case loaded
    case loading
    case error(String)
    case notSupported
}

/// A single usage bucket (e.g., "5-Hour Window: 44% used, resets in 2h 16m")
struct UsageBucket: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let percentUsed: Double // 0.0 to 1.0
    let resetText: String

    static func == (lhs: UsageBucket, rhs: UsageBucket) -> Bool {
        lhs.label == rhs.label &&
        lhs.percentUsed == rhs.percentUsed &&
        lhs.resetText == rhs.resetText
    }
}
