import SwiftUI
import WebKit

/// A window that shows a WKWebView for the user to log in to a service.
struct WebLoginView: View {
    let config: WebLoginManager.ServiceConfig
    let loginManager: WebLoginManager
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("\(config.displayName) — Sign In")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // WebView
            WebLoginWebView(
                config: config,
                loginManager: loginManager,
                onLoginDetected: {
                    loginManager.loginCompleted(for: config.id)
                    onDismiss()
                }
            )
        }
        .frame(width: 480, height: 640)
    }
}

// MARK: - WKWebView Wrapper

struct WebLoginWebView: NSViewRepresentable {
    let config: WebLoginManager.ServiceConfig
    let loginManager: WebLoginManager
    let onLoginDetected: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = loginManager.dataStore(for: config.id)

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

        init(config: WebLoginManager.ServiceConfig, loginManager: WebLoginManager, onLoginDetected: @escaping () -> Void) {
            self.config = config
            self.loginManager = loginManager
        self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasDetectedLogin else { return }

            // Check if URL indicates successful login
            if let url = webView.url?.absoluteString,
               url.contains(config.loggedInURLPattern),
               !url.contains("login") && !url.contains("auth") {
                checkCookiesAndComplete(webView: webView)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url?.absoluteString,
               !hasDetectedLogin,
               url.contains(config.loggedInURLPattern),
               !url.contains("login") && !url.contains("auth") {
                checkCookiesAndComplete(webView: webView)
            }
            return .allow
        }

        private func checkCookiesAndComplete(webView: WKWebView) {
            Task { @MainActor in
                guard !hasDetectedLogin else { return }

                // Give a moment for cookies to settle
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                let hasSession = await loginManager.hasValidSession(for: config.id)
                if hasSession {
                    hasDetectedLogin = true
                    onLoginDetected()
                }
            }
        }
    }
}
