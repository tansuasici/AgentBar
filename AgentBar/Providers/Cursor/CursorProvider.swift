import Foundation

@MainActor @Observable
final class CursorProvider: UsageProvider {
    let id = "cursor"
    let displayName = "Cursor"
    let iconSystemName = "cursorarrow.rays"
    let iconAssetName: String? = "ProviderIcon-cursor"

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    let loginConfig = WebLoginManager.ServiceConfig(
        serviceId: "cursor",
        displayName: "Cursor",
        loginURL: URL(string: "https://cursor.com/settings")!,
        baseURL: "cursor.com",
        requiredCookies: ["WorkosCursorSessionToken"],
        loggedInURLPattern: "cursor.com/settings",
        sessionValidationPath: nil
    )
    let loginManager: WebLoginManager

    var isConnected: Bool { loginManager.isConnected }

    init() {
        loginManager = WebLoginManager(config: loginConfig)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard loginManager.isConnected,
              let cookieHeader = await loginManager.getCookieHeader() else {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isRefreshing = true

        if usageData.status == .needsLogin || usageData.buckets.isEmpty {
            usageData = .loading()
        }

        do {
            let buckets = try await fetchUsage(cookieHeader: cookieHeader)
            usageData = LiveUsageData(buckets: buckets, status: .loaded, lastUpdated: Date())
        } catch let error as ServiceError where error == .unauthorized {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
        } catch {
            usageData = .error(message: error.localizedDescription)
        }

        isRefreshing = false
    }

    func startLogin() { loginManager.startLogin() }
    func disconnect() {
        loginManager.disconnect()
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - Fetch

    private func fetchUsage(cookieHeader: String) async throws -> [UsageBucket] {
        let url = URL(string: "https://cursor.com/api/usage-summary")!
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse(0) }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw ServiceError.unauthorized
        case 429: throw ServiceError.rateLimited
        default: throw ServiceError.invalidResponse(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.decodingError
        }

        return parseUsageSummary(json)
    }

    private func parseUsageSummary(_ json: [String: Any]) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        // Reset time from billing cycle
        var resetText = ""
        if let cycleEnd = json["billingCycleEnd"] as? String {
            resetText = formatResetISO(cycleEnd)
        }

        // Individual usage
        if let individual = json["individualUsage"] as? [String: Any],
           let plan = individual["plan"] as? [String: Any] {

            // Total usage
            if let totalPercent = plan["totalPercentUsed"] as? Double {
                buckets.append(UsageBucket(
                    label: "Plan Usage",
                    percentUsed: min(totalPercent / 100, 1.0),
                    resetText: resetText
                ))
            } else if let used = plan["used"] as? Double, let limit = plan["limit"] as? Double, limit > 0 {
                buckets.append(UsageBucket(
                    label: "Plan Usage",
                    percentUsed: min(used / limit, 1.0),
                    resetText: resetText
                ))
            }

            // On-demand
            if let onDemand = individual["onDemand"] as? [String: Any],
               let enabled = onDemand["enabled"] as? Bool, enabled,
               let used = onDemand["used"] as? Double {
                let limit = onDemand["limit"] as? Double ?? 0
                let usedDollars = used / 100
                let label = limit > 0
                    ? String(format: "On-Demand ($%.2f/$%.2f)", usedDollars, limit / 100)
                    : String(format: "On-Demand ($%.2f)", usedDollars)
                let percent = limit > 0 ? min(used / limit, 1.0) : 0
                buckets.append(UsageBucket(label: label, percentUsed: percent, resetText: resetText))
            }
        }

        return buckets
    }

    private func formatResetISO(_ iso: String) -> String {
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter()
        guard let date = fmtFrac.date(from: iso) ?? fmtPlain.date(from: iso) else { return "" }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "Reset now" }
        let days = Int(diff) / 86400
        if days > 0 { return "Resets in \(days)d" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }
}
