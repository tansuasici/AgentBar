import Foundation

/// Fetches ChatGPT usage/account info via web API using session cookies.
struct ChatGPTWebClient {
    private let baseURL = "https://chatgpt.com"

    /// Fetch account info and conversation stats from ChatGPT web
    func fetchUsage(cookieHeader: String) async throws -> [UsageBucket] {
        guard !cookieHeader.isEmpty else {
            throw ChatGPTWebError.noCookies
        }

        var buckets: [UsageBucket] = []

        // 1. Get user info (plan, email)
        if let userInfo = try? await fetchUserInfo(cookieHeader: cookieHeader) {
            let planName = userInfo.planType.isEmpty ? "Free" : userInfo.planType.capitalized
            buckets.append(UsageBucket(
                label: "Plan: \(planName)",
                percentUsed: 0,
                resetText: userInfo.email ?? ""
            ))
        }

        // 2. Get conversation list count
        if let convInfo = try? await fetchConversationCount(cookieHeader: cookieHeader) {
            buckets.append(UsageBucket(
                label: "\(convInfo.count) conversations",
                percentUsed: 0,
                resetText: convInfo.lastModel ?? ""
            ))
        }

        if buckets.isEmpty {
            throw ChatGPTWebError.noData
        }

        return buckets
    }

    // MARK: - User Info

    private struct UserInfo {
        let email: String?
        let planType: String
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> UserInfo {
        let data = try await makeRequest(path: "/backend-api/me", cookieHeader: cookieHeader)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTWebError.noData
        }

        let email = json["email"] as? String
        let planType = json["plan_type"] as? String ?? ""

        return UserInfo(email: email, planType: planType)
    }

    // MARK: - Conversations

    private struct ConvInfo {
        let count: Int
        let lastModel: String?
    }

    private func fetchConversationCount(cookieHeader: String) async throws -> ConvInfo {
        // Get first page to know total
        let data = try await makeRequest(
            path: "/backend-api/conversations?offset=0&limit=1&order=updated",
            cookieHeader: cookieHeader
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTWebError.noData
        }

        let total = json["total"] as? Int ?? 0

        // Get most recent conversation's model
        var lastModel: String?
        if let items = json["items"] as? [[String: Any]], let first = items.first {
            // Try to get the model from the mapping
            if let mapping = first["mapping"] as? [String: Any] {
                // Find a message with model_slug
                for (_, nodeValue) in mapping {
                    if let node = nodeValue as? [String: Any],
                       let message = node["message"] as? [String: Any],
                       let metadata = message["metadata"] as? [String: Any],
                       let slug = metadata["model_slug"] as? String {
                        lastModel = slug
                        break
                    }
                }
            }
            // Fallback: check default_model_slug
            if lastModel == nil {
                lastModel = first["default_model_slug"] as? String
            }
        }

        return ConvInfo(count: total, lastModel: lastModel)
    }

    // MARK: - Network

    private func makeRequest(path: String, cookieHeader: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ChatGPTWebError.noData
        }

        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatGPTWebError.noData
        }

        switch httpResponse.statusCode {
        case 200: return data
        case 401, 403: throw ChatGPTWebError.sessionExpired
        default: throw ChatGPTWebError.serverError(httpResponse.statusCode)
        }
    }
}

enum ChatGPTWebError: LocalizedError {
    case noCookies
    case sessionExpired
    case noData
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .noCookies: "Not logged in to ChatGPT"
        case .sessionExpired: "ChatGPT session expired. Please reconnect."
        case .noData: "Could not read ChatGPT data"
        case .serverError(let code): "ChatGPT error (HTTP \(code))"
        }
    }
}
