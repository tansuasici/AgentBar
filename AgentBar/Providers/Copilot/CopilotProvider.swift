import AppKit
import Foundation

@MainActor @Observable
final class CopilotProvider: UsageProvider {
    let id = "copilot"
    let displayName = "Copilot"
    let iconSystemName = "chevron.left.forwardslash.chevron.right"
    let iconAssetName: String? = "ProviderIcon-copilot"

    var usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    var isRefreshing = false

    let loginConfig = WebLoginManager.ServiceConfig(
        serviceId: "copilot",
        displayName: "GitHub Copilot",
        loginURL: URL(string: "https://github.com/settings/copilot")!,
        baseURL: "github.com",
        requiredCookies: ["user_session"],
        loggedInURLPattern: "github.com/settings",
        sessionValidationPath: nil
    )
    let loginManager: WebLoginManager

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "copilotAccessToken") }
        set { UserDefaults.standard.set(newValue, forKey: "copilotAccessToken") }
    }

    var isConnected: Bool { accessToken != nil }

    init() {
        loginManager = WebLoginManager(config: loginConfig)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let token = accessToken else {
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
            return
        }
        isRefreshing = true

        if usageData.status == .needsLogin || usageData.buckets.isEmpty {
            usageData = .loading()
        }

        do {
            let buckets = try await fetchUsage(token: token)
            usageData = LiveUsageData(buckets: buckets, status: .loaded, lastUpdated: Date())
        } catch let error as ServiceError where error == .unauthorized {
            accessToken = nil
            usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
        } catch {
            usageData = .error(message: error.localizedDescription)
        }

        isRefreshing = false
    }

    func startLogin() {
        Task { await startDeviceFlow() }
    }

    func disconnect() {
        accessToken = nil
        loginManager.disconnect()
        usageData = LiveUsageData(buckets: [], status: .needsLogin, lastUpdated: Date())
    }

    // MARK: - GitHub Device Flow

    private let clientId = "Iv1.b507a08c87ecfe98" // VS Code client ID

    private func startDeviceFlow() async {
        do {
            // Step 1: Request device code
            let codeURL = URL(string: "https://github.com/login/device/code")!
            var codeReq = URLRequest(url: codeURL)
            codeReq.httpMethod = "POST"
            codeReq.setValue("application/json", forHTTPHeaderField: "Accept")
            codeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            codeReq.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientId, "scope": "read:user"
            ])

            let (codeData, _) = try await URLSession.shared.data(for: codeReq)
            guard let codeJson = try JSONSerialization.jsonObject(with: codeData) as? [String: Any],
                  let deviceCode = codeJson["device_code"] as? String,
                  let userCode = codeJson["user_code"] as? String,
                  let verifyURL = codeJson["verification_uri"] as? String else { return }

            // Open browser for user to enter code
            if let url = URL(string: verifyURL) {
                NSWorkspace.shared.open(url)
            }

            // Copy code to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(userCode, forType: .string)

            // Step 2: Poll for token
            let interval = codeJson["interval"] as? Int ?? 5
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

                let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
                var tokenReq = URLRequest(url: tokenURL)
                tokenReq.httpMethod = "POST"
                tokenReq.setValue("application/json", forHTTPHeaderField: "Accept")
                tokenReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                tokenReq.httpBody = try JSONSerialization.data(withJSONObject: [
                    "client_id": clientId,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])

                let (tokenData, _) = try await URLSession.shared.data(for: tokenReq)
                guard let tokenJson = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any] else { continue }

                if let token = tokenJson["access_token"] as? String {
                    accessToken = token
                    await refresh()
                    return
                }

                let error = tokenJson["error"] as? String
                if error == "expired_token" || error == "access_denied" { return }
                // "authorization_pending" or "slow_down" -> keep polling
            }
        } catch {
            // Device flow failed silently
        }
    }

    // MARK: - Usage Fetch

    private func fetchUsage(token: String) async throws -> [UsageBucket] {
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse(0) }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw ServiceError.unauthorized
        default: throw ServiceError.invalidResponse(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.decodingError
        }

        return parseQuotas(json)
    }

    private func parseQuotas(_ json: [String: Any]) -> [UsageBucket] {
        var buckets: [UsageBucket] = []

        guard let snapshots = json["quota_snapshots"] as? [String: Any] else {
            return buckets
        }

        for (key, value) in snapshots.sorted(by: { $0.key < $1.key }) {
            guard let quota = value as? [String: Any] else { continue }

            let percentRemaining = quota["percent_remaining"] as? Double
                ?? {
                    guard let remaining = quota["remaining"] as? Double,
                          let entitlement = quota["entitlement"] as? Double,
                          entitlement > 0 else { return 100.0 }
                    return remaining / entitlement * 100
                }()

            let usedPercent = (100 - percentRemaining) / 100
            let label = key.replacingOccurrences(of: "_", with: " ").capitalized

            buckets.append(UsageBucket(
                label: label,
                percentUsed: min(max(usedPercent, 0), 1),
                resetText: ""
            ))
        }

        return buckets
    }
}
