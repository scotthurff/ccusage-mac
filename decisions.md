# Decisions

## 2026-07-02: Provider split derived from the existing single ccusage call

**Decision**: Split each day's bar into Claude/Codex/other segments by classifying `modelBreakdowns` model names (`claude-*` → Claude, `gpt-*` → Codex, else other) instead of invoking `ccusage claude daily` + `ccusage codex daily` separately.

**Why**: ccusage v20's plain `daily` already aggregates all agents — Codex was silently blended into every bar. One process instead of two avoids schema drift between subcommands (claude uses `period`/`totalCost`, codex uses `date`/`costUSD`) and keeps totals internally consistent. Provider colors (Claude orange, Codex teal, other gray) repeat between bars and limits rows, so no legend.

## 2026-07-02: Official rate-limit percentages — Codex from session files, Claude from the OAuth usage endpoint

**Decision**: Codex 5h/weekly limits parse from the newest `rate_limits` event in `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (both `resets_at` epoch and `resets_in_seconds` variants; windows classified by `window_minutes` magnitude, not equality). Claude limits come from `GET api.anthropic.com/api/oauth/usage` using the Claude Code OAuth token read via `/usr/bin/security find-generic-password` (fallback `~/.claude/.credentials.json`). This is the app's first network call. The `User-Agent: claude-code/<ver>` header is required — omitting it causes persistent 429s.

**Why**: Both sources carry official account-wide percentages (matching `codex` status and Claude Code's `/usage`) versus token-count estimation, which is approximate and single-machine. The `security` CLI reads the keychain item without an ACL prompt; a native SecItem call from a foreign app would trigger one. The token lives in memory only, is never logged, and the request uses `URLSessionConfiguration.ephemeral` so the Authorization header can never be persisted to the shared URL cache on disk. Expired token → skip the call and wait for Claude Code to refresh it (no refresh flow of our own).

## 2026-07-02: Expiry-zeroing lives in one display-time gate, not the readers

**Decision**: `LimitWindow.effectivePercent`/`effectiveResetsAt` return 0%/nil once the reset time has passed. All consumers (LimitsView, menu bar hottest-%) read through these; readers/fetchers return raw data.

**Why**: Cached snapshots loaded from UserDefaults on relaunch never re-pass through a reader — reader-local zeroing would render a stale hot percentage and fire a false menu-bar warning. One gate covers live fetches, cached snapshots, both providers, and long-open popovers.

## 2026-07-02: Three-state gauge display contract + hold-last-known failure policy

**Decision**: Gauges have three non-live states — loading placeholder on first uncached load, 0% empty gauge for an inactive/reset window (API null or reset passed), `--` per individual missing gauge. On transient fetch failure, hold last-known values; `--` only before the first-ever success.

**Why**: Loading, zero, and broken must never look alike (0% invites work, `--` invites caution). Hold-last-known matches the existing usage-cache behavior and prevents the nightly expired-token 401 from flapping the gauges; staleness is bounded by the expiry gate.

## 2026-07-02: Menu bar label = whole-dollar cost + hottest limit %, warning via icon swap

**Decision**: Label renders `$80 · 62%` (hottest of the four limit gauges). Limits unavailable → existing cost-only label; cost unavailable → percentage alone. At ≥80%, the leading `chart.bar.fill` glyph swaps to `exclamationmark.triangle.fill`, keeping `isTemplate = true`.

**Why**: The hottest limit is the single most actionable number. The icon swap (instead of the plan's inline triangle before the percentage) avoids splitting text runs mid-label while preserving template rendering for light/dark menu bars; same glance signal, simpler drawing.

## 2026-07-02: Still no test target — parsers verified against live data

**Decision**: No XCTest target added. The Codex parser was verified byte-for-byte against the newest real session file and the Claude fetcher end-to-end against the live endpoint on this machine.

**Why**: Repo convention (personal tool, zero ceremony). The defensive branches (hex-decode fallback, `resets_in_seconds` variant) are documented in the plan and exercised only if the wild data shifts.

## 2026-06-09: Require ccusage v20+, map "period" JSON key to date

**Decision**: Upgraded the global ccusage CLI from 17.1.6 to 20.0.9 and added a `CodingKeys` mapping in `DailyUsage` so the `date` property decodes from v20's renamed `period` key.

**Why**: ccusage 17.x had no pricing entry for `claude-fable-5`, so Fable 5 usage decoded with cost $0.00 — invisible in the cost-based bars and totals even though its tokens were counted. v20 prices Fable correctly, but it also renamed `date` → `period` in the daily JSON, which would have broken the app's decoder (decode failure → "Couldn't load data"). Side effect: the app's own cache now encodes `period` too, so a cache written by the old build fails to decode once on first launch and is replaced after the first successful refresh.

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
