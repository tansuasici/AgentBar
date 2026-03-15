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
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        let request = URLRequest(url: config.loginURL)
        webView.load(request)

        // Store reference for polling
        context.coordinator.webView = webView

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config, loginManager: loginManager, onLoginDetected: onLoginDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let config: WebLoginManager.ServiceConfig
        let loginManager: WebLoginManager
        let onLoginDetected: () -> Void
        weak var webView: WKWebView?
        private var hasDetectedLogin = false
        private var pollTimer: Timer?
        private var initialLoadDone = false

        init(config: WebLoginManager.ServiceConfig, loginManager: WebLoginManager, onLoginDetected: @escaping () -> Void) {
            self.config = config
            self.loginManager = loginManager
            self.onLoginDetected = onLoginDetected
            super.init()
            startPolling()
        }

        deinit {
            pollTimer?.invalidate()
        }

        // MARK: - Polling

        private func startPolling() {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.pollForLogin()
            }
        }

        private func pollForLogin() {
            guard !hasDetectedLogin, initialLoadDone else { return }
            // Only poll when the WKWebView is on the service's own domain.
            // During OAuth (auth0.openai.com, accounts.google.com, etc.) skip.
            guard let currentURL = webView?.url?.absoluteString,
                  isLoggedInURL(currentURL) else { return }
            checkLogin()
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !initialLoadDone {
                initialLoadDone = true
                return
            }
            guard !hasDetectedLogin else { return }

            if let url = webView.url?.absoluteString, isLoggedInURL(url) {
                checkLogin()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            .allow
        }

        // MARK: - WKUIDelegate

        /// Handle popups (window.open / target="_blank") by loading in the same webView.
        /// OAuth providers (Google, Apple, etc.) often open in a new window.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - Login Detection

        private func isLoggedInURL(_ url: String) -> Bool {
            url.contains(config.loggedInURLPattern)
                && !url.contains("login")
                && !url.contains("auth")
        }

        private func checkLogin() {
            Task { @MainActor in
                guard !hasDetectedLogin else { return }

                // For services with a session validation path (e.g. ChatGPT),
                // use JS fetch() directly — more reliable than cookie name checks.
                if config.sessionValidationPath != nil {
                    let isValid = await validateSessionViaJS()
                    guard isValid else { return }
                } else {
                    let hasSession = await loginManager.hasValidSession()
                    guard hasSession else { return }
                }
                hasDetectedLogin = true
                pollTimer?.invalidate()
                onLoginDetected()
            }
        }

        /// Validate the session by running fetch() inside the WKWebView.
        /// This avoids Cloudflare blocking (same browser context, same cookies).
        @MainActor
        private func validateSessionViaJS() async -> Bool {
            guard let webView, let path = config.sessionValidationPath else { return false }

            // Use callAsyncJavaScript — it properly handles await / Promises
            // (evaluateJavaScript cannot return Promise results)
            //
            // ChatGPT's /api/auth/session always returns JSON (e.g. {"expires":"..."})
            // even when NOT logged in. We must check for "accessToken" which only
            // exists when the user has an active session.
            let js = """
            try {
                const r = await fetch(path, { credentials: 'include' });
                if (!r.ok) return 'fail';
                const text = await r.text();
                if (!text || text === '{}' || text === '') return 'fail';
                const j = JSON.parse(text);
                if (!j) return 'fail';
                // ChatGPT: accessToken is the definitive sign of a logged-in session.
                // Generic: fall back to checking for user object or non-trivial keys.
                if (j.accessToken) return 'ok';
                if (j.user && typeof j.user === 'object') return 'ok';
                return 'fail';
            } catch(e) { return 'fail'; }
            """

            do {
                let result = try await webView.callAsyncJavaScript(
                    js, arguments: ["path": path], contentWorld: .page
                )
                return (result as? String) == "ok"
            } catch {
                return false
            }
        }
    }
}
