import SwiftUI
import WebKit

// MARK: - WKWebView Wrapper

/// Embeddable WKWebView that detects login completion for AI services.
/// Used by LoginWindowController in a standalone NSWindow.
struct WebLoginWebView: NSViewRepresentable {
    let config: WebLoginManager.ServiceConfig
    let loginManager: WebLoginManager
    let onLoginDetected: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = loginManager.dataStore

        let webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        let request = URLRequest(url: config.loginURL)
        webView.load(request)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config, loginManager: loginManager, onLoginDetected: onLoginDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let config: WebLoginManager.ServiceConfig
        let loginManager: WebLoginManager
        let onLoginDetected: () -> Void
        private var hasDetectedLogin = false
        /// Number of main-frame navigations seen (skip the first one to avoid
        /// false positives from the initial auth→main-page redirect).
        private var mainFrameNavigationCount = 0

        init(config: WebLoginManager.ServiceConfig, loginManager: WebLoginManager, onLoginDetected: @escaping () -> Void) {
            self.config = config
            self.loginManager = loginManager
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasDetectedLogin else { return }
            mainFrameNavigationCount += 1

            if let url = webView.url?.absoluteString,
               isLoggedInURL(url) {
                checkCookiesAndComplete()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true else {
                return .allow
            }
            return .allow
        }

        /// Check if the URL looks like a logged-in page.
        private func isLoggedInURL(_ url: String) -> Bool {
            guard url.contains(config.loggedInURLPattern),
                  !url.contains("login"),
                  !url.contains("auth") else {
                return false
            }

            // Skip the very first navigation (initial redirect from /auth/login → /)
            // For services with API validation, the API call is the real gate.
            if config.sessionValidationPath != nil && mainFrameNavigationCount <= 1 {
                return false
            }

            return true
        }

        private func checkCookiesAndComplete() {
            Task { @MainActor in
                guard !hasDetectedLogin else { return }

                // Wait for cookies to settle
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                let hasSession = await loginManager.hasValidSession()
                guard hasSession else { return }

                // If the service requires API validation, verify the session is real
                if let validationPath = config.sessionValidationPath {
                    guard let cookieHeader = await loginManager.getCookieHeader() else { return }
                    let isValid = await validateSessionWithAPI(
                        cookieHeader: cookieHeader,
                        baseURL: config.baseURL,
                        path: validationPath
                    )
                    guard isValid else { return }
                }

                hasDetectedLogin = true
                onLoginDetected()
            }
        }

        /// Call the session API to verify the login is real (not just a redirect cookie).
        private func validateSessionWithAPI(cookieHeader: String, baseURL: String, path: String) async -> Bool {
            guard let url = URL(string: baseURL + path) else { return false }

            var request = URLRequest(url: url)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 10

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["accessToken"] != nil else {
                return false
            }

            return true
        }
    }
}
