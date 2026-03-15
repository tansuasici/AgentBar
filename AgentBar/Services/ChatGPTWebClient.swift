import Foundation
import WebKit

/// Fetches ChatGPT usage via the /backend-api/wham/usage endpoint.
/// Uses a hidden WKWebView with the shared WKWebsiteDataStore to run fetch()
/// in the same browser context as the login session (bypasses Cloudflare).
@MainActor
final class ChatGPTWebClient: NSObject {
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private var isReady = false

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        super.init()
    }

    // MARK: - Public API

    /// Fetch ChatGPT usage buckets from the wham/usage endpoint.
    func fetchUsage() async throws -> [UsageBucket] {
        let wv = try await getReadyWebView()

        // Use callAsyncJavaScript — it properly handles await / Promises
        // (evaluateJavaScript returns WKError code 5 for Promise results)
        let js = """
        try {
            const authResp = await fetch('/api/auth/session', { credentials: 'include' });
            if (!authResp.ok) return JSON.stringify({ error: 'auth', status: authResp.status });
            const auth = await authResp.json();
            if (!auth.accessToken) return JSON.stringify({ error: 'no_token' });

            const resp = await fetch('/backend-api/wham/usage', {
                headers: {
                    'Authorization': 'Bearer ' + auth.accessToken,
                    'Content-Type': 'application/json'
                },
                credentials: 'include'
            });
            if (!resp.ok) return JSON.stringify({ error: 'usage', status: resp.status });
            const data = await resp.json();
            return JSON.stringify({ ok: true, data: data });
        } catch(e) {
            return JSON.stringify({ error: 'exception', message: e.message });
        }
        """

        let result = try await wv.callAsyncJavaScript(
            js, arguments: [:], contentWorld: .page
        )

        guard let jsonString = result as? String,
              let jsonData = jsonString.data(using: .utf8) else {
            throw ServiceError.decodingError
        }

        guard let response = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ServiceError.decodingError
        }

        // Handle errors
        if let error = response["error"] as? String {
            switch error {
            case "auth", "no_token":
                invalidate()
                throw ServiceError.unauthorized
            case "usage":
                let status = response["status"] as? Int ?? 0
                if status == 401 || status == 403 {
                    invalidate()
                    throw ServiceError.unauthorized
                }
                throw ServiceError.invalidResponse(status)
            default:
                throw ServiceError.decodingError
            }
        }

        guard response["ok"] as? Bool == true,
              let data = response["data"] else {
            throw ServiceError.decodingError
        }

        return parseWhamUsage(data)
    }

    /// Reset state (call on disconnect or auth failure).
    func invalidate() {
        webView?.stopLoading()
        webView = nil
        isReady = false
    }

    // MARK: - Hidden WKWebView

    private func getReadyWebView() async throws -> WKWebView {
        if let wv = webView, isReady { return wv }

        webView?.stopLoading()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.webView = wv

        // Load minimal HTML with chatgpt.com as base URL.
        // This sets the security origin so fetch() calls carry the right cookies
        // without loading the full React SPA.
        let html = "<!DOCTYPE html><html><head></head><body></body></html>"
        try await loadHTML(wv, html: html, baseURL: URL(string: "https://chatgpt.com")!)

        isReady = true
        return wv
    }

    /// Load HTML in the web view and wait for didFinish.
    private func loadHTML(_ wv: WKWebView, html: String, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let handler = OneTimeNavigationDelegate(continuation: continuation)
            wv.navigationDelegate = handler
            objc_setAssociatedObject(wv, &ChatGPTKeys.navDelegate, handler, .OBJC_ASSOCIATION_RETAIN)
            wv.loadHTMLString(html, baseURL: baseURL)
        }
    }

    // MARK: - Parse /backend-api/wham/usage Response

    private func parseWhamUsage(_ rawData: Any) -> [UsageBucket] {
        guard let data = rawData as? [String: Any] else {
            // Maybe array of rate limits
            if let array = rawData as? [[String: Any]] {
                return array.compactMap { parseBucket(from: $0) }
            }
            return []
        }

        var buckets: [UsageBucket] = []

        // Shape 1: { rate_limits: [ { ... }, ... ] }
        if let rateLimits = data["rate_limits"] as? [[String: Any]] {
            buckets = rateLimits.compactMap { parseBucket(from: $0) }
        }
        // Shape 2: { rate_limit: { primary_window: { ... }, secondary_window: { ... } } }
        else if let rateLimit = data["rate_limit"] as? [String: Any] {
            if let pw = rateLimit["primary_window"] as? [String: Any],
               let b = parseBucket(from: pw, fallbackLabel: "Current Session") { buckets.append(b) }
            if let sw = rateLimit["secondary_window"] as? [String: Any],
               let b = parseBucket(from: sw, fallbackLabel: "Weekly") { buckets.append(b) }
        }
        // Shape 3: flat { used_percent: N, ... }
        else if let b = parseBucket(from: data) {
            buckets.append(b)
        }
        // Shape 4: nested objects keyed by name
        else {
            for (key, value) in data.sorted(by: { $0.key < $1.key }) {
                if let nested = value as? [String: Any],
                   let b = parseBucket(from: nested, fallbackLabel: prettify(key)) {
                    buckets.append(b)
                }
            }
        }

        return buckets
    }

    private func parseBucket(from dict: [String: Any], fallbackLabel: String? = nil) -> UsageBucket? {
        let percent: Double

        if let used = dict["used_percent"] as? Double {
            percent = used > 1 ? used / 100 : used
        } else if let remaining = dict["remaining_percent"] as? Double {
            let r = remaining > 1 ? remaining / 100 : remaining
            percent = 1 - r
        } else if let used = dict["usage"] as? Double, let limit = dict["limit"] as? Double, limit > 0 {
            percent = min(used / limit, 1)
        } else {
            return nil
        }

        let label = (dict["name"] as? String)
            ?? (dict["model"] as? String)
            ?? (dict["label"] as? String)
            ?? (dict["window_name"] as? String)
            ?? fallbackLabel
            ?? "ChatGPT"

        var resetText = ""
        // reset_at can be a Unix timestamp (Int/Double) or ISO 8601 string
        if let ts = (dict["reset_at"] ?? dict["resets_at"]) as? Double {
            resetText = formatReset(Date(timeIntervalSince1970: ts))
        } else if let ts = (dict["reset_at"] ?? dict["resets_at"]) as? Int {
            resetText = formatReset(Date(timeIntervalSince1970: Double(ts)))
        } else if let iso = (dict["reset_at"] ?? dict["resets_at"]) as? String {
            resetText = formatISO(iso)
        } else if let secs = dict["reset_seconds"] as? Double {
            resetText = formatReset(Date().addingTimeInterval(secs))
        }

        return UsageBucket(
            label: label,
            percentUsed: min(max(percent, 0), 1),
            resetText: resetText
        )
    }

    // MARK: - Formatting

    private func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatISO(_ iso: String) -> String {
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter()
        guard let date = fmtFrac.date(from: iso) ?? fmtPlain.date(from: iso) else { return "" }
        return formatReset(date)
    }

    private func formatReset(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "Reset now" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "Resets in \(h)h \(m)m" }
        return "Resets in \(m)m"
    }
}

// MARK: - One-shot Navigation Delegate

private enum ChatGPTKeys { nonisolated(unsafe) static var navDelegate = 0 }

private final class OneTimeNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
