# AgentBar

A native macOS menu bar app that auto-detects installed AI tools and shows their usage stats with a single click.

## Features

- **Zero Configuration** — No API keys, no manual setup. Auto-detects installed AI apps.
- **Web Login** — Sign in to Claude and ChatGPT directly from AgentBar for live usage data.
- **Local-First** — Reads data from your device. No external servers, no telemetry.
- **Live Usage Bars** — See rate limit utilization, reset timers, and plan info at a glance.
- **Menu Bar Native** — Lives in your macOS menu bar, one click to open.

## Supported Apps

| App | Data Source | What You See |
|-----|-----------|-------------|
| **Claude** | Web login or Desktop cookies | 5h/7d usage %, reset timers, extra usage credits |
| **ChatGPT** | Web login or local data | Plan type, rate limit status, conversation count, last model |
| **Cursor** | Local SQLite (state.vscdb) | Plan (free/pro), subscription status, last model, email |
| **Codex** | Log file analysis | Session count, active days, auth method |

## How It Works

1. **Auto-detect**: Scans `/Applications/` for AI apps on launch
2. **Web Login** (recommended): Click "Sign in" to open a login window — cookies are stored locally
3. **Local Fallback**: Reads data from app databases, logs, and preferences when available
4. **Auto-refresh**: Updates every 5 minutes automatically

## Requirements

- macOS 14.0 (Sonoma) or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (for building from source)

## Build

```bash
# Install xcodegen if needed
brew install xcodegen

# Clone and build
git clone https://github.com/tansuasici/AgentBar.git
cd AgentBar
xcodegen generate
open AgentBar.xcodeproj
# Build & Run (Cmd+R) in Xcode
```

## Architecture

```
AgentBar/
├── AgentBarApp.swift          # Menu bar app entry point
├── Models/
│   ├── LiveUsageData.swift    # Usage buckets and status types
│   └── SubscriptionService.swift  # App detection (AppPreset enum)
├── Services/
│   ├── WebLoginManager.swift      # WKWebView-based login (primary)
│   ├── ClaudeWebClient.swift      # Claude usage API client
│   ├── ChatGPTWebClient.swift     # ChatGPT web API client
│   ├── ChatGPTLocalReader.swift   # ChatGPT local data reader
│   ├── ChromiumCookieReader.swift # Electron cookie decryption (fallback)
│   ├── CursorLocalReader.swift    # Cursor state.vscdb reader
│   └── CodexLocalReader.swift     # Codex log file analyzer
├── ViewModels/
│   └── AppViewModel.swift     # Main state management
└── Views/
    ├── MenuContentView.swift  # Menu bar popup UI
    ├── WebLoginView.swift     # WKWebView login window
    └── SettingsView.swift     # Settings (detected apps list)
```

## Privacy

All data stays on your device. AgentBar:
- Does **not** send data to any server
- Does **not** collect analytics or telemetry
- Stores login cookies locally in WKWebsiteDataStore
- Only communicates with the AI services you explicitly sign in to

## License

MIT
