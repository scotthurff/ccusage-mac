# CCUsageBar

macOS menu bar app for tracking [Claude Code](https://claude.ai/claude-code) token usage and cost via [ccusage](https://github.com/ryoppippi/ccusage).

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)

## Features

- Today's cost displayed in the menu bar
- 7-day usage history with proportional bars
- Monthly total
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

The app shells out to `ccusage daily --json` to fetch usage data from your local Claude Code conversation logs. On first launch, it resolves the `ccusage` binary path via your shell profile and caches it for subsequent calls.

Data is cached in UserDefaults so the app shows your last known usage instantly on launch, then refreshes in the background.
