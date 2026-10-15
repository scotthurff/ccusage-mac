# CLAUDE.md

## Project Overview

CCUsageBar is a macOS menu bar app (SwiftUI) that displays Claude Code and Codex usage, cost, and live rate limits. It publishes the limits to private iCloud for a personal iPhone companion app and Home Screen widget. It's a personal dev tool — not App Store bound.

## Architecture

- **SwiftUI** with `MenuBarExtra` (.window style) for the popover
- **No sandbox** on the Mac — needs Process execution for ccusage and the Codex CLI
- **Targets**: `CCUsageBar` (macOS 14+), `CCUsagePhone` (iOS 17+), `CCUsageWidget` (WidgetKit extension), plus test targets `CCUsageSharedTests`, `CCUsageBarTests`, `CCUsagePhoneTests`, `CCUsageWidgetTests`, `CCUsagePhoneUITests`
- **Signing**: Apple Development, one paid team for all targets; iCloud container `iCloud.com.ccusagebar`; App Group `group.com.ccusagebar` (phone and widget)
- **Flat folders per target**: `CCUsageBar/`, `CCUsagePhone/`, `CCUsageWidget/`, `Shared/`, one folder per test target. Target membership is explicit in the project file; adding a file means adding it to every target that compiles it.

### Key Files

- `CCUsageBar/CCUsageBarApp.swift` — @main entry point, MenuBarExtra scene
- `CCUsageBar/AppState.swift` — @MainActor ObservableObject: usage/cost state, one quota slot per provider, account binding, refresh loop
- `CCUsageBar/CCUsageRunner.swift` — actor, resolves ccusage binary path, runs Process with terminationHandler
- `CCUsageBar/CodexLimitsClient.swift` — bounded, read-only `codex app-server` session for live Codex limits
- `CCUsageBar/ClaudeLimitsFetcher.swift` — Claude OAuth usage endpoint
- `CCUsageBar/QuotaPublisher.swift` — publishes the latest snapshot to private CloudKit
- `CCUsageBar/PopoverContentView.swift`, `LimitsView.swift`, `FooterView.swift` — popover UI
- `Shared/QuotaSnapshot.swift` — the versioned snapshot format shared by all apps
- `Shared/QuotaPresentation.swift` — freshness rules (outdated after 60 minutes or a failed attempt; passed resets unconfirmed, never 0%)
- `Shared/CloudQuotaStore.swift` / `CloudQuotaWriter.swift` — the CloudKit record's read side (all apps) and write side (Mac only)
- `Shared/PhoneSnapshotCache.swift` — the phone app and widget's shared, coordinated cache
- `CCUsagePhone/` — companion app (details, setup guidance, refresh); `CCUsageWidget/` — small/medium/large widget, timeline, paging

### Data Flow

1. On launch: load cached JSON from UserDefaults → display → async refresh
2. Every 15 minutes: background refresh via Task.sleep loop (ccusage costs, Claude and Codex limits, each independent)
3. Binaries resolved once and cached in UserDefaults: ccusage via `zsh -lc "which ccusage"`, Codex via `zsh -lc 'whence -p codex'` (the user's shell defines a `codex` function)
4. Process execution uses terminationHandler + CheckedContinuation (never waitUntilExit); 30-second timeout for ccusage, 15 seconds for Codex
5. After each limits round, the Mac publishes one snapshot to the private CloudKit record; iCloud failures never affect the menu bar
6. The phone app and widget fetch that record (bounded), keep it in the App Group cache, and show each reading's original age

## Build

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsageBar -configuration Release -allowProvisioningUpdates build
```

Tests, phone install, renewal, and troubleshooting: see `README.md` and `docs/iphone-widget-setup.md`.

## Conventions

- Flat file structure — no folders until a category has 3+ files
- Views stay in single files until they exceed ~150 lines
- No premature abstractions — build what's needed now
- Error handling: 2 states (has data / no data), not granular error screens
- Log errors via os.Logger, don't surface implementation details to UI

## Decision Log

All architectural and design decisions are documented in `decisions.md`. When making a decision that affects architecture, UI behavior, data flow, or tooling, add an entry to that file with the date, decision, and reasoning.
