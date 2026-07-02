# CCUsageBar

macOS menu bar app for tracking [Claude Code](https://claude.ai/claude-code) and [Codex](https://developers.openai.com/codex) token usage, cost, and rate limits via [ccusage](https://github.com/ryoppippi/ccusage).

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)

## Features

- Today's cost + hottest rate-limit % in the menu bar (warning icon at ≥80%)
- Rate-limit portrait: Claude and Codex 5-hour + weekly usage with reset times
- 7-day usage history with stacked Claude/Codex bars
- 14-day total
- Auto-refresh every 15 minutes
- Cached data for instant display on relaunch

## Prerequisites

Install ccusage:

```sh
npm install -g ccusage
```

## Build

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsageBar -configuration Release build
```

The built app is at `~/Library/Developer/Xcode/DerivedData/CCUsageBar-*/Build/Products/Release/CCUsageBar.app`.

## Install

Drag `CCUsageBar.app` to `/Applications`.

To launch at login, add it in **System Settings > General > Login Items**.

## How It Works

The app shells out to `ccusage daily --json` to fetch usage data from your local agent CLI logs (ccusage v20+ aggregates Claude Code, Codex, and other agents; the app splits providers by model name). On first launch, it resolves the `ccusage` binary path via your shell profile and caches it for subsequent calls.

Rate limits come from two sources on each refresh:

- **Codex**: the newest `rate_limits` event in `~/.codex/sessions/` — official percentages the Codex CLI records locally
- **Claude**: Anthropic's OAuth usage endpoint (the app's only network call), authenticated with the Claude Code token read from the macOS keychain. Read-only: the token is never logged or persisted, and the request uses an ephemeral session so nothing hits the disk cache.

Data is cached in UserDefaults so the app shows your last known usage instantly on launch, then refreshes in the background.
