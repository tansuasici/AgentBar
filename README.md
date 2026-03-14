# AgentBar

A native macOS menu bar app that shows your **Claude usage & rate limits** at a glance.

## Features

- **Claude Rate Limits** — Current session %, weekly limits (all models + per-model), and extra usage credits.
- **Zero Configuration** — Sign in once, see your usage instantly.
- **Menu Bar Native** — Lives in your macOS menu bar, one click to open.
- **Auto-Refresh** — Updates automatically every few minutes.
- **Local-First** — All data stays on your device. No servers, no telemetry.

## Install

Download the latest DMG from [Releases](https://github.com/tansuasici/ClaudeBar/releases), open it, and drag AgentBar to Applications.

## Build from Source

```bash
git clone https://github.com/tansuasici/ClaudeBar.git
cd ClaudeBar
open AgentBar.xcodeproj
# Build & Run (Cmd+R) in Xcode
```

Requires macOS 14.0 (Sonoma) or later.

## How It Works

1. Sign in with your Claude account via the built-in browser
2. AgentBar reads your usage data from the Claude API
3. Displays session usage, weekly limits, and extra credits in a compact menu bar popup

## Privacy

All data stays on your device. AgentBar:
- Does **not** send data to any server (other than claude.ai for your own usage data)
- Does **not** collect analytics or telemetry

## License

MIT
