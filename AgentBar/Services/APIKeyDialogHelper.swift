import AppKit

/// Shows a modal dialog for entering an API key.
@MainActor
enum APIKeyDialogHelper {
    static func showDialog(
        title: String,
        message: String,
        consoleURL: URL? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: consoleURL != nil ? 54 : 24))

        let textField = NSSecureTextField(frame: NSRect(x: 0, y: consoleURL != nil ? 30 : 0, width: 320, height: 24))
        textField.placeholderString = "Paste your API key here"
        container.addSubview(textField)

        if let consoleURL {
            let linkButton = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
            linkButton.title = "Get your API key →"
            linkButton.bezelStyle = .inline
            linkButton.isBordered = false
            linkButton.font = NSFont.systemFont(ofSize: 11)
            linkButton.contentTintColor = .linkColor
            linkButton.target = URLOpener.shared
            linkButton.action = #selector(URLOpener.openURL(_:))
            URLOpener.shared.pendingURL = consoleURL
            container.addSubview(linkButton)
        }

        alert.accessoryView = container
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(key.isEmpty ? nil : key)
        } else {
            completion(nil)
        }
    }
}

/// Helper to open URLs from NSButton targets.
private class URLOpener: NSObject {
    static let shared = URLOpener()
    var pendingURL: URL?

    @objc func openURL(_ sender: Any?) {
        if let url = pendingURL {
            NSWorkspace.shared.open(url)
        }
    }
}
