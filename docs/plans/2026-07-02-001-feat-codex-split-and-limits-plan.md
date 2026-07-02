---
title: "feat: Codex provider split + usage limit portrait"
type: feat
status: complete
date: 2026-07-02
origin: docs/brainstorms/2026-07-02-codex-and-limits-requirements.md
---

# feat: Codex Provider Split + Usage Limit Portrait

## Overview

Two additions to CCUsageBar: (1) split the existing 7-day cost bars into Claude/Codex stacked segments — the data is already in the app's single `ccusage daily` call, just invisibly blended; (2) add a limits portrait at the top of the popover showing official 5-hour and weekly rate-limit percentages for both providers with reset times, plus a hottest-limit indicator in the menu bar label.

---

## Problem Frame

Since the ccusage v20 upgrade, plain `ccusage daily` aggregates all agent CLIs — Codex usage is silently mixed into every bar and total. And the app says nothing about the binding constraint on daily work: hourly/weekly rate limits on both subscriptions. (see origin: docs/brainstorms/2026-07-02-codex-and-limits-requirements.md)

---

## Requirements Trace

Carried from origin doc:

**Provider split in the 7-day graph**
- R1. Stacked per-day bars: Claude segment (existing orange) + Codex segment (distinct color); combined day totals unchanged
- R2. Provider split derived from existing single `ccusage daily --json` call via model-name prefix (`claude-*` / `gpt-*` / other), no second invocation
- R3. Provider colors consistent between bar segments and limits rows; minimal legend only if it fits
- R4. "Last 14 Days" row stays combined

**Limits portrait**
- R5. Limits section at top of popover: one compact row per provider, 5h + weekly gauges
- R6. Gauge = progress bar + used % + inline dimmed reset (clock time for 5h, day for weekly)
- R7. Codex limits from newest session rollout `rate_limits` event (verified locally)
- R8. Claude limits from `api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token
- R9. Stale/missing handling: expired reset → 0%; unavailable provider → `--` gauges (2-state philosophy)
- R10. Limits refresh on the existing 15-min loop + manual refresh

**Menu bar label**
- R11. Menu bar: whole-dollar today cost + hottest limit %, e.g. `$80 · 62%`
- R12. Warning treatment when any limit ≥ 80%, compatible with template-NSImage rendering

---

## Scope Boundaries

Carried from origin: no per-provider 14-day split, no tabs/drill-down, no notifications, no first-class support for other agents (lumped into "other" segment), no configurable thresholds/intervals.

Plan-local additions:

- No OAuth token refresh logic — read whatever token Claude Code has stored; on 401/expiry, show `--` until Claude Code refreshes it (matches all known community tools)
- No display of Claude's per-model weekly sub-limits (`seven_day_opus`/`seven_day_sonnet`) or `extra_usage` overage state in v1
- No XCTest target — repo has none; verification stays manual per repo convention

---

## Context & Research

### Relevant Code and Patterns

- `CCUsageBar/CCUsageBar/CCUsageRunner.swift` — actor + Process + terminationHandler/CheckedContinuation + 30s timeout pattern; reuse for the `security` CLI call
- `CCUsageBar/CCUsageBar/AppState.swift` — @MainActor ObservableObject owning state, UserDefaults cache, 15-min refresh loop; limits state slots in here
- `CCUsageBar/CCUsageBar/PopoverContentView.swift` — `dayRow(_:)` GeometryReader bar to convert to stacked segments; Claude orange is `Color(red: 0.85, green: 0.45, blue: 0.25)`
- `CCUsageBar/CCUsageBar/CCUsageBarApp.swift` — `menuBarImage(cost:)` renders the label as a template NSImage (monospaced 11pt); extend for `$NN · NN%`
- `CCUsageBar/CCUsageBar/UsageData.swift` — `ModelBreakdown` (modelName + cost) already decoded per day; the provider split needs no schema change
- Repo conventions: flat files, new view file only when >150 lines, 2 error states, os.Logger, decisions.md entry for every architectural/UI decision

### External References (verified 2026-07-02)

- **Claude usage endpoint**: `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, and `User-Agent: claude-code/<version>` — the User-Agent is load-bearing (its absence causes persistent 429s). Response: `five_hour: {utilization: 0-100, resets_at: ISO8601}`, `seven_day: {...}`, plus `seven_day_opus/seven_day_sonnet/extra_usage` (ignored in v1). Undocumented/internal endpoint — schema has shifted before; treat defensively. (github.com/Maciek-roboblog/Claude-Code-Usage-Monitor#202, anthropics/claude-code#31021, #13770)
- **Claude token storage**: keychain service `Claude Code-credentials`, account = macOS username, JSON payload `{claudeAiOauth: {accessToken, refreshToken, expiresAt, ...}}`; fallback file `~/.claude/.credentials.json` (same shape). `/usr/bin/security find-generic-password -a <user> -s "Claude Code-credentials" -w` reads it **without a keychain prompt** (anthropics/claude-code#29783); a native SecItem call from another app would hit the ACL dialog.
- **Codex rate_limits**: inside `token_count` events in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Schema varies by Codex version: this machine's files carry `resets_at` (epoch seconds); recent builds documented with `resets_in_seconds` (relative to event). `window_minutes` is off-by-one in the wild (299/10079) — identify windows by magnitude, not equality. Format explicitly labeled evolving by ccusage. (openai/codex#14728, ccusage.com/guide/codex)
- **Prior art**: steipete/CodexBar — Swift menu bar app doing exactly this (Claude + Codex usage, no login); xiangz19/codex-ratelimit walks dated session dirs backward to find the latest rate_limits event.

---

## Key Technical Decisions

- **Read the Claude token by shelling out to `/usr/bin/security`**, not Security.framework: no keychain ACL prompt, and the app already has a hardened Process pattern in CCUsageRunner. Fall back to `~/.claude/.credentials.json` if the keychain item lacks `claudeAiOauth`.
- **Parse both Codex reset field variants** (`resets_at` epoch → Date; `resets_in_seconds` + event timestamp → Date). Classify primary/secondary by `window_minutes` magnitude (≈300 vs ≈10080), not exact equality.
- **Scan rollout files backward by dated directory, tail-first**: walk `~/.codex/sessions/YYYY/MM/DD` from today backward (bounded to ~7 days), take files by mtime descending, and search each file's *last* `rate_limits` occurrence. Read file contents once per refresh; files are MBs not GBs, and refresh is 15-minutely.
- **Limits fetch failures are silent per provider** (R9): each provider's limits are `nil`-able; UI renders `--`. Log via os.Logger. No new error states.
- **Cache limits snapshots in UserDefaults** alongside the existing usage cache so relaunch shows last-known limits instantly.
- **Expiry-zeroing (R9) lives in one shared display-time gate, not in the readers**: `LimitWindow` exposes an effective percentage that returns 0 (with no reset time) once its reset Date has passed. LimitsView, the menu bar's `hottestLimitPercent`, and anything else consuming limits read through this gate. Readers/fetchers return raw parsed data. Rationale: cached snapshots loaded from UserDefaults on relaunch never pass through a reader — reader-local zeroing would render a stale hot percentage and fire a false menu-bar warning; a display-time gate covers live fetches, cached snapshots, Claude and Codex windows, and long-open popovers through the same code path.
- **Menu bar warning stays template-compatible**: at ≥80% render an `exclamationmark.triangle.fill` SF Symbol before the percentage instead of colorizing — keeps `isTemplate = true` so light/dark adaptation is preserved. (R12; colored non-template rendering rejected: breaks menu bar appearance adaptation.)
- **No test target**: repo has none and its conventions favor zero ceremony for a personal tool. Each unit carries concrete manual verification scenarios instead; parsing edge cases are exercised against real local files.

---

## Open Questions

### Resolved During Planning

- Where does the Claude token live / how to read it without a prompt: `security` CLI against service `Claude Code-credentials`, account = macOS username. **Verified on this machine 2026-07-02**: the item contains both `mcpOAuth` and `claudeAiOauth` (with `accessToken`, `refreshToken`, `expiresAt` in ms), read with no keychain prompt.
- Endpoint request/response shape: verified from community sources with real payloads (see External References).
- Codex reset field: both variants handled; local files verified to use `resets_at` epoch.
- Limits display-state contract (from 2026-07-02 doc review): three distinct non-live states — loading placeholder on first uncached load, 0% empty gauge for inactive/reset windows, `--` per individual missing gauge. Decided with the user.
- Transient-failure display policy (from 2026-07-02 doc review): hold last-known values through failures, `--` only before first-ever success; the shared expiry gate bounds staleness. Decided with the user.

### Deferred to Implementation

- Exact `User-Agent` version string to send (mirror a current Claude Code version; verify the endpoint accepts it with a live call during U4)
- Whether the keychain JSON is ever hex-encoded (one unverified claim; handle by attempting JSON parse, then hex-decode fallback if needed)
- Codex segment color + gauge micro-styling (frontend-design pass during U2/U5; layout is fixed by the approved mockups)
- Menu bar label width tuning if `$NNN · NN%` proves too wide on a crowded menu bar

---

## Implementation Units

- [x] U1. **Provider split in the data layer**

**Goal:** Every `DailyUsage` exposes claude/codex/other cost splits derived from its `modelBreakdowns`.

**Requirements:** R2, R4

**Dependencies:** None

**Files:**
- Modify: `CCUsageBar/CCUsageBar/UsageData.swift`

**Approach:**
- Add a `Provider` enum (claude, codex, other) with a classifier on model name prefix: `claude-*` → claude, `gpt-*` → codex, else other
- Add computed properties on `DailyUsage` (e.g. `claudeCost`, `codexCost`, `otherCost`) summing `modelBreakdowns` by provider — no stored properties, so the Codable schema and existing cache stay untouched
- Totals and existing properties unchanged (R4)

**Test scenarios:** (manual, via real cached data)
- Happy path: a day with both `claude-*` and `gpt-*` breakdowns → splits sum to `totalCost` within float tolerance
- Edge case: a day with only Claude models → `codexCost == 0`, bar renders full orange
- Edge case: unknown model name (simulate) → lands in `other`, never dropped

**Verification:**
- App builds; popover totals identical to pre-change values for the same data

---

- [x] U2. **Stacked provider segments in the 7-day bars**

**Goal:** Each day bar renders Claude + Codex (+ other, when present) segments proportional to cost, colors consistent with the limits section.

**Requirements:** R1, R3

**Dependencies:** U1

**Files:**
- Modify: `CCUsageBar/CCUsageBar/PopoverContentView.swift`

**Approach:**
- In `dayRow(_:)`, replace the single `RoundedRectangle` with adjacent segments inside the same GeometryReader track (rounded container, e.g. clipped HStack with zero spacing) — widths proportional to per-provider cost over `maxDailyCost`
- Define provider colors once (Claude = existing orange; Codex = distinct cool tone chosen in the design pass; other = neutral gray) where both this view and the limits view can use them
- Keep the 4pt minimum visible width behavior for nonzero days; omit zero-cost segments entirely on days with cost
- Special-case all-zero days (`totalCost == 0`): render the existing single min-width neutral bar exactly as today, rather than attempting per-provider segment omission — an ordinary weekend occurrence, not an edge
- Legend: only if it fits the existing footprint (R3); provider colors repeating in the limits rows may make it unnecessary

**Execution note:** Apply frontend-design judgment here (restrained palette, contrast in light/dark menu bar popovers); the approved ASCII mock in the origin doc is the layout spec.

**Test scenarios:** (manual)
- Happy path: day with both providers → two segments, boundary at the cost ratio, total bar length unchanged vs. pre-change
- Edge case: Claude-only day → single orange bar, no sliver artifacts
- Edge case: tiny Codex share (<2% of max) → segment either visible at min width or cleanly omitted — no 1px smear
- Edge case: all-zero day (e.g. weekend) → single neutral min-width bar matching current behavior, no empty track or sliver artifacts
- Light/dark: popover in both appearances → segment colors distinguishable and non-vibrating

**Verification:**
- Visual: last-7-days view matches origin mockup; day totals on the right unchanged

---

- [x] U3. **Codex limits reader**

**Goal:** An actor that returns the latest Codex 5h/weekly limit snapshot from local session rollouts.

**Requirements:** R7, R9

**Dependencies:** None (parallel with U1/U2)

**Files:**
- Create: `CCUsageBar/CCUsageBar/LimitsData.swift` (shared models: e.g. `LimitWindow {usedPercent, resetsAt}`, `ProviderLimits {fiveHour, weekly}`)
- Create: `CCUsageBar/CCUsageBar/CodexLimitsReader.swift`

**Approach:**
- Walk `~/.codex/sessions/YYYY/MM/DD` directories backward from today (bounded ~7 days); within a day, order rollout files by mtime descending
- In the newest file containing `rate_limits`, take the **last** occurrence; decode `primary`/`secondary` by `window_minutes` magnitude (≈300 → 5h, ≈10080 → weekly)
- Normalize resets: `resets_at` epoch → Date; else `resets_in_seconds` + event timestamp → Date
- Return raw parsed windows — expiry-zeroing happens in the shared display-time gate (see Key Technical Decisions), so cached and live data satisfy R9 identically
- Return `nil` (not throw) when no sessions/no rate_limits found; log via os.Logger
- Line-oriented scan (read file, split lines, scan from end) — avoid full JSONL object decoding; decode only the `rate_limits` fragment of matching lines

**Test scenarios:** (manual, against real `~/.codex/sessions` data)
- Happy path: current machine state → percentages match `codex` CLI's own status display within 1-2 points (data freshness skew allowed)
- Edge case: point reader at an empty/nonexistent sessions dir → returns nil, gauges show `--`, no crash
- Edge case: rollout file where the last rate_limits event's primary `resets_at` is in the past → 5h gauge shows 0%
- Edge case: hand-crafted line with `resets_in_seconds` variant → parses to a sane future Date

**Verification:**
- Snapshot values logged on refresh match the freshest session file's last rate_limits event

---

- [x] U4. **Claude limits fetcher**

**Goal:** Fetch official Claude 5h/weekly utilization via the OAuth usage endpoint using the locally stored Claude Code token.

**Requirements:** R8, R9

**Dependencies:** U3 (shared `LimitsData` models)

**Files:**
- Create: `CCUsageBar/CCUsageBar/ClaudeLimitsFetcher.swift`

**Approach:**
- Token acquisition, in order: (1) Process → `/usr/bin/security find-generic-password -a <NSUserName()> -s "Claude Code-credentials" -w`, parse `claudeAiOauth.accessToken`; (2) fallback `~/.claude/.credentials.json`, same shape. Reuse the CCUsageRunner Process pattern (terminationHandler + continuation, short timeout). Never log the token
- If `expiresAt` is in the past, skip the call and return nil (Claude Code will refresh it on its next run); no refresh flow of our own
- `GET https://api.anthropic.com/api/oauth/usage` via a URLSession built from `URLSessionConfiguration.ephemeral` (no persistent cache — the default shared cache can write the Authorization header to on-disk Cache.db, breaking the "never persisted" guarantee; don't rely on the server sending no-store), 10s timeout, headers: `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<current-version>` (required — omitting it triggers 429s). Note the ephemeral-session choice in decisions.md
- Decode `five_hour`/`seven_day` `{utilization, resets_at}` tolerantly (unknown fields ignored, either field nullable) → `ProviderLimits`; return raw values — expiry-zeroing happens in the shared display-time gate, same as Codex (R9)
- Any failure (no token, 401, 429, timeout, schema surprise) → nil + os.Logger; AppState holds last-known values per the U5 failure policy — `--` only if no fetch has ever succeeded (R9)

**Test scenarios:** (manual)
- Happy path: live call on this machine → utilization matches `/usage` inside Claude Code within a point or two
- Error path: temporarily rename the keychain lookup service string → nil, gauges `--`, app otherwise normal
- Error path: garble the token → 401 handled as nil, logged, no user-facing error
- Edge case: response with `five_hour: null`/absent (no active window) → 0% with empty gauge per the U5 display-state contract, no crash
- Edge case: response carrying a `resets_at` already in the past → gauge shows 0% via the shared expiry gate, not a stale nonzero percentage

**Verification:**
- Claude gauges populate with account-wide numbers matching Claude Code's `/usage`; failure modes degrade to `--` without touching the usage-data path

---

- [x] U5. **Limits state in AppState + limits section UI**

**Goal:** Popover renders the approved two-row limits portrait at the top, refreshed on the existing cadence, cached for instant relaunch display.

**Requirements:** R5, R6, R9, R10, R3

**Dependencies:** U3, U4 (data); U2 (shared provider colors)

**Files:**
- Create: `CCUsageBar/CCUsageBar/LimitsView.swift`
- Modify: `CCUsageBar/CCUsageBar/AppState.swift`, `CCUsageBar/CCUsageBar/PopoverContentView.swift`

**Approach:**
- AppState: `@Published var claudeLimits/codexLimits: ProviderLimits?`; `refresh()` runs usage fetch + both limit fetches concurrently (async let / task group) so one slow source can't block the others; results cached in UserDefaults with the existing cache pattern
- Derived helper for the menu bar: `hottestLimitPercent` = max of the four gauges (nil if all unavailable)
- LimitsView: two rows (CLAUDE, CODEX) per the approved mock — `5h ▓▓▓░ 62% ·2:14p  wk ▓▓▓▓ 78% ·Mon`; gauge = slim rounded capsule fill in the provider color; % in primary text; reset inline in dimmed caption (5h → localized short time, weekly → weekday abbreviation)
- Display-state contract (decided 2026-07-02): three distinct non-live states. (1) First uncached load → loading placeholder in the limits rows, mirroring dailyListSection's ProgressView pattern. (2) Inactive/reset window (API null or reset time passed) → 0% with empty gauge — a reset window is real data, not an error. (3) Missing window (partial data, fetch never succeeded) → `--` per individual gauge, so a present sibling window still renders live. Loading, zero, and broken must never look alike
- Failure policy (decided 2026-07-02): hold last-known values through transient failures (matches the existing usage-cache pattern where a failed refresh keeps old data); `--` appears only before the first-ever success. Staleness is bounded by the shared expiry gate — a stale 5h reading self-zeroes when its reset passes. The nightly expired-token 401 therefore never flaps the gauges
- Placement: top of `PopoverContentView`'s VStack, divider below, existing sections untouched; popover width stays 320
- Stale display: LimitsView and `hottestLimitPercent` read expiry-adjusted values through the shared display-time gate (see Key Technical Decisions) — a cached snapshot whose reset has passed renders 0%, never a stale hot percentage or a false menu-bar warning

**Execution note:** frontend-design pass applies — this is the hero section; keep it quiet (secondary-weight labels, no color except gauge fills, warning tint on a gauge only at ≥80%).

**Test scenarios:** (manual)
- Happy path: fresh refresh → all four gauges populated, resets formatted per spec (clock vs weekday)
- Edge case: kill network → Claude gauges `--`, Codex gauges still live, graph unaffected
- Edge case: relaunch app offline → cached limits render instantly
- Edge case: relaunch with a cached snapshot whose reset time has passed → affected gauges show 0%, menu bar shows no false ≥80% warning
- Integration: manual refresh button → limits and usage both update in one pass
- Layout: longest realistic strings (100% + "12:59p") at 320pt in both appearances → no truncation or wrapping

**Verification:**
- Popover matches the origin mockup; refresh timing unchanged; no regression in usage-data display

---

- [x] U6. **Menu bar label: cost + hottest limit, warning state**

**Goal:** Menu bar shows `$80 · 62%` (whole-dollar today cost + hottest limit) with a template-safe warning at ≥80%.

**Requirements:** R11, R12

**Dependencies:** U5 (`hottestLimitPercent`)

**Files:**
- Modify: `CCUsageBar/CCUsageBar/CCUsageBarApp.swift`, `CCUsageBar/CCUsageBar/AppState.swift`

**Approach:**
- AppState exposes a compact label model (whole-dollar cost string, optional hottest %, warning flag) so the App layer stays dumb
- `menuBarImage` renders `$80 · 62%`; when limits are unavailable, degrade to the current cost-only label; when usage data is missing but limits are available, render the percentage alone (never `-- · 62%`) — note in decisions.md
- Warning (≥80%): draw `exclamationmark.triangle.fill` before the percentage, keep `isTemplate = true` (Key Technical Decisions); consider `.semibold` percentage text for extra weight
- Keep the existing chart glyph and metrics; label width grows only by the ` · NN%` suffix

**Test scenarios:** (manual)
- Happy path: normal state → `$NN · NN%` renders crisply in light + dark menu bars
- Edge case: all limits unavailable → label falls back to `$NN.NN` exactly as today
- Edge case: usage data missing (ccusage failure, no cache) but limits available → label shows the percentage alone, not `-- · 62%`
- Edge case: force hottest ≥80% (stub value) → warning glyph appears, template rendering intact in both appearances
- Edge case: $0 day + 0% limits → `$0 · 0%` renders without layout collapse

**Verification:**
- Menu bar readable at a glance in both appearances; width acceptable alongside other status items

---

## System-Wide Impact

- **Refresh path:** `refresh()` fans out to three sources (ccusage, Codex files, Claude endpoint); failures must stay independent — usage data must never be blocked or blanked by a limits failure
- **Cache shape:** two new UserDefaults keys (limits snapshots); existing `cachedUsageResponse` untouched, so no cache-migration event like the v20 `period` rename
- **Network egress:** first-ever network call from this app (one HTTPS GET per refresh). Unsandboxed, so no entitlement changes; note it in decisions.md and README ("How It Works")
- **Credential handling:** app reads (never writes) the Claude Code token; token stays in memory only, never logged, never persisted by us
- **External-contract fragility:** the usage endpoint is undocumented and the Codex log format is explicitly evolving — both readers must fail to `--`, never to a broken popover
- **Unchanged invariants:** ccusage invocation (`daily --json --since`), 14-day window, cache decode path, 2-state error philosophy, 320pt popover width

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| OAuth usage endpoint changes or rejects the beta header (has happened) | Tolerant decoding; all failures → `--`; endpoint isolated in one file |
| 429s from missing/wrong User-Agent | Send `claude-code/<version>` UA; single call per 15-min cycle stays far under any sane limit |
| Codex rollout schema drift (`resets_at` vs `resets_in_seconds`, field renames) | Dual-variant parsing, magnitude-based window matching, nil on surprise |
| Keychain item shape drifts in future Claude Code versions | Shape verified on this machine (contains `claudeAiOauth`); credentials-file fallback; if both miss, Claude gauges show `--` |
| Menu bar label too wide | Whole-dollar cost; suffix degrades gracefully when limits unavailable; tune during U6 |
| Limits fetch slows the refresh loop | Concurrent fan-out with independent short timeouts (10s HTTP, existing 30s ccusage) |

---

## Documentation / Operational Notes

- decisions.md entries required (repo convention): security-CLI token read, network egress introduction, ephemeral URLSession for the credential-bearing request, shared display-time expiry gate, three-state gauge display contract, hold-last-known failure policy, template-safe warning treatment, menu-bar percentage-only fallback, no-test-target verification stance, provider color choices
- README "How It Works" + Features: mention Codex split, limits portrait, and the one network call

---

## Sources & References

- **Origin document:** docs/brainstorms/2026-07-02-codex-and-limits-requirements.md
- Endpoint + token storage: github.com/Maciek-roboblog/Claude-Code-Usage-Monitor#202, anthropics/claude-code#29783, #31021, #13770, code.claude.com/docs/en/authentication
- Codex schema: github.com/openai/codex#14728, ccusage.com/guide/codex, developers.openai.com/codex/changelog
- Prior art: github.com/steipete/codexbar, github.com/xiangz19/codex-ratelimit
