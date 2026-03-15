# AgentBar

<p align="center">
  <img src="icon.png" alt="AgentBar Logo" width="128" height="128">
</p>

A native macOS menu bar app that shows your **Claude usage & rate limits** at a glance.

<p align="center">
  <img src="screenshot.png" width="314" alt="AgentBar screenshot">
</p>

## Features

- **Claude Rate Limits** — Current session %, weekly limits (all models + per-model), and extra usage credits.
- **Simple Setup** — Auto-detects Claude Desktop cookies, or sign in once manually.
- **Menu Bar Native** — Lives in your macOS menu bar, one click to open.
- **Auto-Refresh** — Updates automatically every few minutes.
- **Local-First** — All data stays on your device. No servers, no telemetry.

## Install

Download the latest DMG from [Releases](https://github.com/tansuasici/AgentBar/releases), open it, and drag AgentBar to Applications.

> **Note:** Since AgentBar is not notarized with an Apple Developer ID, macOS may show a warning on first launch. To fix this, run:
> ```bash
> xattr -cr /Applications/AgentBar.app
> ```
> Then open AgentBar normally.

Requires macOS 14.0 (Sonoma) or later.

## How It Works

1. If Claude Desktop is installed, usage data is fetched automatically (no sign-in needed)
2. Otherwise, sign in once with your Claude account via the built-in browser
3. Displays session usage, weekly limits, and extra credits in a compact menu bar popup

## Privacy

All data stays on your device. AgentBar:
- Does **not** send data to any server (other than claude.ai for your own usage data)
- Does **not** collect analytics or telemetry

## License

MIT
