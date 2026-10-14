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

        let claude = await ClaudeLimitsFetcher().fetchLimits()
        print("Claude live limits via Keychain: \(claude != nil ? "ok" : "FAILED")")
        if claude == nil { passed = false }

        let codex = await CodexLimitsReader().fetchLimits()
        print("Codex local log read: \(codex != nil ? "ok" : "no snapshot found")")

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
