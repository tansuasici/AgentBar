# AgentBar

<p align="center">
  <img src="icon.png" alt="AgentBar Logo" width="128" height="128">
</p>

A native macOS menu bar app that shows your **Claude** and **ChatGPT** usage & rate limits at a glance.

<p align="center">
  <img src="screenshot.png" width="314" alt="AgentBar screenshot">
</p>

## Features

- **Claude Rate Limits** — Current session %, weekly limits (all models + per-model), and extra usage credits.
- **ChatGPT Rate Limits** — Current session and weekly usage percentages with reset timers.
- **Simple Setup** — Auto-detects Claude Desktop cookies, or sign in once manually. ChatGPT sign-in via built-in browser with OAuth support (Google, Apple, etc.).
- **Menu Bar Native** — Lives in your macOS menu bar, one click to open.
- **Auto-Refresh** — Updates automatically every 5 minutes.
- **Local-First** — All data stays on your device. No servers, no telemetry.

## Install

Download the latest DMG from [Releases](https://github.com/tansuasici/AgentBar/releases), open it, and drag AgentBar to Applications.

Requires macOS 14.0 (Sonoma) or later.

## How It Works

### Claude
1. If Claude Desktop is installed, usage data is fetched automatically (no sign-in needed)
2. Otherwise, sign in once with your Claude account via the built-in browser
3. Displays session usage, weekly limits, and extra credits

### ChatGPT
1. Sign in to your ChatGPT account via the built-in browser
2. Usage data is fetched from ChatGPT's usage API
3. Displays current session and weekly usage with reset timers

## Privacy

All data stays on your device. AgentBar:
- Does **not** send data to any server (other than claude.ai and chatgpt.com for your own usage data)
- Does **not** collect analytics or telemetry
- Cookies are stored locally in isolated per-service data stores

## License

MIT
