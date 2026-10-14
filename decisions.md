# Decisions

## 2026-10-14: Superseded — local-log Codex limits and expiry-to-zero

**Decision**: Two 2026-07-02 entries below no longer describe the app. "Official rate-limit percentages — Codex from session files" is replaced by the live `codex app-server` read; `CodexLimitsReader.swift` was deleted. "Expiry-zeroing lives in one display-time gate" is replaced by the shared presentation rule in `Shared/QuotaPresentation.swift`: a passed reset keeps the last value, marked unconfirmed, until a new reading arrives. Readings also go outdated after 60 minutes or after a failed attempt. The Claude OAuth half of the first entry, and the hold-last-known failure policy, still apply.

**Why**: Local session files cannot see cloud or other-machine Codex use, and an expired window showed a confident 0% that could be wrong. Both mattered once the readings went to the phone, where you choose a model without the Mac in front of you.

## Deferred polish (from 2026-07-02 review; not yet built)

- **Weekly reset weekday is ambiguous within 24h**: `wk 94% ·Mon` rendered on a Monday could mean hours or a week away. Fix: switch the weekly reset to clock time when it's within the next 24 hours.
- **Codex gauges are local-snapshot only**: they reflect the last local Codex turn, while the limits are account-wide. If Codex ever runs on another machine (e.g. the OpenClaw box), the gauges understate — and an expired local window shows a confident 0% that may be wrong. Consider a snapshot-age indicator past ~1h.
- **Hardcoded `claude-code/2.0.0` User-Agent will age**: if Claude gauges ever silently blank (429s in the log), bump the version string in ClaudeLimitsFetcher first.

## 2026-10-14: Mac publishing and the real widget

**Decision (publishing)**: The write half of the iCloud record lives in `Shared/CloudQuotaWriter.swift`, Mac-only, rather than inside `CloudQuotaStore.swift`. That kept the phone and widget from compiling code that was being edited during parallel work. When merging with the server record, each provider keeps its later state. Within one account context the higher accepted attempt wins, and a tie keeps the server's copy. Revisions are chosen only after reading the server, and a missing record gets a new incarnation. There are no timer retries; a failed or throttled upload waits for the next refresh, so the phone can lag up to about 15 minutes. If the server holds a newer snapshot format, the Mac stops overwriting it. Builds without the iCloud entitlement skip publishing instead of crashing. Publisher state lives under `quotaPublisherState`.

**Decision (widget)**: The small size shows at most one model cap per provider: the one closest to its limit, and only when it is past every account-wide window. Widget text is capped at the extra-extra-large size, where the Home Screen stops growing widget text on iOS 26.5, so paging doesn't trigger early. A page turn records its time and the reload within 20 seconds uses only the cache. Large repeats a provider's header when it splits across pages. Medium pages each provider's column separately. Page buttons are separate tap targets from provider links. Timeline budget: 3 seconds for the account check, 4 for the fetch, 8 overall. Future entries at each one-hour mark, reset, and credit expiry, at most 24. Next refresh about 30 minutes.

**Known issue**: JSON date encoding can move sub-second dates by about 0.12 microseconds on a round trip. Display is unaffected and the publisher tolerates it, but code comparing a local slot with a decoded one should not expect exact date equality.

**Why**: These follow KTD2, KTD6, KTD8, KTD9, and KTD10, and were accepted after 159 tests across four suites, signed Mac and iPhone builds, and a live publish and read-back passed.

## 2026-10-14: Live Mac collectors and the phone's shared cache

**Decision (Mac)**: Codex limits come from a short, read-only `codex app-server` session, not local logs. That supersedes the "Codex gauges are local-snapshot only" note above. The binary path is found with `zsh -lc 'whence -p codex'`, because Scott's shell defines a `codex` function. It is cached under `codexBinaryPath`, with `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin` as fallbacks. Only ChatGPT logins are supported. Codex buckets other than the main `codex` one become model-specific rows labeled from `limitName`. In the menu bar, outdated numbers are left out of the compact hint and the red warning, and a passed reset shows the old number struck through in gray. The legacy cache keys stay in place, because the installed `/Applications` copy shares this app's settings storage.

**Decision (phone)**: The app and widget share one JSON file in the `group.com.ccusagebar` App Group. It holds the hashed iCloud account, a generation counter, the snapshot with its cloud ordering data, and widget page state. Every change happens inside one coordinated write. The phone skips a fetch when it cannot confirm the iCloud account, and keeps its dated data. Restricted or temporarily unavailable accounts never clear data. The first account binding adopts whatever is already cached. The widget is asked to reload only when the cache actually changed. Wording: "Read on your Mac 12 minutes ago"; reset times read "today", a weekday within six days, or a date after that.

**Why**: These follow the plan's KTD5, KTD7, and KTD10. They were the workers' choices where the plan left room, and they were accepted after the combined tests, signed builds, and a live read passed.

**Codex cloud check**: Scott rarely uses Codex cloud tasks. Work on this Mac, including phone sessions that control it, reaches the live reading within seconds (18% live vs 18% in the logs, two seconds apart, on 2026-10-14). Cloud tasks remain unverified; check one when it happens, and the final end-to-end test repeats it.

## 2026-10-14: Small widget size

**Decision**: Add the small Home Screen size. It shows one line per limit (label, bar, percentage) with no reset times and no reset-credit expiry; those stay in the medium and large sizes. A model-specific cap such as Fable appears in the small size only when it is closer to its limit than every provider-wide window. An outdated reading shows its age in gray without the word "Outdated", which does not fit.

**Why**: Scott asked whether dropping the Fable line would allow a smaller widget. Width, not the Fable row, limits the small size. Hiding Fable entirely would mislead when Fable is the cap that actually stops work, so it shows only then.

## 2026-10-14: Codex reset credits and credit balance on the widget; medium size, always dark

**Decision**: The widget also shows Codex's "Full reset" credits (count and next expiry) and its credit balance, under the Codex section. It supports the medium and large Home Screen sizes and is always dark. Scott chose these; he declined a separate "blocked" status and the history stats (daily tokens, lifetime tokens, streaks).

**Why**: Reset credits change how hard Codex can be leaned on, and they expire unused (three on 2026-10-14, the first expiring October 22). `account/rateLimits/read` returns the count even with `excludeResetCreditDetails: true`, but the expiry dates need the detail lookup, so the Mac collector must read with details. The credit unit's dollar value is unknown, so the balance shows as a raw number. This adds to the plan's original capacity scope at Scott's request.

## 2026-10-14: Widget look built before the iCloud proof

**Decision**: At Scott's request, the large Home Screen widget's real design was built ahead of the signing and iCloud checks. It runs on a fixed sample of real October 14 readings and says "Preview · sample readings, not live" on screen. The temporary iCloud test widget remains as a separate widget, "CCUsage iCloud test", for the device check.

**Why**: Scott wanted to see the actual widget while his developer membership processes. The design does not depend on how readings travel, so the risk of rework is low. Reading ages show whole minutes on iOS 18 and later; seconds-level ages were too noisy on the Home Screen.

## 2026-10-14: Native iPhone widget scope confirmed

**Decision**: Use the [iPhone Usage Widget plan](docs/plans/2026-10-14-0849-feat-iphone-usage-widget-plan.md) as the scope for a personal native iPhone widget and small companion app, fed by private iCloud snapshots from this Mac. OpenClaw integration is deferred. This records the intended direction; implementation has not started.

**Why**: Scott wants to compare available Claude/Codex capacity from the Home Screen before starting remote or cloud work. The Mac normally remains awake, so it can continue collecting readings. The plan requires visible reading age and identifies developer signing, iCloud compatibility with the existing Mac app, and current Codex account-limit retrieval as early feasibility checks.

**Planned architecture**: Keep the existing unsandboxed Mac app and add an iOS companion app and WidgetKit extension in the same project. The Mac publishes one latest snapshot to a private CloudKit record; the phone app and extension share a coordinated cache. Credentials remain on the Mac. Use fresh Codex app-server account-limit readings and shared freshness rules across all three targets. Once implemented, these rules supersede the local-log-only Codex source and expiry-to-zero display behavior below: an expired or failed reading remains dated history until a new observation arrives. Validate the signed Mac-to-phone transfer before building the remaining feature.

## 2026-09-01: Fable 5.1 pricing pinned in a ccusage config override

**Decision**: Pin `claude-fable-5-1` pricing in `~/.config/claude/ccusage.json` under `defaults.pricingOverrides`, using Anthropic's published rates: input $10/M, output $50/M, cache write $12.50/M, cache read $0.25/M. No app code changed. The Fable sub-slice already matches any model name starting with `claude-fable`, and the FABLE limits row comes from the generic `limits[]` parsing; the endpoint reports one scoped "Fable" cap that covers the whole family.

**Why**: ccusage prices from LiteLLM's live table when online. When that fetch fails it silently falls back to a price snapshot embedded in its binary, with nothing on stderr. Neither the installed 20.0.9 nor the latest 20.0.20 (Aug 15) embeds `claude-fable-5-1`, so a refresh during a network blip would report Fable 5.1 at $0.00 and the app would cache it. Upgrading ccusage does not help this time (unlike the July 2 Fable 5 fix). A config override wins over the live table, so it also guards against upstream edits. Verified: online with the override, online without it, and offline with it all produce the same Fable 5.1 cost. One ccusage quirk worth knowing: under an override, 1-hour cache writes are charged at twice `inputCostPerToken` ($20/M, the same as LiteLLM's `above_1hr` rate), and `cacheCreationInputTokenCost` only covers 5-minute cache writes. Claude Code currently writes 1-hour cache entries only. Trade-off: if Anthropic changes Fable 5.1 prices, this file must be edited by hand.

## 2026-07-02: Fable sub-slice in the stacked bars

**Decision**: The Claude block in each day bar splits into standard orange (non-Fable Claude models) and a deeper burnt orange for `claude-fable-*` cost. The FABLE limits gauge uses the same deep shade.

**Why**: Fable dominates Claude spend and has its own weekly cap; giving its slice a shade ties the bar to the FABLE limits row (color-consistency rule).

## 2026-07-02: Per-model weekly caps as their own limits rows

**Decision**: Parse `weekly_scoped` entries from the usage endpoint's `limits[]` array (percent, reset, `scope.model.display_name`) and render each as its own row between CLAUDE and CODEX — weekly gauge only, aligned with the wk column. Scoped caps join the menu bar hottest-limit calculation with a first-two-letters hint (Fable → FA).

**Why**: The Fable weekly cap runs ~2x hotter than the all-models weekly, making it the binding Claude constraint; hiding it made the app's numbers look wrong next to /usage. Parsing the array generically (rather than hardcoding Fable) tracks whatever scoped caps the account exposes. Originally scoped out of v1; added same-day on real use.

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
