import Foundation

// MARK: - App Definitions

enum AppPreset: String, CaseIterable, Identifiable, Codable, Hashable {
    case claude
    case chatgpt
    case cursor
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    var iconName: String {
        switch self {
        case .claude: "message.fill"
        case .chatgpt: "brain.head.profile"
        case .cursor: "cursorarrow.rays"
        case .codex: "terminal.fill"
        }
    }

    /// Whether local data tracking is implemented for this app
    var supportsLiveTracking: Bool {
        switch self {
        case .claude: true   // Web API via cookies
        case .chatgpt: true  // Local data (WebKit, UserDefaults, filesystem)
        case .cursor: true   // Local data (state.vscdb SQLite)
        case .codex: true    // Local data (log files)
        }
    }

    // MARK: - App Detection

    /// Check if this app is installed on the system
    var isInstalled: Bool {
        let appPath = "/Applications/\(appBundleName)"
        return FileManager.default.fileExists(atPath: appPath)
    }

    /// Check if this app has cookie data we can read
    var hasCookieData: Bool {
        guard let config = cookieConfig else { return false }
        return FileManager.default.fileExists(atPath: config.appDataDir + "/Cookies")
    }

    private var appBundleName: String {
        switch self {
        case .claude: "Claude.app"
        case .chatgpt: "ChatGPT.app"
        case .cursor: "Cursor.app"
        case .codex: "Codex.app"
        }
    }

    /// Cookie reading configuration for Electron-based apps
    var cookieConfig: ChromiumCookieReader.AppConfig? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        switch self {
        case .claude:
            return ChromiumCookieReader.AppConfig(
                appDataDir: appSupport.appendingPathComponent("Claude").path,
                keychainService: "Claude Safe Storage",
                keychainAccount: "Claude Key",
                domain: "claude.ai"
            )
        case .cursor:
            return ChromiumCookieReader.AppConfig(
                appDataDir: appSupport.appendingPathComponent("Cursor").path,
                keychainService: "Cursor Safe Storage",
                keychainAccount: "Cursor Key",
                domain: "cursor.com"
            )
        case .codex:
            return ChromiumCookieReader.AppConfig(
                appDataDir: appSupport.appendingPathComponent("Codex").path,
                keychainService: "Codex Safe Storage",
                keychainAccount: "Codex",
                domain: "codex.openai.com"
            )
        case .chatgpt:
            // ChatGPT is a native macOS app, not Electron - no cookie DB
            return nil
        }
    }

    /// Detect all installed AI apps
    static var installedApps: [AppPreset] {
        allCases.filter(\.isInstalled)
    }
}
