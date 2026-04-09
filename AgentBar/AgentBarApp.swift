import SwiftUI

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.startAutoRefresh()
                }
        } label: {
            MenuBarIconView(providers: viewModel.providers)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shortcut = GlobalShortcut()

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcut.register { [weak self] in
            self?.toggleMenuBarPanel()
        }
    }

    private func toggleMenuBarPanel() {
        // Find the AgentBar status item and simulate a click
        guard let button = NSApp.windows
            .compactMap({ $0.value(forKey: "statusItem") as? NSStatusItem })
            .first?.button else {
            // Fallback: find status item via the status bar
            if let button = findStatusButton() {
                button.performClick(nil)
            }
            return
        }
        button.performClick(nil)
    }

    private func findStatusButton() -> NSStatusBarButton? {
        // Walk all windows to find the MenuBarExtra's status button
        for window in NSApp.windows {
            if let item = window.value(forKey: "_statusItem") as? NSStatusItem {
                return item.button
            }
        }
        return nil
    }
}
