# iPhone Widget Setup and Feasibility Record

Evidence for the plan's first unit (U1): signing, private iCloud delivery, and current account limits. No credentials, emails, or account identifiers belong in this file.

## Checklist status

| Check | Status | Evidence |
| --- | --- | --- |
| Paid Apple Developer membership signed into Xcode | Not met | 2026-10-14: no Apple account in Xcode, no signing certificates, no provisioning profiles |
| iOS platform installed in Xcode | Not met | 2026-10-14: Xcode 26.6 reports "iOS 26.5 is not installed"; no simulator runtimes |
| iPhone connected, trusted, Developer Mode on | Not met | 2026-10-14: `xcrun devicectl list devices` finds no devices |
| Phone iOS version supported by installed Xcode | Unknown | Read from the device once connected |
| Signed Mac app writes the synthetic iCloud record, sandbox off | Not run | Needs signing |
| Phone app and widget read the record, widget with app closed | Not run | Needs signing and device |
| Mac collectors still work under the new signature | Not run | Needs signing |
| Current Codex account limits readable without a model turn | Met | See below |
| Cloud or remote Codex work moves the live reading | Open | Baseline recorded; waiting for ordinary cloud or remote work |

## Project shape

- Targets: `CCUsageBar` (macOS 14+, unsandboxed), `CCUsagePhone` (iOS 17+), `CCUsageWidget` (WidgetKit extension embedded in the phone app).
- Bundle identifiers: `com.ccusagebar`, `com.ccusagebar.phone`, `com.ccusagebar.phone.widget`.
- iCloud container: `iCloud.com.ccusagebar`, CloudKit Development environment, private database, on all three targets.
- Signing: Apple Development, automatic, one team for all targets. The team identifier is added once an account is signed into Xcode.
- Shared schemes: `CCUsageBar`, `CCUsagePhone`, `CCUsageWidget`.

## Temporary smoke test

These files exist only for this check and must be removed before live use:
`CCUsageBar/Shared/CloudKitSmoke.swift`, `CCUsageBar/CCUsageBar/MacSmokeCheck.swift`, the smoke screen in `CCUsagePhoneApp.swift`, the smoke widget in `CCUsageWidget.swift`, and the `MacSmokeCheck.runIfRequested()` call in `CCUsageBarApp.swift`.

They read and write one record, `synthetic-smoke-test`, labeled "SYNTHETIC SMOKE TEST - not usage data". It holds a random nonce, a write time, and the writer name.

Steps once signing works:
1. Build and sign the Mac app, then run `CCUsageBar.app/Contents/MacOS/CCUsageBar --smoke-check`. It checks the Claude Keychain read, the Codex log read, and the ccusage process, then writes and reads back the record.
2. Install the phone app on the iPhone. Open it and confirm it shows the Mac's nonce.
3. Add the large widget. Force-quit the app. Run the Mac check again so a new nonce is written. Remove and re-add the widget, or wait for its refresh. The widget must show the new nonce while the app stays closed.
4. Sign the phone out of iCloud, or point it at a different environment. It must show a failure, not a reading.
5. Run `CCUsageBar --smoke-delete` to remove the record.

## Codex current account limits

Validated 2026-10-14 against Codex CLI 0.154.0 (`~/.local/bin/codex`, a link into `~/.codex/packages/standalone/current/bin/codex`).

- `codex app-server` over standard input and output. Sequence: `initialize`, the `initialized` notice, `account/read` with `refreshToken: false`, then `account/rateLimits/read` with `excludeResetCreditDetails: true`. Close standard input to end the process. No model turn starts.
- Do not send `supportsLunaReserve`. It lets the backend record experiment exposure.
- Never call `account/rateLimitResetCredit/consume`, `account/logout`, or `account/sendAddCreditsNudgeEmail`.
- The process emits `remoteControl/status/changed` with status `disabled`. A standalone app-server does not join remote control, so it does not disturb phone sessions.
- Result: ChatGPT login, Pro plan. `rateLimitsByLimitId` is present with one bucket, `codex`. That bucket reports only a 10,080-minute (weekly) window, in the `primary` position, with `usedPercent` as a whole number. No five-hour window is reported. This confirms the plan's rule to classify windows by duration, not position.
- Identity signals available without copying them here: `account/rateLimits/read` returns an account identifier, and `account/read` returns the login email and plan type.
- Baseline for the cloud check: 13% used at 11:26 AM Pacific on 2026-10-14, weekly reset October 19 at 10:15 PM Pacific. The newest local log snapshot showed 11% at 10:05 AM. That gap hints that the live read sees usage the logs miss, but it is not proof.

## Claude current account limits

- The Mac app reads the Claude Code login from the Keychain through `/usr/bin/security`, not under the app's own signature. Re-signing the app should not change that access. Confirm with the Mac smoke check.
- Identity signals: `~/.claude.json` holds `oauthAccount.accountUuid` and `organizationUuid`.
