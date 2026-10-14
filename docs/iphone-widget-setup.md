# iPhone Widget Setup and Feasibility Record

Evidence for the plan's first unit (U1): signing, private iCloud delivery, and current account limits. No credentials, emails, or account identifiers belong in this file.

## Checklist status

| Check | Status | Evidence |
| --- | --- | --- |
| Paid Apple Developer membership signed into Xcode | Met | 2026-10-14: team YT4ALW7VT7 active. Xcode created an Apple Development certificate and profiles for all three bundle identifiers through `-allowProvisioningUpdates`. |
| iOS platform installed in Xcode | Met | 2026-10-14: iOS 26.5 platform and simulators installed |
| iPhone connected, trusted, Developer Mode on | Met | 2026-10-14: Developer Mode on; phone registered to the team by a device build; signed app installed with `xcrun devicectl device install app` |
| Phone iOS version supported by installed Xcode | Met | iPhone on iOS 26.6.2; Xcode 26.6 lists it as a run destination |
| Signed Mac app writes the synthetic iCloud record, sandbox off | Met | 2026-10-14: signed Release build has the container entitlement and no sandbox key. First write failed with "Bad Container" right after Xcode registered the container; about ten minutes later the write and read-back succeeded. |
| Phone app and widget read the record, widget with app closed | Met | 2026-10-14: the phone app showed the Mac's nonce 4235041E. With the app confirmed not running, the Mac wrote A484BA7B; Scott re-added the "CCUsage iCloud test" widget and it showed A484BA7B. The app was running again by the time of a later check, but the app has no channel to the widget (no shared App Group, no reload call), so the value can only have come from the extension's own iCloud fetch. |
| Mac collectors still work under the new signature | Met | 2026-10-14: smoke check reported the Claude Keychain read, the Codex log read, and the ccusage process all ok under Apple Development signing |
| Current Codex account limits readable without a model turn | Met | See below |
| Cloud or remote Codex work moves the live reading | Met for Scott's usage; cloud unverified | 2026-10-14: during Scott's ongoing Codex work, the live read showed 18% at 2:03:29 PM and the local log 18% at 2:03:27 PM. Work on this Mac, including phone sessions that control it, reaches the live read within seconds. Scott rarely uses cloud tasks; verify one when it happens. The final end-to-end test repeats this. |

## End-to-end on the real devices

- 2026-10-14: the signed menu bar app (team YT4ALW7VT7) replaced the ad-hoc copy in `/Applications`. The old copy is kept as `/Applications/CCUsageBar-old.app`. The login item still points to `/Applications/CCUsageBar.app`.
- On first launch the new app collected both providers and published revision 5 to the private record, with nothing left pending.
- Scott opened the updated phone app: it showed the Mac's readings. He added the "Claude & Codex limits" widget, which showed them too.
- Still to observe: the widget refreshing in the background with the app closed, a pull-to-refresh keeping the Mac's reading age, and offline launch with cached data.

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
3. Add the large "CCUsage iCloud test" widget (not "Claude & Codex limits", which shows preview data). Force-quit the app. Run the Mac check again so a new nonce is written. Remove and re-add the widget, or wait for its refresh. The widget must show the new nonce while the app stays closed.
4. Sign the phone out of iCloud, or point it at a different environment. It must show a failure, not a reading.
5. Run `CCUsageBar --smoke-delete` to remove the record.

## Simulator check (packaging only)

2026-10-14, iPhone 17 Pro Max simulator, iOS 26.5, unsigned team. This does not count toward the signed checks above.

- `CCUsagePhone` builds with the widget embedded under `PlugIns/`. Both binaries carry the iCloud container entitlement.
- The app launches. With no iCloud account in the simulator it shows "no iCloud account" and "Fetch failed: This request requires an authenticated account". It shows no reading, which is the required failure behavior.
- iOS registered the widget: the system logged its description and its single large size, and started the extension process.
- Simulated taps could not open the widget picker; it logged "No suggestions file found" and closed. Scott added the large widget by hand. It rendered "SYNTHETIC SMOKE TEST", "Fetch failed: This request requires an authenticated account", and its own fetch time. The extension made its own iCloud request and showed the failure, not a reading.

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
