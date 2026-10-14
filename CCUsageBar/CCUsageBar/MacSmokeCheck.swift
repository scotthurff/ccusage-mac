import CloudKit
import Foundation

// TEMPORARY feasibility check (plan U1). Run the signed binary directly:
//   CCUsageBar.app/Contents/MacOS/CCUsageBar --smoke-check
//   CCUsageBar.app/Contents/MacOS/CCUsageBar --smoke-delete
//   CCUsageBar.app/Contents/MacOS/CCUsageBar --publish-check
// Proves the existing collectors still work under the new signature, then
// writes the synthetic CloudKit record. Remove before live use.
enum MacSmokeCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--smoke-check") || args.contains("--smoke-delete") || args.contains("--publish-check") else { return }
        let deleteOnly = args.contains("--smoke-delete")
        let publishOnly = args.contains("--publish-check")
        Task.detached {
            if publishOnly { exit(await publishCheck()) }
            exit(deleteOnly ? await delete() : await run())
        }
        dispatchMain()
    }

    private static func run() async -> Int32 {
        var passed = true
        print("CCUsageBar smoke check (synthetic, temporary)")

        // Prints limit values and dates only: never tokens, emails, or account ids.
        let claude = await ClaudeLimitsFetcher().collect()
        print("Claude live limits via Keychain: \(claude.observation != nil ? "ok" : "FAILED")")
        print("Claude account identity signal: \(claude.accountKey != nil ? "present" : "missing")")
        claude.observation.map(describe)
        if claude.observation == nil { passed = false }

        let started = Date()
        let codex = await CodexLimitsClient().read()
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        switch codex {
        case .success(let reading):
            print("Codex current limits via app-server: ok in \(seconds)s")
            print("Codex account identity signal: \(reading.accountKey != nil ? "present" : "missing")")
            describe(reading.observation)
        case .failure(let failure):
            print("Codex current limits via app-server: FAILED (\(failure)) after \(seconds)s")
            passed = false
        }

        do {
            let usage = try await CCUsageRunner().fetchUsage(since: await AppState.sinceDateString())
            print("ccusage Process: ok (\(usage.daily.count) days)")
        } catch {
            print("ccusage Process: FAILED \(error)")
            passed = false
        }

        print("iCloud account: \(await CloudKitSmoke.accountStatusDescription())")
        do {
            let written = try await CloudKitSmoke.write(writer: "mac")
            print("CloudKit write: ok nonce=\(written.nonce) at \(written.writtenAt)")
            let readBack = try await CloudKitSmoke.read()
            print("CloudKit read-back: \(readBack?.nonce == written.nonce ? "ok" : "MISMATCH")")
            if readBack?.nonce != written.nonce { passed = false }
        } catch {
            print("CloudKit write: FAILED \(error)")
            passed = false
        }
        return passed ? 0 : 1
    }

    private static func describe(_ observation: QuotaObservation) {
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm zzz"
        print("  observed \(time.string(from: observation.observedAt))")
        for window in observation.windows {
            let reset = window.resetsAt.map { ", resets \(time.string(from: $0))" } ?? ""
            let length = window.durationMinutes.map { "\($0) min" } ?? "unknown length"
            print("  \(window.label) [\(window.scope.rawValue), \(length)]: \(window.usedPercent)% used\(reset)")
        }
        if let credits = observation.resetCredits {
            let expiry = credits.nextExpiry.map { ", next expires \(time.string(from: $0))" } ?? ""
            print("  full reset credits: \(credits.available) available\(expiry)")
        }
        if observation.creditBalance != nil { print("  credit balance: present") }
    }

    // Collects both providers with the real collectors and publishes through
    // the real publisher into the private record the phone reads, twice, then
    // reads it back the way the phone does. It also confirms that CloudKit
    // refuses the two writes the publisher relies on being refused; each
    // carries the record's current contents, so even a wrong answer changes
    // nothing. Settings go to a separate suite, removed at the end, so the
    // installed app's settings are untouched. Prints values and dates only.
    @MainActor
    private static func publishCheck() async -> Int32 {
        print("CCUsageBar publish check (real readings, private iCloud record)")
        guard CloudKitQuotaDatabase.isEntitled else {
            print("iCloud entitlement: MISSING")
            return 1
        }
        let suiteName = "com.ccusagebar.publish-check"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return 1 }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let database = CloudKitQuotaDatabase()
        switch await database.account() {
        case .available: print("iCloud account: available")
        case .noAccount: print("iCloud account: none"); return 1
        case .unavailable: print("iCloud account: unavailable"); return 1
        }
        print("Before:")
        describe(await CloudQuotaStore().fetchLatest())

        var passed = true
        let publisher = QuotaPublisher(database: database, defaults: defaults)
        let state = AppState(defaults: defaults, publisher: publisher, startsAutomatically: false)
        var staleCopy: FetchedQuotaRecord?
        for round in 1...2 {
            await state.refreshQuotas()
            await publisher.waitUntilIdle()
            let collected = state.providerSlots
                .map { "\($0.provider.rawValue) \($0.observation != nil ? "ok" : "FAILED")" }
                .joined(separator: ", ")
            let sent = publisher.pending == nil
            print("Round \(round): collected \(collected); publish \(sent ? "ok" : "NOT SENT"), revision \(publisher.baseline?.revision ?? -1)")
            if !sent || state.providerSlots.contains(where: { $0.observation == nil }) { passed = false }
            if round == 1 { staleCopy = try? await database.fetch() }
        }

        guard case .snapshot(let current, let metadata) = await CloudQuotaStore().fetchLatest() else {
            print("Read-back: FAILED")
            return 1
        }
        // Compared as the payload carries them: JSON keeps dates to about a
        // ten-millionth of a second.
        var expected = current
        expected.providers = state.providerSlots
        let encodedLocally = (try? expected.encoded()).flatMap { try? QuotaSnapshot.decode(from: $0).get() }
        let matches = encodedLocally?.providers == current.providers
        print("Read-back matches the Mac's readings and their dates: \(matches ? "yes" : "NO")")
        if !matches || metadata.revision != publisher.baseline?.revision { passed = false }

        // A copy fetched before the latest save, and a new record under the same name.
        let probes: [(String, CKRecord?)] = [("stale copy", staleCopy?.record),
                                             ("second new record", CloudQuotaWriter.newRecord(incarnation: metadata.incarnation))]
        for (name, record) in probes {
            guard let record else {
                print("Refusal of a \(name): SKIPPED")
                passed = false
                continue
            }
            do {
                try CloudQuotaWriter.fill(record, with: current)
                _ = try await database.saveIfUnchanged(record)
                print("Refusal of a \(name): NOT REFUSED")
                passed = false
            } catch let error as CKError where error.code == .serverRecordChanged {
                print("Refusal of a \(name): ok (server record changed)")
            } catch {
                print("Refusal of a \(name): unexpected \((error as NSError).domain) \((error as NSError).code)")
                passed = false
            }
        }

        print("After:")
        describe(await CloudQuotaStore().fetchLatest())
        print(passed ? "PASSED" : "FAILED")
        return passed ? 0 : 1
    }

    private static func describe(_ result: CloudFetchResult) {
        guard case .snapshot(let snapshot, let metadata) = result else {
            print("  record: \(result)")
            return
        }
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        print("  revision \(metadata.revision), incarnation \(metadata.incarnation.prefix(8))..., created \(time.string(from: metadata.incarnationCreatedAt)), published \(time.string(from: snapshot.publishedAt))")
        let phone = QuotaPresentation(now: Date())
        for slot in snapshot.providers {
            let attempt = slot.lastAttempt.map { "\($0.outcome.rawValue) at \(time.string(from: $0.at))" } ?? "none"
            print("  \(slot.provider.rawValue): attempt \(slot.acceptedAttempt), last \(attempt), phone shows \(phone.provider(slot).freshness)")
            slot.observation.map(describe)
        }
    }

    private static func delete() async -> Int32 {
        do {
            try await CloudKitSmoke.delete()
            print("Synthetic record deleted")
            return 0
        } catch {
            print("Delete FAILED \(error)")
            return 1
        }
    }
}
