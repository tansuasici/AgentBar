import Foundation

/// Client that fetches usage data from claude.ai.
/// Supports two auth methods:
/// 1. Web login via WKWebView (primary — no Keychain needed)
/// 2. Desktop cookie auto-read (fallback — requires Keychain access)
struct ClaudeWebClient {
    private let baseURL = "https://claude.ai"

    /// Fetch usage using web login cookies (primary method)
    func fetchUsageFromWebLogin(cookieHeader: String) async throws -> [UsageBucket] {
        guard !cookieHeader.isEmpty else {
            throw ClaudeError.noCookies
        }

        let orgId = try await fetchOrganizationId(cookieHeader: cookieHeader)
        return try await fetchUsage(orgId: orgId, cookieHeader: cookieHeader)
    }

    /// Fetch usage by auto-reading cookies from Claude Desktop (fallback)
    func fetchUsageFromDesktop() async throws -> [UsageBucket] {
        guard ChromiumCookieReader.isClaudeDesktopInstalled else {
            throw ClaudeError.appNotInstalled
        }

        let cookies = try ChromiumCookieReader.readClaudeDesktopCookies()
        let cookieHeader = buildCookieHeader(from: cookies)

        guard !cookieHeader.isEmpty else {
            throw ClaudeError.noCookies
        }

        let orgId = try await fetchOrganizationId(cookieHeader: cookieHeader)
        return try await fetchUsage(orgId: orgId, cookieHeader: cookieHeader)
    }

    // MARK: - Organization

    private func fetchOrganizationId(cookieHeader: String) async throws -> String {
        // First try to get orgId from lastActiveOrg cookie
        if let orgId = extractCookieValue(named: "lastActiveOrg", from: cookieHeader), !orgId.isEmpty {
            return orgId
        }

        // Fallback: call the API
        let data = try await makeRequest(path: "/api/organizations", cookieHeader: cookieHeader)

        guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstOrg = orgs.first,
              let uuid = firstOrg["uuid"] as? String else {
            throw ServiceError.decodingError
        }

        return uuid
    }

    // MARK: - Usage Fetch

    private func fetchUsage(orgId: String, cookieHeader: String) async throws -> [UsageBucket] {
        // Primary: /api/organizations/{orgId}/usage
        // Returns: { "five_hour": { "utilization": 44.0, "resets_at": "..." }, "seven_day": {...}, ... }
        let data = try await makeRequest(
            path: "/api/organizations/\(orgId)/usage",
            cookieHeader: cookieHeader
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.decodingError
        }

        return parseUsageResponse(json)
    }

    // MARK: - Response Parsing

    /// Parse the /api/organizations/{orgId}/usage response
    /// Format:
    /// {
    ///   "five_hour": { "utilization": 44.0, "resets_at": "2026-03-14T17:00:00+00:00" },
    ///   "seven_day": { "utilization": 23.0, "resets_at": "2026-03-20T13:00:00+00:00" },
    ///   "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
    ///   "seven_day_opus": null,
    ///   "seven_day_cowork": null,
    ///   "extra_usage": { "is_enabled": true, "monthly_limit": 5000, "used_credits": 0.0, "utilization": null }
    /// }
    private func parseUsageResponse(_ json: [String: Any]) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        // Known usage window keys and their display labels
        let usageWindows: [(key: String, label: String)] = [
            ("five_hour", "5-Hour Window"),
            ("seven_day", "7-Day - All Models"),
            ("seven_day_sonnet", "7-Day - Sonnet"),
            ("seven_day_opus", "7-Day - Opus"),
            ("seven_day_cowork", "7-Day - Cowork"),
        ]

        for window in usageWindows {
            guard let windowData = json[window.key] as? [String: Any] else { continue }

            let utilization = windowData["utilization"] as? Double ?? 0
            let percent = min(utilization / 100.0, 1.0)

            var resetText = ""
            if let resetsAt = windowData["resets_at"] as? String {
                resetText = formatResetDate(resetsAt)
            }

            buckets.append(UsageBucket(
                label: window.label,
                percentUsed: percent,
                resetText: resetText
            ))
        }

        // Handle extra_usage (overage/extended usage)
        if let extraUsage = json["extra_usage"] as? [String: Any],
           let isEnabled = extraUsage["is_enabled"] as? Bool, isEnabled {
            let monthlyLimitCents = extraUsage["monthly_limit"] as? Double ?? 0
            let usedCreditsCents = extraUsage["used_credits"] as? Double ?? 0
            let monthlyLimit = monthlyLimitCents / 100.0
            let usedCredits = usedCreditsCents / 100.0

            if monthlyLimit > 0 {
                let percent = min(usedCreditsCents / monthlyLimitCents, 1.0)
                let formatUsed = usedCredits.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "$%.0f", usedCredits)
                    : String(format: "$%.2f", usedCredits)
                let formatLimit = monthlyLimit.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "$%.0f", monthlyLimit)
                    : String(format: "$%.2f", monthlyLimit)
                let label = "Extra Usage (\(formatUsed)/\(formatLimit))"
                buckets.append(UsageBucket(
                    label: label,
                    percentUsed: percent,
                    resetText: "Monthly"
                ))
            }
        }

        // Also handle any unknown keys that have utilization data
        let knownKeys = Set(usageWindows.map(\.key) + ["extra_usage", "iguana_necktie", "seven_day_oauth_apps"])
        for (key, value) in json {
            guard !knownKeys.contains(key),
                  let windowData = value as? [String: Any],
                  let utilization = windowData["utilization"] as? Double else { continue }

            let label = key.replacingOccurrences(of: "_", with: " ").capitalized
            let percent = min(utilization / 100.0, 1.0)

            var resetText = ""
            if let resetsAt = windowData["resets_at"] as? String {
                resetText = formatResetDate(resetsAt)
            }

            buckets.append(UsageBucket(
                label: label,
                percentUsed: percent,
                resetText: resetText
            ))
        }

        return buckets
    }

    // MARK: - Cookie Helpers

    private func buildCookieHeader(from cookies: [ChromiumCookieReader.CookieInfo]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func extractCookieValue(named name: String, from cookieHeader: String) -> String? {
        let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == name {
                return String(parts[1])
            }
        }
        return nil
    }

    // MARK: - Date Formatting

    private func formatResetDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: isoString) {
            return formatResetDateObj(date)
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            return formatResetDateObj(date)
        }

        return isoString
    }

    private func formatResetDateObj(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)

        if diff <= 0 { return "Reset now" }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if hours > 24 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE h:mm a"
            return "Resets \(dayFormatter.string(from: date))"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    // MARK: - Network

    private func makeRequest(path: String, cookieHeader: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
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
}

// MARK: - Claude-specific errors

enum ClaudeError: LocalizedError {
    case appNotInstalled
    case noCookies

    var errorDescription: String? {
        switch self {
        case .appNotInstalled: "Claude Desktop not installed"
        case .noCookies: "No session found in Claude Desktop"
        }
    }
}

// MARK: - Network errors

enum ServiceError: LocalizedError {
    case invalidURL
    case invalidResponse(Int)
    case unauthorized
    case rateLimited
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .invalidResponse(let code): "Server error (HTTP \(code))"
        case .unauthorized: "Session expired. Reopen Claude Desktop."
        case .rateLimited: "Rate limited. Try again later."
        case .decodingError: "Could not read response data"
        }
    }
}
