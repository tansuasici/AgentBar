import Foundation

struct CostData: Equatable {
    let todayCost: Double
    let todayTokens: Int
    let last30DaysCost: Double
    let last30DaysTokens: Int
    let perModelBreakdown: [ModelCost]

    static let empty = CostData(todayCost: 0, todayTokens: 0, last30DaysCost: 0, last30DaysTokens: 0, perModelBreakdown: [])
}

struct ModelCost: Identifiable, Equatable {
    let id: String // model name
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double
}

/// Per-million-token pricing for Claude models.
enum ClaudePricing {
    struct ModelPrice {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double
        let cacheWritePerMillion: Double
    }

    static let prices: [String: ModelPrice] = [
        "claude-opus-4-6": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75),
        "claude-sonnet-4-6": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
        "claude-haiku-4-5": ModelPrice(inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.0),
        // Older model names
        "claude-sonnet-4-5-20250514": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
        "claude-3-5-sonnet-20241022": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75),
    ]

    static let fallback = ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let p = prices[model] ?? fallback
        return Double(input) / 1_000_000 * p.inputPerMillion
            + Double(output) / 1_000_000 * p.outputPerMillion
            + Double(cacheRead) / 1_000_000 * p.cacheReadPerMillion
            + Double(cacheWrite) / 1_000_000 * p.cacheWritePerMillion
    }
}
