import Foundation
import os

actor CodexLimitsReader {
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "codexlimits")

    func fetchLimits() -> ProviderLimits? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current

        // Walk dated day directories backward from today; only the dated tree
        // is scanned (legacy flat rollout-*.json files at the root are ignored).
        for daysBack in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: Date()) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = comps.year, let month = comps.month, let day = comps.day else { continue }
            let dayDir = sessionsDir
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let rollouts = files
                .filter { $0.pathExtension == "jsonl" }
                .sorted { modificationDate($0) > modificationDate($1) }

            for file in rollouts {
                if let limits = lastRateLimits(in: file) {
                    return limits
                }
            }
        }

        Self.logger.info("No rate_limits event found in ~/.codex/sessions (7-day window)")
        return nil
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func lastRateLimits(in file: URL) -> ProviderLimits? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            if let limits = parseRateLimitsLine(String(line)) {
                return limits
            }
        }
        return nil
    }

    private func parseRateLimitsLine(_ line: String) -> ProviderLimits? {
        guard let data = line.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let payload = event["payload"] as? [String: Any]
        guard let rateLimits = (payload?["rate_limits"] ?? event["rate_limits"]) as? [String: Any] else {
            return nil
        }

        // Needed for the resets_in_seconds variant (relative to the event).
        let eventDate = (event["timestamp"] as? String).flatMap(Self.parseISO8601) ?? Date()

        var fiveHour: LimitWindow?
        var weekly: LimitWindow?

        for key in ["primary", "secondary"] {
            guard let raw = rateLimits[key] as? [String: Any],
                  let usedPercent = raw["used_percent"] as? Double else { continue }

            var resetsAt: Date?
            if let epoch = raw["resets_at"] as? Double {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let relative = raw["resets_in_seconds"] as? Double {
                resetsAt = eventDate.addingTimeInterval(relative)
            }

            let window = LimitWindow(usedPercent: usedPercent, resetsAt: resetsAt)

            // Classify by window size magnitude (values are off-by-one in the
            // wild: 299/300, 10079/10080); fall back to primary=5h, secondary=weekly.
            let windowMinutes = raw["window_minutes"] as? Double ?? 0
            if windowMinutes > 0 {
                if windowMinutes < 1440 { fiveHour = window } else { weekly = window }
            } else {
                if key == "primary" { fiveHour = window } else { weekly = window }
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return ProviderLimits(fiveHour: fiveHour, weekly: weekly, fetchedAt: Date())
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
