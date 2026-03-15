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

        // Start polling for login (handles SPA route changes that don't trigger didFinish)
        context.coordinator.startPolling()

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
        private var pollTimer: Timer?
        /// Set to true after the initial page finishes loading (avoids false positive on first redirect)
        private var initialLoadDone = false

        init(config: WebLoginManager.ServiceConfig, loginManager: WebLoginManager, onLoginDetected: @escaping () -> Void) {
            self.config = config
            self.loginManager = loginManager
            self.onLoginDetected = onLoginDetected
        }

        deinit {
            pollTimer?.invalidate()
        }

        // MARK: - Polling (primary detection for SPAs like ChatGPT)

        func startPolling() {
            // Poll every 3 seconds to check if the user has logged in.
            // This handles SPA client-side navigations that don't trigger didFinish.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.pollForLogin()
            }
        }

        private func pollForLogin() {
            guard !hasDetectedLogin, initialLoadDone else { return }
            checkCookiesAndComplete()
        }

        // MARK: - WKNavigationDelegate (fast path for full navigations)

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !initialLoadDone {
                initialLoadDone = true
                return // Skip the first load (auth page itself)
            }

            guard !hasDetectedLogin else { return }

            if let url = webView.url?.absoluteString,
               isLoggedInURL(url) {
                checkCookiesAndComplete()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            .allow
        }

        // MARK: - Login Detection

        private func isLoggedInURL(_ url: String) -> Bool {
            url.contains(config.loggedInURLPattern)
                && !url.contains("login")
                && !url.contains("auth")
        }

        private func checkCookiesAndComplete() {
            Task { @MainActor in
                guard !hasDetectedLogin else { return }

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
                pollTimer?.invalidate()
                onLoginDetected()
            }
        }

        /// Call the session API to verify the login is real.
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
