import Foundation

/// Live usage data fetched from claude.ai
struct LiveUsageData: Equatable {
    let buckets: [UsageBucket]
    let status: LiveStatus
    let lastUpdated: Date

    static func loading() -> LiveUsageData {
        LiveUsageData(buckets: [], status: .loading, lastUpdated: Date())
    }

    static func error(message: String) -> LiveUsageData {
        LiveUsageData(buckets: [], status: .error(message), lastUpdated: Date())
    }
}

enum LiveStatus: Equatable {
    case loaded
    case loading
    case error(String)
    case needsLogin
}

/// A single usage bucket (e.g., "Current Session: 9%, resets in 2h 16m")
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
