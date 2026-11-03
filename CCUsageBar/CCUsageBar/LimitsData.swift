import Foundation

// MARK: - Collection results

// What one collection attempt produced, before AppState accepts it.
struct QuotaCollectionResult: Equatable {
    // A local hash of the signed-in account, or nil when no identity signal
    // was available. Only used on this Mac to notice an account switch.
    var accountKey: String?
    // Nil means the attempt failed.
    var observation: QuotaObservation?
}

protocol QuotaCollector: Sendable {
    func collect() async -> QuotaCollectionResult
}

enum QuotaAccountKey {
    // One-way, so raw account identifiers are never stored or published.
    static func make(_ provider: QuotaProvider, _ parts: [String]) -> String {
        AccountHash.sha256Hex(([provider.rawValue] + parts).joined(separator: "|"))
    }
}

// MARK: - Values from provider responses

// Uses the bounds QuotaSnapshot.validate enforces, so a collected reading
// can always be published.
enum QuotaValues {
    // A JSON number; true/false are not numbers here.
    static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    static func percent(_ value: Any?) -> Double? {
        guard let percent = number(value)?.doubleValue else { return nil }
        return percent.isFinite && QuotaSnapshot.usedPercentRange.contains(percent) ? percent : nil
    }

    static func date(unixSeconds value: Any?) -> Date? {
        number(value).flatMap { plausible(Date(timeIntervalSince1970: $0.doubleValue)) }
    }

    static func plausible(_ date: Date) -> Date? {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && QuotaSnapshot.plausibleDates.contains(date) ? date : nil
    }

    // "5-hour", "Weekly", or the reported length in plain units.
    static func durationLabel(_ minutes: Int?) -> String {
        minutes.map { QuotaWindow.lengthName(minutes: $0) } ?? "Limit"
    }
}

// MARK: - Mac popover layout

// One popover line: a limit's name, bar, value, and reset.
struct MacGauge: Equatable {
    enum Tone: Equatable {
        case normal, warning
        // Dated history: shown, but not as a live reading.
        case neutral
    }

    let id: String
    let label: String
    // A model or product cap inside the provider's allowance.
    let isCap: Bool
    let valueText: String
    let fill: Double
    let tone: Tone
    // The reset time passed with no newer reading to confirm the new value.
    let isStruckThrough: Bool
    // Only a reset that is still ahead.
    let resetsAt: Date?
    // A day or longer, or an unknown length: the reset shows its weekday.
    let resetShowsWeekday: Bool
    let help: String
}

// Turns the shared presentation (the same rules the phone uses) into the
// popover's lines, one per window, in the shared order.
enum MacQuotaDisplay {
    static func gauges(_ presentation: ProviderPresentation) -> [MacGauge] {
        presentation.windows.map(gauge)
    }

    static func gauge(_ window: WindowPresentation) -> MacGauge {
        let used = window.window.usedPercent
        // A dollar limit reads "$14 of $250"; everything else is a percentage.
        let text = window.window.dollars?.text() ?? "\(Int(used.rounded()))%"
        let name = window.window.label
        let tone: MacGauge.Tone
        let help: String
        switch window.state {
        case .current:
            tone = window.isWarning ? .warning : .normal
            help = "\(name): \(text) used"
        case .outdated:
            tone = .neutral
            help = "\(name): \(text) used at the last reading, which is out of date"
        case .resetPassedUnconfirmed:
            tone = .neutral
            help = "\(name): this window reset after the last reading (\(text) used then). Waiting for a new reading."
        }
        return MacGauge(id: window.window.id, label: name, isCap: window.window.scope != .provider, valueText: text,
                        fill: min(max(used, 0), 100), tone: tone,
                        isStruckThrough: window.state == .resetPassedUnconfirmed,
                        resetsAt: window.state == .resetPassedUnconfirmed ? nil : window.window.resetsAt,
                        resetShowsWeekday: (window.window.durationMinutes ?? .max) >= 1_440, help: help)
    }

    // How long ago the provider was last read; nil before the first reading.
    static func ageText(_ presentation: ProviderPresentation) -> String? {
        switch presentation.freshness {
        case .unknown:
            return nil
        case .unverified:
            return "?"
        case .current, .outdated:
            guard let age = presentation.age else { return nil }
            let minutes = Int(age / 60)
            if minutes < 1 { return "now" }
            if minutes < 60 { return "\(minutes)m ago" }
            if minutes < 1_440 { return "\(minutes / 60)h ago" }
            return "\(minutes / 1_440)d ago"
        }
    }

    static func isOutdated(_ presentation: ProviderPresentation) -> Bool {
        switch presentation.freshness {
        case .outdated, .unverified: return true
        case .current, .unknown: return false
        }
    }

    // Shown in place of the bars when a provider has none to show.
    static func emptyText(_ presentation: ProviderPresentation) -> String? {
        guard presentation.windows.isEmpty else { return nil }
        return presentation.observedAt == nil ? "No reading yet" : "No limits in the last reading"
    }
}

// MARK: - Legacy cache (read once, for migration)

// The format stored under `cachedClaudeLimits` / `cachedCodexLimits` before
// the shared snapshot. Only Claude's is migrated: its `fetchedAt` was the
// time of a live response. Codex's came from local log reads and is not.
struct LimitWindow: Codable {
    let usedPercent: Double
    let resetsAt: Date?
}

struct ScopedLimit: Codable {
    let name: String
    let window: LimitWindow
}

struct ProviderLimits: Codable {
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    var scopedWeekly: [ScopedLimit]?
    let fetchedAt: Date

    // Keeps the original observation date. Nil when the cache can't be trusted.
    func migratedClaudeObservation(now: Date) -> QuotaObservation? {
        guard let observedAt = QuotaValues.plausible(fetchedAt),
              observedAt <= now.addingTimeInterval(QuotaPresentation.futureTolerance) else { return nil }
        func valid(_ window: LimitWindow?) -> (percent: Double, resetsAt: Date?)? {
            guard let window, window.usedPercent.isFinite, QuotaSnapshot.usedPercentRange.contains(window.usedPercent) else { return nil }
            return (window.usedPercent, window.resetsAt.flatMap(QuotaValues.plausible))
        }
        var windows: [QuotaWindow] = []
        if let fiveHour = valid(fiveHour) {
            windows.append(ClaudeLimitsFetcher.fiveHourWindow(fiveHour.percent, resetsAt: fiveHour.resetsAt))
        }
        if let weekly = valid(weekly) {
            windows.append(ClaudeLimitsFetcher.weeklyWindow(weekly.percent, resetsAt: weekly.resetsAt))
        }
        for scoped in scopedWeekly ?? [] where !scoped.name.isEmpty {
            guard let cap = valid(scoped.window) else { continue }
            let window = ClaudeLimitsFetcher.modelWindow(scoped.name, cap.percent, resetsAt: cap.resetsAt)
            if !windows.contains(where: { $0.id == window.id }) { windows.append(window) }
        }
        guard !windows.isEmpty else { return nil }
        return QuotaObservation(source: ClaudeLimitsFetcher.source, observedAt: observedAt, windows: windows,
                                resetCredits: nil, creditBalance: nil)
    }
}
