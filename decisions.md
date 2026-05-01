# Decisions

## 2026-04-07: Flat file structure, no subdirectories

**Decision**: Keep all Swift files flat in the CCUsageBar/ directory. No Models/, Services/, or Views/ folders.

**Why**: With ~7 files, subdirectories are ceremony, not organization. A folder with one file in it solves no problem. Revisit when any category hits 3+ files.

## 2026-04-07: Use terminationHandler + CheckedContinuation, not waitUntilExit()

**Decision**: Never call `Process.waitUntilExit()` from async context. Use `terminationHandler` bridged to async/await via `CheckedContinuation`.

**Why**: `waitUntilExit()` blocks a cooperative thread for the entire ccusage execution (~3-10 seconds), starving Swift's limited thread pool.

## 2026-04-07: Resolve ccusage binary once, call directly

**Decision**: On first launch, resolve the ccusage path via `zsh -lc "which ccusage"`. Cache the path in UserDefaults. All subsequent calls invoke the binary directly with PATH set to include its parent directory.

**Why**: Running `zsh -lc` on every refresh sources the user's entire .zshrc (potentially slow with oh-my-zsh, conda, etc.). Resolving once avoids that overhead and eliminates shell injection risk since args are passed as an array, not interpolated into a shell string.

## 2026-04-07: 15-minute refresh interval

**Decision**: Auto-refresh every 15 minutes, with a manual refresh button for immediate updates.

**Why**: Daily cost doesn't change fast enough to warrant 5-minute refreshes. Each ccusage run takes 3-10 seconds, so less frequent polling is more respectful of system resources. Manual refresh covers the "I want it now" case.

## 2026-04-07: 2 error states, not 5

**Decision**: UI shows two states — "has data" (possibly stale) and "no data" (error/first launch). No granular error screens for binary-not-found vs parse-error vs timeout.

**Why**: This is a personal dev tool. Detailed error UX is wasted effort. Actual errors are logged via os.Logger for console debugging.

## 2026-04-07: UserDefaults for cache

**Decision**: Cache the last ccusage JSON response (~5KB) in UserDefaults with a timestamp.

**Why**: Enables instant display on app launch before the background refresh completes. UserDefaults handles this size trivially. A file in Application Support would work but adds unnecessary complexity.

## 2026-04-07: No sandbox

**Decision**: Disable App Sandbox entirely.

**Why**: The app needs to execute arbitrary binaries via Process (ccusage, zsh). It's a local dev tool, not destined for the Mac App Store.

## 2026-04-07: MenuBarExtra with .window style

**Decision**: Use `.menuBarExtraStyle(.window)` for the popover, not `.menu`.

**Why**: The .window style gives a proper NSPanel popover that can hold a richer layout (proportional bars, styled text). The .menu style would limit us to basic menu items.

## 2026-04-07: Deferred features (v2)

**Decision**: Cut from v1: per-model breakdown drill-down, Launch at Login (SMAppService), configurable refresh interval, .menu style evaluation.

**Why**: Ship the core (glance at cost in menu bar, see 7-day history) first. Add features only after using the app and discovering what's actually missing.

## 2026-04-07: 30-second process timeout

**Decision**: Race ccusage execution against a 30-second timeout. On timeout, terminate the process.

**Why**: Without a timeout, a hung ccusage process (network issue, filesystem lock) would silently block all future refreshes forever.

## 2026-04-30: Shrink --since window from full month to 14 days

**Decision**: Pass `--since <14 days ago>` instead of `--since <1st of current month>` when invoking ccusage.

**Why**: ccusage hangs indefinitely on multi-week ranges (reproduced from terminal, not just from the app — tested ranges as small as 10 days hang past 30s, while 1-day ranges return in ~1s). With our 30s process timeout, every refresh silently failed, leaving the popover stuck on whatever the last successful refresh captured. The popover only shows the last 7 days anyway; 14 gives a small buffer without re-entering ccusage's slow path. Renamed the bottom row from "<Month> Total" to "Last 14 Days" to match.

## 2026-04-07: Render menu bar label as NSImage, not SwiftUI Text

**Decision**: Use `NSImage` rendering with `NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)` for the menu bar label instead of SwiftUI `Text` views.

**Why**: SwiftUI's `MenuBarExtra` label ignores custom font settings (size, font family). Rendering as an `NSImage` with `isTemplate = true` gives full control over font, size, and spacing while still adapting to light/dark menu bar.
