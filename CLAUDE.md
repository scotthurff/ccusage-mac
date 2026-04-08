# CLAUDE.md

## Project Overview

CCUsageBar is a macOS menu bar app (SwiftUI) that displays Claude Code token usage and cost data from the `ccusage` CLI tool. It's a personal dev tool — not App Store bound.

## Architecture

- **SwiftUI** with `MenuBarExtra` (.window style) for the popover
- **No sandbox** — needs Process execution to shell out to ccusage
- **Target**: macOS 14+ (Sonoma)
- **7 source files, flat structure** — no subdirectories for Models/Services/Views

### Key Files

- `CCUsageBarApp.swift` — @main entry point, MenuBarExtra scene
- `AppState.swift` — @MainActor ObservableObject, owns all state, cache, refresh loop
- `CCUsageRunner.swift` — actor, resolves ccusage binary path, runs Process with terminationHandler
- `UsageData.swift` — Codable structs matching ccusage JSON schema
- `PopoverContentView.swift` — entire popover UI in one file
- `FooterView.swift` — refresh button, quit button

### Data Flow

1. On launch: load cached JSON from UserDefaults → display → async refresh
2. Every 15 minutes: background refresh via Task.sleep loop
3. ccusage binary resolved once via `zsh -lc "which ccusage"`, path cached in UserDefaults
4. Process execution uses terminationHandler + CheckedContinuation (never waitUntilExit)
5. 30-second timeout on process execution

## Build

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsageBar -configuration Release build
```

## Conventions

- Flat file structure — no folders until a category has 3+ files
- Views stay in single files until they exceed ~150 lines
- No premature abstractions — build what's needed now
- Error handling: 2 states (has data / no data), not granular error screens
- Log errors via os.Logger, don't surface implementation details to UI

## Decision Log

All architectural and design decisions are documented in `decisions.md`. When making a decision that affects architecture, UI behavior, data flow, or tooling, add an entry to that file with the date, decision, and reasoning.
