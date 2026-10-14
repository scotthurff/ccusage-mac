# CCUsageBar

macOS menu bar app for tracking [Claude Code](https://claude.ai/claude-code) and [Codex](https://developers.openai.com/codex) token usage, cost, and rate limits via [ccusage](https://github.com/ryoppippi/ccusage), plus a personal iPhone app and Home Screen widget that show the same limits away from the Mac.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue)

## Features

- Today's cost + hottest rate-limit % in the menu bar (warning icon at ≥80%)
- Rate-limit portrait: Claude and Codex 5-hour + weekly usage with reset times, each reading's age, and gray outdated values
- iPhone Home Screen widget (small, medium, large) and companion app, fed by private iCloud snapshots from the Mac
- 7-day usage history with stacked Claude/Codex bars
- 14-day total
- Auto-refresh every 15 minutes
- Cached data for instant display on relaunch

## Prerequisites

Install ccusage:

```sh
npm install -g ccusage
```

Pin pricing for any model newer than the price snapshot embedded in ccusage, so cost stays correct when its live price fetch fails. Create `~/.config/claude/ccusage.json`:

```json
{
  "$schema": "https://ccusage.com/config-schema.json",
  "defaults": {
    "pricingOverrides": {
      "claude-fable-5-1": {
        "inputCostPerToken": 0.00001,
        "outputCostPerToken": 0.00005,
        "cacheCreationInputTokenCost": 0.0000125,
        "cacheReadInputTokenCost": 0.00000025
      }
    }
  }
}
```

ccusage 20.0.9 and newer reads this file on its own. See `decisions.md` (2026-09-01) for why an upgrade alone does not cover it.

## Build

All targets sign with Apple Development under the team in the project (a paid Apple Developer Program membership is required for iCloud). Xcode needs that Apple account signed in.

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsageBar -configuration Release -allowProvisioningUpdates build
```

The built app is at `~/Library/Developer/Xcode/DerivedData/CCUsageBar-*/Build/Products/Release/CCUsageBar.app`.

Tests:

```sh
xcodebuild test -project CCUsageBar.xcodeproj -scheme CCUsageSharedTests -destination 'platform=macOS'
xcodebuild test -project CCUsageBar.xcodeproj -scheme CCUsageBarTests -destination 'platform=macOS'
xcodebuild test -project CCUsageBar.xcodeproj -scheme CCUsagePhoneTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project CCUsageBar.xcodeproj -scheme CCUsageWidgetTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project CCUsageBar.xcodeproj -scheme CCUsagePhoneUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

## Install

Quit any running copy, replace `/Applications/CCUsageBar.app` with the built app, and open it.

To launch at login, add it in **System Settings > General > Login Items**.

The iPhone app and widget install from Xcode onto a connected phone with Developer Mode on. See [docs/iphone-widget-setup.md](docs/iphone-widget-setup.md) for setup, renewal, and troubleshooting.

## How It Works

The app shells out to `ccusage daily --json` to fetch usage data from your local agent CLI logs (ccusage v20+ aggregates Claude Code, Codex, and other agents; the app splits providers by model name). On first launch, it resolves the `ccusage` binary path via your shell profile and caches it for subsequent calls.

Rate limits come from two live sources on each refresh:

- **Codex**: a short, read-only `codex app-server` session (`account/read`, then `account/rateLimits/read`) using the Codex CLI's existing login. It never starts a model turn. It includes cloud and remote usage that local logs miss, plus "Full reset" credits and the credit balance.
- **Claude**: Anthropic's OAuth usage endpoint, authenticated with the Claude Code token read from the macOS keychain. Read-only: the token is never logged or persisted, and the request uses an ephemeral session so nothing hits the disk cache.

Each reading keeps the time the provider reported it. A reading older than an hour, or after a failed refresh, turns gray instead of claiming to be current, and a reset that passes without a new reading never becomes 0%.

After each refresh the Mac publishes one small snapshot of limit values to a private CloudKit record in your own iCloud. It contains percentages, reset times, and reading times only, never tokens, emails, or session contents. The iPhone app and widget read that record.

Data is cached in UserDefaults so the app shows your last known usage instantly on launch, then refreshes in the background.
