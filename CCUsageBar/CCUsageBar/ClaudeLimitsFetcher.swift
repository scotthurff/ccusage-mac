import Foundation
import os

actor ClaudeLimitsFetcher: QuotaCollector {
    static let source = "claude-oauth-usage"
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "claudelimits")

    // Load-bearing: omitting a claude-code User-Agent routes requests into a
    // strictly rate-limited bucket (persistent 429s).
    private static let userAgent = "claude-code/2.0.0"

    // The account is read from local config even when the request fails, so
    // a switched account never inherits the previous account's readings.
    func collect() async -> QuotaCollectionResult {
        let accountKey = Self.readAccountKey()
        return QuotaCollectionResult(accountKey: accountKey, observation: await fetchObservation())
    }

    private func fetchObservation() async -> QuotaObservation? {
        guard let token = await resolveAccessToken() else {
            Self.logger.info("No usable Claude Code OAuth token; skipping usage fetch")
            return nil
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // Ephemeral session: the default shared URLCache can persist the
        // Authorization header to disk (Cache.db); don't rely on server no-store.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.logger.error("Usage endpoint returned status \(status)")
                return nil
            }
            // Observed when the live response arrived.
            return Self.parseUsage(data, observedAt: Date())
        } catch {
            Self.logger.error("Usage fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Response parsing

    static func parseUsage(_ data: Data, observedAt: Date) -> QuotaObservation? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Self.logger.error("Usage response was not a JSON object")
            return nil
        }
        // Key present with null = no active window = a confirmed 0%;
        // key absent or malformed = schema surprise = unknown (no window).
        var windows: [QuotaWindow] = []
        if let fiveHour = parseWindow(obj["five_hour"]) {
            windows.append(fiveHourWindow(fiveHour.percent, resetsAt: fiveHour.resetsAt))
        }
        if let weekly = parseWindow(obj["seven_day"]) {
            windows.append(weeklyWindow(weekly.percent, resetsAt: weekly.resetsAt))
        }
        guard !windows.isEmpty else {
            Self.logger.error("Usage response missing five_hour and seven_day")
            return nil
        }
        windows += scopedWindows(obj["limits"])
        return QuotaObservation(source: source, observedAt: observedAt, windows: windows,
                                resetCredits: nil, creditBalance: nil)
    }

    // Per-model weekly caps (e.g. Fable) from the `limits[]` array:
    // {kind: "weekly_scoped", percent, resets_at, scope.model.display_name}.
    // The whole list is replaced on every read, so a removed cap disappears.
    private static func scopedWindows(_ value: Any?) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for case let entry as [String: Any] in value as? [Any] ?? [] {
            guard entry["kind"] as? String == "weekly_scoped",
                  let percent = QuotaValues.percent(entry["percent"]),
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty else { continue }
            let window = modelWindow(name, percent, resetsAt: (entry["resets_at"] as? String).flatMap(parseISO8601))
            guard !windows.contains(where: { $0.id == window.id }) else { continue }
            windows.append(window)
        }
        return windows
    }

    // Stable ids and labels, shared with the legacy cache migration.
    static func fiveHourWindow(_ percent: Double, resetsAt: Date?) -> QuotaWindow {
        QuotaWindow(id: "claude:5h", label: "5-hour", durationMinutes: 300, usedPercent: percent,
                    resetsAt: resetsAt, scope: .provider)
    }

    static func weeklyWindow(_ percent: Double, resetsAt: Date?) -> QuotaWindow {
        QuotaWindow(id: "claude:7d", label: "Weekly", durationMinutes: 10_080, usedPercent: percent,
                    resetsAt: resetsAt, scope: .provider)
    }

    static func modelWindow(_ name: String, _ percent: Double, resetsAt: Date?) -> QuotaWindow {
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return QuotaWindow(id: "claude:model:\(slug)", label: name, durationMinutes: 10_080, usedPercent: percent,
                           resetsAt: resetsAt, scope: .model)
    }

    private static func parseWindow(_ value: Any?) -> (percent: Double, resetsAt: Date?)? {
        guard let value else { return nil }
        if value is NSNull { return (0, nil) }
        guard let dict = value as? [String: Any],
              let utilization = QuotaValues.percent(dict["utilization"]) else { return nil }
        return (utilization, (dict["resets_at"] as? String).flatMap(parseISO8601))
    }

    private static func parseISO8601(_ string: String) -> Date? {
        // The endpoint emits microsecond fractions ("07:00:00.528743+00:00");
        // ISO8601DateFormatter only handles millisecond fractions, so strip them.
        let stripped = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stripped).flatMap(QuotaValues.plausible)
    }

    // MARK: - Account identity (local only; never logged or published)

    // Stable across token refreshes: the login token is not part of it.
    static func accountKey(fromConfig data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any],
              let account = oauth["accountUuid"] as? String, !account.isEmpty else { return nil }
        return QuotaAccountKey.make(.claude, [account, oauth["organizationUuid"] as? String ?? ""])
    }

    private static func readAccountKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        return (try? Data(contentsOf: url)).flatMap(accountKey(fromConfig:))
    }

    // MARK: - Token resolution (read-only; token never logged, never persisted)

    private func resolveAccessToken() async -> String? {
        if let raw = await readKeychainItem(), let token = Self.extractAccessToken(from: raw) {
            return token
        }
        let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let raw = try? String(contentsOf: credentialsFile, encoding: .utf8),
           let token = Self.extractAccessToken(from: raw) {
            return token
        }
        return nil
    }

    static func extractAccessToken(from raw: String) -> String? {
        var jsonData = raw.data(using: .utf8)
        // Some Claude Code versions have been reported to hex-encode the blob.
        if let data = jsonData, (try? JSONSerialization.jsonObject(with: data)) == nil,
           let hexDecoded = dataFromHex(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            jsonData = hexDecoded
        }
        guard let data = jsonData,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        // Expired token: skip the call — Claude Code refreshes it on its next
        // run; we hold last-known values in the meantime (no refresh flow here).
        if let expiresAtMs = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAtMs / 1000) <= Date() {
            logger.info("Claude Code OAuth token expired; waiting for Claude Code to refresh it")
            return nil
        }
        return token
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0, hex.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func readKeychainItem() async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = [
                "find-generic-password",
                "-a", NSUserName(),
                "-s", "Claude Code-credentials",
                "-w"
            ]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0,
                      let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !output.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                Self.logger.error("Failed to launch /usr/bin/security: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            }
        }
    }
}
