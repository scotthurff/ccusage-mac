# iPhone Widget: Setup, Maintenance, and Feasibility Record

How the personal iPhone widget is installed and kept working, followed by the evidence gathered when it was first proven. No credentials, emails, or account identifiers belong in this file.

## How it fits together

1. The menu bar app reads Claude and Codex limits on the Mac at launch, on manual refresh, and every 15 minutes.
2. After each round it publishes one snapshot of limit values to a private CloudKit record in your own iCloud: container `iCloud.com.ccusagebar`, record `latest-quota-snapshot`.
3. The iPhone app and widget fetch that record and share a local copy in the App Group `group.com.ccusagebar`.
4. Every reading keeps the time the provider reported it. Fetching, caching, and uploading never make it look newer.

The Mac must be awake and running the menu bar app for readings to move. Nothing is collected while it sleeps.

## Requirements

- A paid Apple Developer Program membership. The free tier cannot use iCloud. The team is set in the project (`DEVELOPMENT_TEAM`).
- Xcode with that Apple account signed in (Settings → Accounts) and the iOS platform installed (Settings → Components).
- The iPhone connected once by cable, trusted, with Developer Mode on (Settings → Privacy & Security → Developer Mode). The switch appears only after Xcode has tried to install something.
- The Mac and iPhone signed into the same iCloud account.

## Install or update the Mac app

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsageBar -configuration Release -allowProvisioningUpdates build
```

Quit the running menu bar app, replace `/Applications/CCUsageBar.app` with the built copy, and open it. Keep the same path so the login item keeps working.

## Install or update the iPhone app and widget

With the phone connected (cable or the same network) and unlocked:

```sh
cd CCUsageBar
xcodebuild -project CCUsageBar.xcodeproj -scheme CCUsagePhone -configuration Debug -destination 'platform=iOS,name=<phone name>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <phone name or id> ~/Library/Developer/Xcode/DerivedData/CCUsageBar-*/Build/Products/Debug-iphoneos/CCUsagePhone.app
```

Running the `CCUsagePhone` scheme from Xcode onto the phone does the same.

To add the widget: long-press the Home Screen → Edit → Add Widget → search "CCUsage" → "Claude & Codex limits" → pick small, medium, or large.

## Reading the widget and app

- **"12 minutes ago" / "Read on your Mac 12 minutes ago"**: when the Mac took the reading, not when the phone fetched it. Refreshing on the phone does not change it.
- **Gray name and bars, "Outdated"**: the reading is an hour old or more, or the Mac's last attempt for that provider failed. The number shown is the last known value.
- **"reset passed" / "reset 4:29 PM, unconfirmed"**: the window's reset time has passed but no newer reading has confirmed the new value. The old number stays; it is never shown as 0%.
- **"No reading yet"**: that provider has never been read successfully under the current accounts.
- **"Waiting for your Mac's first reading"**: iCloud works but the Mac has not published yet.
- **"iCloud is off on this iPhone"**: sign the phone into iCloud.
- **Small size**: one line per limit without reset times. A model cap such as Fable appears only when it is closer to its limit than every account-wide window.
- **Codex extras**: "3 full resets · next expires Oct 22" counts Codex's full-reset credits; the credit balance is a raw number of Codex credits.

iOS decides when widgets refresh, usually every 30 to 60 minutes. Opening the app fetches the latest snapshot and asks the widget to redraw.

## Renewal

- The Apple Development certificate and all three provisioning profiles expire on **2027-10-14**. The membership also renews yearly from 2026-10-14.
- When a profile expires, the phone app stops opening. Renew the membership if needed, then rebuild and reinstall both apps as above. `-allowProvisioningUpdates` creates fresh profiles.
- Reinstalling over the existing apps keeps the widget on the Home Screen and the cached readings.

## iCloud environment

All three targets are development builds and use CloudKit's Development environment, so they see the same record. A TestFlight or App Store build would use the Production environment and see no data from a development Mac build. Keep the Mac and phone builds in the same environment.

## Troubleshooting

- **Claude stays gray or "No reading yet"**: the Claude Code login on the Mac may have expired. Run `claude` in a terminal and sign in with `/login`, then click refresh in the menu bar.
- **Codex stays gray**: run `codex login` on the Mac. Only ChatGPT logins report account limits; an API-key login is treated as unsupported. If the Codex CLI moved, clear the cached path with `defaults delete com.ccusagebar codexBinaryPath` and relaunch the menu bar app.
- **The widget's age keeps growing**: check that the Mac is awake and the menu bar app is running. Then open the phone app to fetch the latest snapshot.
- **"Bad Container" right after a new container is created**: Apple's servers need several minutes to set it up. Retry later.
- **Switching iCloud accounts**: the Mac and phone discard readings tied to the previous account and wait for fresh ones. Nothing from the old account is published into the new one.

## Project shape

- Apps: `CCUsageBar` (macOS 14+, unsandboxed), `CCUsagePhone` (iOS 17+), `CCUsageWidget` (WidgetKit extension embedded in the phone app).
- Tests: `CCUsageSharedTests` and `CCUsageBarTests` (macOS), `CCUsagePhoneTests`, `CCUsageWidgetTests`, and `CCUsagePhoneUITests` (iOS Simulator). Each has a shared scheme.
- Bundle identifiers: `com.ccusagebar`, `com.ccusagebar.phone`, `com.ccusagebar.phone.widget`.
- iCloud container `iCloud.com.ccusagebar` on all three apps; App Group `group.com.ccusagebar` on the phone app and widget.
- Signing: Apple Development, automatic, one team for all targets.

## Feasibility record (2026-10-14)

The plan's first unit (U1) required proof that signing, private iCloud delivery, and live account limits worked on the real devices before the feature was built.

| Check | Status | Evidence |
| --- | --- | --- |
| Paid Apple Developer membership signed into Xcode | Met | Team YT4ALW7VT7 active. Xcode created an Apple Development certificate and profiles for all three bundle identifiers through `-allowProvisioningUpdates`. |
| iOS platform installed in Xcode | Met | iOS 26.5 platform and simulators installed. |
| iPhone connected, trusted, Developer Mode on | Met | Developer Mode on; the phone was registered to the team by a device build; the signed app installed with `xcrun devicectl device install app`. |
| Phone iOS version supported by installed Xcode | Met | iPhone on iOS 26.6.2; Xcode 26.6 lists it as a run destination. |
| Signed Mac app writes a synthetic iCloud record, sandbox off | Met | The signed Release build had the container entitlement and no sandbox key. The first write failed with "Bad Container" right after Xcode registered the container; about ten minutes later the write and read-back succeeded. |
| Phone app and widget read the record, widget with the app closed | Met | The phone app showed the Mac's nonce 4235041E. With the app confirmed not running, the Mac wrote A484BA7B; Scott re-added the test widget and it showed A484BA7B. The app had no channel to the widget at the time (no shared App Group, no reload call), so the value came from the extension's own iCloud fetch. |
| Mac collectors still work under the new signature | Met | The Claude Keychain read, the Codex read, and the ccusage process all worked under Apple Development signing. |
| Current Codex account limits readable without a model turn | Met | See "Codex account limits" below. |
| Cloud or remote Codex work moves the live reading | Met for Scott's usage; cloud unverified | During Scott's Codex work the live read showed 18% at 2:03:29 PM and the local log 18% at 2:03:27 PM. Work on this Mac, including phone sessions that control it, reaches the live read within seconds. Scott rarely uses cloud tasks; verify one when it happens. |

The temporary smoke-test code (a synthetic record, a Mac `--smoke-check` mode, a test widget, and an app test section) was removed after these checks passed, and the synthetic record was deleted from the private database.

### End-to-end on the real devices

- The signed menu bar app replaced the ad-hoc copy in `/Applications`. The old copy is kept as `/Applications/CCUsageBar-old.app`. The login item still points to `/Applications/CCUsageBar.app`.
- On first launch the new app collected both providers and published revision 5 to the private record, with nothing left pending.
- Scott opened the updated phone app and it showed the Mac's readings. He added the "Claude & Codex limits" widget, which showed them too.
- Scott confirmed the remaining device checks on 2026-10-14: a pull-to-refresh kept the Mac's reading age, an offline (Airplane Mode) launch showed the saved readings with their age, and the widget kept updating with the app closed as the Mac published.
- After the code review fixes, the reinstalled menu bar app published through revision 10 with nothing pending.
- The phone app with the code review fixes was installed over the earlier build, keeping its cached readings. On first launch it replaced them with the Mac's latest snapshot (revision 27) and showed the reading as taken "just now".

### Codex account limits

Validated against Codex CLI 0.154.0 (`~/.local/bin/codex`, a link into `~/.codex/packages/standalone/current/bin/codex`).

- `codex app-server` over standard input and output. Sequence: `initialize`, the `initialized` notice, `account/read` with `refreshToken: false`, then `account/rateLimits/read` with `excludeResetCreditDetails: false`. Reset-credit expiry dates require the details. Closing standard input ends the process. No model turn starts.
- Never send `supportsLunaReserve`; it lets the backend record experiment exposure. Never call `account/rateLimitResetCredit/consume`, `account/logout`, or `account/sendAddCreditsNudgeEmail`.
- The process emits `remoteControl/status/changed` with status `disabled`. A standalone app-server does not join remote control, so it does not disturb phone sessions.
- Result: ChatGPT login, Pro plan. `rateLimitsByLimitId` has one bucket, `codex`, which reports only a 10,080-minute (weekly) window, in the `primary` position, with `usedPercent` as a whole number. This confirms the rule to classify windows by duration, not position.
- Scott's shell defines a `codex` function, so the app finds the binary with `zsh -lc 'whence -p codex'`.

### Claude account limits

- The Mac app reads the Claude Code login from the Keychain through `/usr/bin/security`, not under the app's own signature, so re-signing the app did not change that access.
- Identity signals used only as local hashes: `~/.claude.json` `oauthAccount.accountUuid` and `organizationUuid`.
