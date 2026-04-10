import AppKit
import Foundation

@MainActor @Observable
final class ZaiProvider: UsageProvider {
    let id = "zai"
    let displayName = "z.ai"
    let iconSystemName = "globe.asia.australia.fill"
    let iconAssetName: String? = "ProviderIcon-zai"
    let handlesOwnLogin = true

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    let loginConfig = WebLoginManager.ServiceConfig(
        serviceId: "zai",
        displayName: "z.ai",
        loginURL: URL(string: "https://open.bigmodel.cn")!,
        baseURL: "open.bigmodel.cn",
        requiredCookies: [],
        loggedInURLPattern: "open.bigmodel.cn",
        sessionValidationPath: nil
    )
    let loginManager: WebLoginManager

    private var apiKey: String? {
        get {
            UserDefaults.standard.string(forKey: "zaiAPIKey")
                ?? ProcessInfo.processInfo.environment["Z_AI_API_KEY"]
        }
        set { UserDefaults.standard.set(newValue, forKey: "zaiAPIKey") }
    }

    var isConnected: Bool { apiKey != nil && !(apiKey?.isEmpty ?? true) }

    init() {
        loginManager = WebLoginManager(config: loginConfig)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let key = apiKey, !key.isEmpty else {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isRefreshing = true

        if usageData.status == .needsLogin || usageData.buckets.isEmpty {
            usageData = .loading()
        }

        do {
            let buckets = try await fetchQuota(apiKey: key)
            usageData = LiveUsageData(buckets: buckets, status: .loaded, lastUpdated: Date())
        } catch let error as ServiceError where error == .unauthorized {
            apiKey = nil
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
        } catch {
            usageData = .error(message: error.localizedDescription)
        }

        isRefreshing = false
    }

    func startLogin() {
        APIKeyDialogHelper.showDialog(
            title: "z.ai API Key",
            message: "Enter your z.ai (Zhipu GLM) API key.",
            consoleURL: URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        ) { [weak self] key in
            guard let self, let key else { return }
            self.apiKey = key
            Task { await self.refresh() }
        }
    }

    func disconnect() {
        apiKey = nil
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - Quota API

    /// Resolves the API host. Priority: Z_AI_QUOTA_URL > Z_AI_API_HOST > default (api.z.ai).
    private var quotaURL: URL {
        let env = ProcessInfo.processInfo.environment

        // Full URL override
        if let raw = env["Z_AI_QUOTA_URL"],
           let url = URL(string: raw), url.scheme != nil {
            return url
        }

        // Host-only override
        let host: String
        if let override = env["Z_AI_API_HOST"], !override.isEmpty {
            host = override
        } else {
            host = "api.z.ai"
        }

        let base = host.hasPrefix("http") ? host : "https://\(host)"
        return URL(string: base)!.appendingPathComponent("api/monitor/usage/quota/limit")
    }

    private func fetchQuota(apiKey: String) async throws -> [UsageBucket] {
        var request = URLRequest(url: quotaURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse(0) }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw ServiceError.unauthorized
        default: throw ServiceError.invalidResponse(http.statusCode)
        }

        // Guard against empty body (can happen with wrong region/proxy).
        guard !data.isEmpty else {
            throw ServiceError.decodingError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let payload = json["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else {
            throw ServiceError.decodingError
        }

        // Plan name: try multiple possible keys (planName, plan, plan_type, packageName)
        let planName: String? = {
            for key in ["planName", "plan", "plan_type", "packageName"] {
                if let val = payload[key] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                    return val.trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }()

        return parseLimits(limits, planName: planName)
    }

    // MARK: - Response Parsing

    private func parseLimits(_ limits: [[String: Any]], planName: String?) -> [UsageBucket] {
        var tokenLimits: [(entry: [String: Any], windowMinutes: Int)] = []
        var timeLimit: [String: Any]?

        for entry in limits {
            let type = entry["type"] as? String ?? ""
            if type == "TOKENS_LIMIT" {
                let minutes = windowMinutes(for: entry)
                tokenLimits.append((entry, minutes))
            } else if type == "TIME_LIMIT" {
                timeLimit = entry
            }
        }

        // Sort by window size (shortest first).
        // Multiple TOKENS_LIMIT: longest → primary, shortest → secondary (CodexBar convention).
        tokenLimits.sort { $0.windowMinutes < $1.windowMinutes }

        var buckets: [UsageBucket] = []

        // Primary token limit (longest window)
        if let primary = tokenLimits.last {
            let bucket = makeBucket(from: primary.entry, label: windowLabel(for: primary.entry, planName: planName))
            buckets.append(bucket)
        }

        // Secondary / session token limit (shortest window, if different from primary)
        if tokenLimits.count >= 2, let secondary = tokenLimits.first {
            let bucket = makeBucket(from: secondary.entry, label: windowLabel(for: secondary.entry, planName: nil))
            buckets.append(bucket)
        }

        // Time/MCP limit
        if let time = timeLimit {
            let bucket = makeBucket(from: time, label: "MCP Usage")
            buckets.append(bucket)
        }

        return buckets
    }

    private func makeBucket(from entry: [String: Any], label: String) -> UsageBucket {
        let percent = usedPercent(for: entry)
        let resetText = formatResetTime(entry["nextResetTime"])
        return UsageBucket(label: label, percentUsed: percent, resetText: resetText)
    }

    /// Computes used percentage matching CodexBar's logic:
    /// prefer max(usage - remaining, currentValue), fallback to percentage field.
    private func usedPercent(for entry: [String: Any]) -> Double {
        let total = (entry["usage"] as? Double) ?? (entry["usage"] as? Int).map(Double.init)
        let remaining = (entry["remaining"] as? Double) ?? (entry["remaining"] as? Int).map(Double.init)
        let currentValue = (entry["currentValue"] as? Double) ?? (entry["currentValue"] as? Int).map(Double.init)

        guard let total, total > 0 else {
            // No total — fallback to percentage field (0-100)
            if let pct = (entry["percentage"] as? Double) ?? (entry["percentage"] as? Int).map(Double.init) {
                return min(max(pct / 100.0, 0), 1)
            }
            return 0
        }

        // Compute used from both sources and take the max (most conservative).
        var usedRaw: Double?
        if let remaining {
            let fromRemaining = total - remaining
            if let currentValue {
                usedRaw = max(fromRemaining, currentValue)
            } else {
                usedRaw = fromRemaining
            }
        } else if let currentValue {
            usedRaw = currentValue
        }

        guard let usedRaw else {
            if let pct = (entry["percentage"] as? Double) ?? (entry["percentage"] as? Int).map(Double.init) {
                return min(max(pct / 100.0, 0), 1)
            }
            return 0
        }

        let clamped = max(0, min(total, usedRaw))
        return clamped / total
    }

    // MARK: - Window Helpers

    private func windowMinutes(for entry: [String: Any]) -> Int {
        let unit = entry["unit"] as? Int ?? 0
        let number = entry["number"] as? Int ?? 0
        switch unit {
        case 5: return number               // minutes
        case 3: return number * 60          // hours
        case 1: return number * 24 * 60    // days
        case 6: return number * 7 * 24 * 60 // weeks
        default: return number
        }
    }

    private func windowLabel(for entry: [String: Any], planName: String?) -> String {
        let unit = entry["unit"] as? Int ?? 0
        let number = entry["number"] as? Int ?? 0
        let prefix = planName.map { "\($0) — " } ?? ""

        switch unit {
        case 5: return "\(prefix)\(number)m window"
        case 3: return "\(prefix)\(number)h window"
        case 1: return "\(prefix)\(number)d window"
        case 6: return "\(prefix)\(number)w window"
        default: return "\(prefix)Usage"
        }
    }

    private func formatResetTime(_ value: Any?) -> String {
        // nextResetTime can arrive as Int or Double (epoch milliseconds)
        let ms: Double?
        if let d = value as? Double { ms = d }
        else if let i = value as? Int { ms = Double(i) }
        else { return "" }

        guard let ms else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "Reset now" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }
}
