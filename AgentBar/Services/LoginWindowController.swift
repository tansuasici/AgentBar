import AppKit
import SwiftUI

/// Opens login views in a standalone NSWindow instead of a SwiftUI .sheet()
/// to avoid the MenuBarExtra dismiss-on-click issue.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    static let shared = LoginWindowController()

    private var windows: [String: NSWindow] = [:]
    private var onCloseCallbacks: [String: () -> Void] = [:]

    func open(
        config: WebLoginManager.ServiceConfig,
        loginManager: WebLoginManager,
        onComplete: @escaping () -> Void
    ) {
        let serviceId = config.serviceId

        // Close existing window for this service if any
        close(serviceId: serviceId)

        onCloseCallbacks[serviceId] = onComplete

        let loginView = WebLoginWebView(
            config: config,
            loginManager: loginManager,
            onLoginDetected: { [weak self] in
                loginManager.loginCompleted()
                self?.close(serviceId: serviceId)
            }
        )

        let hostingView = NSHostingView(rootView: loginView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "\(config.displayName) — Sign In"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[serviceId] = window
    }

    func close(serviceId: String) {
        windows[serviceId]?.close()
        windows.removeValue(forKey: serviceId)

        if let callback = onCloseCallbacks.removeValue(forKey: serviceId) {
            callback()
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let closingWindow = notification.object as? NSWindow else { return }
            for (serviceId, window) in windows where window === closingWindow {
                windows.removeValue(forKey: serviceId)
                if let callback = onCloseCallbacks.removeValue(forKey: serviceId) {
                    callback()
                }
                break
            }
        }
    }
}
