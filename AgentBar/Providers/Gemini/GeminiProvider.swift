import AppKit
import Foundation

@MainActor @Observable
final class GeminiProvider: UsageProvider {
    let id = "gemini"
    let displayName = "Gemini"
    let iconSystemName = "sparkles"

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    // Gemini doesn't use web login — it reads local OAuth creds from Gemini CLI
    let loginConfig = WebLoginManager.ServiceConfig(
        serviceId: "gemini",
        displayName: "Gemini",
        loginURL: URL(string: "https://gemini.google.com")!,
        baseURL: "gemini.google.com",
        requiredCookies: [],
        loggedInURLPattern: "gemini.google.com",
        sessionValidationPath: nil
    )
    let loginManager: WebLoginManager

    private let credsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.gemini/oauth_creds.json"
    }()

    var isConnected: Bool {
        FileManager.default.fileExists(atPath: credsPath)
    }

    init() {
        loginManager = WebLoginManager(config: loginConfig)
    }

    func refresh() async {
        guard !isRefreshing else { return }

        guard FileManager.default.fileExists(atPath: credsPath) else {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isRefreshing = true

        if usageData.status == .needsLogin || usageData.buckets.isEmpty {
            usageData = .loading()
        }

        do {
            let token = try readAccessToken()
            let buckets = try await fetchQuota(accessToken: token)
            usageData = LiveUsageData(buckets: buckets, status: .loaded, lastUpdated: Date())
        } catch let error as ServiceError where error == .unauthorized {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
        } catch {
            usageData = .error(message: error.localizedDescription)
        }

        isRefreshing = false
    }

    func startLogin() {
        // Gemini CLI login: open terminal instruction
        if let url = URL(string: "https://github.com/google-gemini/gemini-cli") {
            NSWorkspace.shared.open(url)
        }
    }

    func disconnect() {
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - OAuth Credentials

    private func readAccessToken() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: credsPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw ServiceError.unauthorized
        }
        return token
    }

    // MARK: - Quota API

    private func fetchQuota(accessToken: String) async throws -> [UsageBucket] {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse(0) }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw ServiceError.unauthorized
        default: throw ServiceError.invalidResponse(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBuckets = json["buckets"] as? [[String: Any]] else {
            throw ServiceError.decodingError
        }

        return parseQuotaBuckets(rawBuckets)
    }

    private func parseQuotaBuckets(_ buckets: [[String: Any]]) -> [UsageBucket] {
        // Group by model, keep lowest remainingFraction per model
        var modelQuotas: [String: (remaining: Double, resetTime: String?)] = [:]

        for bucket in buckets {
            guard let remaining = bucket["remainingFraction"] as? Double,
                  let modelId = bucket["modelId"] as? String else { continue }

            let resetTime = bucket["resetTime"] as? String
            let existing = modelQuotas[modelId]

            if existing == nil || remaining < existing!.remaining {
                modelQuotas[modelId] = (remaining, resetTime)
            }
        }

        // Classify into tiers
        var result: [UsageBucket] = []

        // Sort: Pro first, then Flash, then Flash Lite
        let sorted = modelQuotas.sorted { a, b in
            let aOrder = a.key.contains("pro") ? 0 : a.key.contains("flash-lite") ? 2 : 1
            let bOrder = b.key.contains("pro") ? 0 : b.key.contains("flash-lite") ? 2 : 1
            return aOrder < bOrder
        }

        for (model, quota) in sorted {
            let usedPercent = 1.0 - quota.remaining
            let label = shortModelName(model)
            var resetText = ""
            if let rt = quota.resetTime {
                resetText = formatResetISO(rt)
            }
            result.append(UsageBucket(label: label, percentUsed: min(max(usedPercent, 0), 1), resetText: resetText))
        }

        return result
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("pro") { return "Pro" }
        if model.contains("flash-lite") { return "Flash Lite" }
        if model.contains("flash") { return "Flash" }
        return model
    }

    private func formatResetISO(_ iso: String) -> String {
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter()
        guard let date = fmtFrac.date(from: iso) ?? fmtPlain.date(from: iso) else { return "" }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "Reset now" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }
}
