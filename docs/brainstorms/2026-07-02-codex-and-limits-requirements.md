---
date: 2026-07-02
topic: codex-and-limits
---

# Codex Visibility + Usage Limit Portrait

## Problem Frame

CCUsageBar shows "Claude Code" spend, but since the ccusage v20 upgrade the plain `ccusage daily` call the app makes already aggregates **all** detected agent CLIs — Codex (gpt-5.5 / gpt-5.4-mini) usage is silently blended into every bar and total. Scott can't see how spend splits between Claude and Codex, and the app says nothing about the thing that actually constrains his day: hourly (5h) and weekly rate limits on both subscriptions. This work (1) makes the Claude/Codex split visible in the existing graph, and (2) adds a limits portrait — four gauges (Claude 5h, Claude weekly, Codex 5h, Codex weekly) with reset times — as the top section of the popover, plus a hottest-limit indicator in the menu bar.

---

## Requirements

**Provider split in the 7-day graph**
- R1. Each day's bar becomes a stacked bar: a Claude segment (existing orange) and a Codex segment (a second, visually distinct color), proportional to each provider's cost that day. Day total cost/tokens on the right stay combined, unchanged.
- R2. Provider classification is derived from the existing single `ccusage daily --json` response via per-model breakdowns: `claude-*` → Claude, `gpt-*` → Codex. Any other model names group into a neutral "other" segment (rendered only if present). No second ccusage invocation.
- R3. Provider colors are consistent everywhere they appear (bar segments, limits rows) so no legend is strictly required; a minimal legend is acceptable if it fits without growing the layout materially.
- R4. The "Last 14 Days" total row stays combined (no per-provider split there in v1).

**Limits portrait**
- R5. A new limits section sits at the top of the popover, above the 7-day graph: one compact row per provider (CLAUDE, CODEX), each row containing a 5h gauge and a weekly gauge.
- R6. Each gauge shows a small progress bar plus the used percentage, with the reset time inline after the % in dimmed secondary text — clock time for 5h windows (e.g. `·2:14p`), day for weekly windows (e.g. `·Mon`). Approved layout:
  ```
  CLAUDE  5h ▓▓▓░ 62% ·2:14p  wk ▓▓▓▓ 78% ·Mon
  CODEX   5h ▓▓░░ 38% ·3:04p  wk ▓▓░░ 35% ·Tue
  ```
- R7. Codex limit data comes from the newest Codex session rollout file (`~/.codex/sessions/<year>/<month>/<day>/*.jsonl`), last `rate_limits` event: `primary` = 5h window, `secondary` = weekly, both carrying official `used_percent` and `resets_at`. Verified present on this machine.
- R8. Claude limit data comes from Anthropic's OAuth usage endpoint (`api.anthropic.com/api/oauth/usage`) using the Claude Code OAuth token from the macOS keychain — the same account-wide percentages `/usage` shows.
- R9. Stale/missing handling: if a Codex `resets_at` has passed, treat that window as reset (show 0%). If a provider's limit data is unavailable (no token found, endpoint failure, no Codex sessions), its gauges show `--` rather than an error state — consistent with the app's 2-state error philosophy.
- R10. Limits refresh on the same cadence as usage data (15-minute loop + manual refresh button).

**Menu bar label**
- R11. The menu bar label shows today's combined cost plus the hottest of the four limit percentages, e.g. `$80 · 62%` (cost rendered in whole dollars to conserve menu bar width).
- R12. When any limit is ≥ 80%, the label visually signals warning. Exact treatment (glyph prefix, weight, or color) is a design decision at implementation — constrained by the label being a template NSImage.

---

## Success Criteria

- One glance at the popover answers: how close am I to each rate limit, when do they reset, and how does today's spend split between Claude and Codex.
- Menu bar answers "am I about to hit a wall?" without opening the popover.
- The Codex percentages match `codex` CLI's own status display; Claude percentages match `/usage` in Claude Code.
- No new external dependencies: existing ccusage binary, local file reads, and one HTTPS call.
- Popover keeps its current width (320pt) and grows only by the two limits rows.

---

## Scope Boundaries

- No per-provider split of the 14-day total row (v1 keeps it combined).
- No provider toggle/tabs, no per-model drill-down.
- No notifications/alerts when limits get hot — the menu bar warning state is the only signal in v1.
- No support for other agents (Gemini, Copilot, etc.) beyond lumping their cost into the "other" segment.
- No configurable thresholds or refresh intervals.

---

## Key Decisions

- **Stacked segments over paired bars or tabs**: zero layout growth, comparison visible at a glance; paired bars doubled popover height, tabs hid the comparison behind a click.
- **Limits as the top/hero section, compact two-row form with inline resets**: limits are the actionable number; chosen over a 2×2 grid (taller) and hover-only resets (no glance value).
- **Derive provider split from the existing single ccusage call** via model-name classification rather than running `ccusage claude daily` + `ccusage codex daily` separately: one process instead of two, no schema drift risk between subcommands (claude uses `period`/`totalCost`, codex uses `date`/`costUSD`), and totals stay internally consistent.
- **Official limit percentages over local estimation**: Codex percentages are already recorded locally by the CLI; Claude's OAuth endpoint returns account-wide truth (multi-machine correct — matters given OpenClaw/remote usage). `ccusage blocks` estimation is the fallback only if the OAuth path fails at implementation.
- **Menu bar = cost + hottest limit %**: cost keeps the app's original glance value; the hottest limit is the single most actionable addition.

---

## Dependencies / Assumptions

- ccusage v20+ installed globally (already required; v20's plain `daily` aggregating all agents is what makes R2 possible).
- Codex CLI writes `rate_limits` events into session rollouts (verified 2026-07-02 on this machine; format could change with Codex releases).
- The Claude Code OAuth token is retrievable from the macOS keychain by a native app, and the `api.anthropic.com/api/oauth/usage` endpoint returns 5h/weekly utilization for it. **Unverified end-to-end** — a probe of the `Claude Code-credentials` keychain item surfaced only an `mcpOAuth` blob; the token likely lives in another item/account under the same service, but this needs verification during implementation. Confidence: moderate-high.
- App remains unsandboxed (needed for Process, keychain, and `~/.codex` reads).

---

## Outstanding Questions

### Deferred to Planning

- [Affects R8][Needs research] Locate the exact keychain item/attribute holding the Claude Code OAuth access token, confirm the usage endpoint's request shape (headers, beta flag) and response schema, and handle token refresh/expiry. If the path dead-ends, fall back to `ccusage blocks`-based estimation and note it in decisions.md.
- [Affects R7][Technical] Efficient newest-rollout-file discovery in `~/.codex/sessions/` (directory dates vs file mtimes) and tail-reading the last `rate_limits` event without parsing whole multi-MB JSONL files.
- [Affects R1, R6][Design] Codex segment/gauge color selection and gauge micro-styling. Apply frontend-design principles (hierarchy, restrained palette, monospaced numerals) during implementation; the ASCII mockups above are the approved layout spec.
- [Affects R12][Technical] Warning treatment compatible with the template-NSImage menu bar rendering (template images are monochrome; a color warning may require dropping `isTemplate` conditionally).

---

## Next Steps

-> /ce-plan for structured implementation planning
