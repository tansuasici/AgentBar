import Foundation

/// Client that estimates ChatGPT usage by counting messages from conversation history.
/// Since ChatGPT has no usage endpoint, we:
/// 1. Exchange session cookie for a JWT access token
/// 2. Fetch recent conversations from the backend API
/// 3. Count assistant messages grouped by model_slug within rate limit windows
/// 4. Compare against known Plus-tier limits
struct ChatGPTWebClient {
    private let baseURL = "https://chatgpt.com"

    // MARK: - Rate Limit Rules (Plus tier, approximate)

    struct RateRule {
        let modelPrefixes: [String]
        let label: String
        let maxMessages: Int
        let windowSeconds: TimeInterval
    }

    // These limits are approximate and change frequently.
    // Source: OpenAI help articles + community reports (March 2026)
    static let plusRules: [RateRule] = [
        RateRule(
            modelPrefixes: ["gpt-4o", "gpt-5"],
            label: "GPT-4o / 5",
            maxMessages: 160,
            windowSeconds: 3 * 3600 // 3 hours
        ),
        RateRule(
            modelPrefixes: ["gpt-4.1"],
            label: "GPT-4.1",
            maxMessages: 40,
            windowSeconds: 3 * 3600 // 3 hours
        ),
        RateRule(
            modelPrefixes: ["o3"],
            label: "o3",
            maxMessages: 100,
            windowSeconds: 7 * 24 * 3600 // 1 week
        ),
        RateRule(
            modelPrefixes: ["o4-mini"],
            label: "o4-mini",
            maxMessages: 300,
            windowSeconds: 24 * 3600 // 1 day
        ),
    ]

    // MARK: - Public API

    /// Fetch ChatGPT usage by counting messages from conversation history.
    func fetchUsage(cookieHeader: String) async throws -> [UsageBucket] {
        let accessToken = try await getAccessToken(cookieHeader: cookieHeader)
        let conversations = try await fetchRecentConversations(accessToken: accessToken)
        let messages = try await collectMessages(from: conversations, accessToken: accessToken)
        return buildBuckets(from: messages)
    }

    // MARK: - Access Token

    /// Exchange session cookie for JWT access token via /api/auth/session
    private func getAccessToken(cookieHeader: String) async throws -> String {
        guard let url = URL(string: baseURL + "/api/auth/session") else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse(0)
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401, 403: throw ServiceError.unauthorized
        default: throw ServiceError.invalidResponse(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String else {
            throw ServiceError.unauthorized
        }

        return accessToken
    }

    // MARK: - Conversations List

    private func fetchRecentConversations(accessToken: String) async throws -> [[String: Any]] {
        let data = try await makeAuthRequest(
            path: "/backend-api/conversations?offset=0&limit=50&order=updated",
            accessToken: accessToken
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw ServiceError.decodingError
        }

        // Filter to conversations updated within the widest window (7 days)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return items.filter { conv in
            if let updateTime = conv["update_time"] as? Double {
                return Date(timeIntervalSince1970: updateTime) > cutoff
            }
            return false
        }
    }

    // MARK: - Message Collection

    /// A timestamped message with its model slug.
    struct TimestampedMessage {
        let date: Date
        let modelSlug: String
    }

    /// Fetch messages from individual conversations (parallel, max 20).
    private func collectMessages(
        from conversations: [[String: Any]],
        accessToken: String
    ) async throws -> [TimestampedMessage] {
        let toFetch = Array(conversations.prefix(20))

        return try await withThrowingTaskGroup(of: [TimestampedMessage].self) { group in
            for conv in toFetch {
                guard let convId = conv["id"] as? String else { continue }
                group.addTask {
                    try await self.fetchConversationMessages(id: convId, accessToken: accessToken)
                }
            }

            var allMessages: [TimestampedMessage] = []
            for try await batch in group {
                allMessages.append(contentsOf: batch)
            }
            return allMessages
        }
    }

    /// Parse messages from a single conversation's mapping tree.
    /// Counts assistant messages (each one = 1 user turn).
    private func fetchConversationMessages(
        id: String,
        accessToken: String
    ) async throws -> [TimestampedMessage] {
        let data = try await makeAuthRequest(
            path: "/backend-api/conversation/\(id)",
            accessToken: accessToken
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mapping = json["mapping"] as? [String: Any] else {
            return []
        }

        var messages: [TimestampedMessage] = []

        for (_, nodeValue) in mapping {
            guard let node = nodeValue as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  author["role"] as? String == "assistant",
                  let metadata = message["metadata"] as? [String: Any],
                  let modelSlug = metadata["model_slug"] as? String,
                  !modelSlug.isEmpty else {
                continue
            }

            // Use create_time if available, fall back to conversation update_time
            let timestamp: Date
            if let createTime = message["create_time"] as? Double, createTime > 0 {
                timestamp = Date(timeIntervalSince1970: createTime)
            } else {
                continue
            }

            messages.append(TimestampedMessage(date: timestamp, modelSlug: modelSlug))
        }

        return messages
    }

    // MARK: - Build Buckets

    /// Map counted messages to UsageBuckets using rate limit rules.
    private func buildBuckets(from messages: [TimestampedMessage]) -> [UsageBucket] {
        let now = Date()
        var buckets: [UsageBucket] = []

        for rule in Self.plusRules {
            let windowStart = now.addingTimeInterval(-rule.windowSeconds)

            // Count messages matching this rule's model prefixes within the window
            let count = messages.filter { msg in
                msg.date > windowStart && rule.modelPrefixes.contains(where: { msg.modelSlug.hasPrefix($0) })
            }.count

            guard count > 0 else { continue }

            let percent = min(Double(count) / Double(rule.maxMessages), 1.0)

            // Calculate reset time: when the oldest matching message falls outside the window
            let matchingDates = messages
                .filter { msg in
                    msg.date > windowStart && rule.modelPrefixes.contains(where: { msg.modelSlug.hasPrefix($0) })
                }
                .map(\.date)
                .sorted()

            var resetText = ""
            if let oldest = matchingDates.first {
                let resetDate = oldest.addingTimeInterval(rule.windowSeconds)
                resetText = formatResetDate(resetDate)
            }

            buckets.append(UsageBucket(
                label: "\(rule.label) (\(count)/\(rule.maxMessages))",
                percentUsed: percent,
                resetText: resetText
            ))
        }

        // Also show any models not covered by rules (informational, no limit)
        let knownPrefixes = Self.plusRules.flatMap(\.modelPrefixes)
        let unknownMessages = messages.filter { msg in
            !knownPrefixes.contains(where: { msg.modelSlug.hasPrefix($0) })
        }

        // Group unknown messages by slug
        let unknownGrouped = Dictionary(grouping: unknownMessages, by: \.modelSlug)
        for (slug, msgs) in unknownGrouped.sorted(by: { $0.value.count > $1.value.count }) {
            // Skip mini models (usually fallback, not rate-limited separately in a meaningful way)
            if slug.hasSuffix("-mini") { continue }

            let count = msgs.count
            guard count > 0 else { continue }

            let label = slug.replacingOccurrences(of: "-", with: " ").capitalized
            buckets.append(UsageBucket(
                label: "\(label) (\(count) msgs)",
                percentUsed: 0, // No known limit
                resetText: "7d window"
            ))
        }

        return buckets
    }

    // MARK: - Date Formatting

    private func formatResetDate(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)

        if diff <= 0 { return "Reset now" }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if hours > 24 {
            let days = hours / 24
            return "Resets in \(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    // MARK: - Network

    private func makeAuthRequest(path: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "oai-device-id")
        request.setValue("en-US", forHTTPHeaderField: "oai-language")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse(0)
        }

        switch httpResponse.statusCode {
        case 200: return data
        case 401, 403: throw ServiceError.unauthorized
        case 429: throw ServiceError.rateLimited
        default: throw ServiceError.invalidResponse(httpResponse.statusCode)
        }
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
