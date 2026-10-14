import Foundation

// TEMPORARY feasibility check (plan U1). Run the signed binary directly:
//   CCUsageBar.app/Contents/MacOS/CCUsageBar --smoke-check
//   CCUsageBar.app/Contents/MacOS/CCUsageBar --smoke-delete
// Proves the existing collectors still work under the new signature, then
// writes the synthetic CloudKit record. Remove before live use.
enum MacSmokeCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--smoke-check") || args.contains("--smoke-delete") else { return }
        let deleteOnly = args.contains("--smoke-delete")
        Task.detached {
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
