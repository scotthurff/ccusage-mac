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

// One popover row: a short window (under a day) and a long one side by side.
struct MacQuotaRow: Equatable {
    let title: String
    let isModel: Bool
    let short: WindowPresentation?
    let long: WindowPresentation?
}

struct MacGauge: Equatable {
    enum Tone: Equatable {
        case normal, warning
        // Dated history: shown, but not as a live reading.
        case neutral
    }

    let label: String
    let percentText: String
    let fill: Double
    let tone: Tone
    // The reset time passed with no newer reading to confirm the new value.
    let isStruckThrough: Bool
    // Only a reset that is still ahead.
    let resetsAt: Date?
    let help: String
}

// Turns the shared presentation (the same rules the phone uses) into the
// popover's rows and gauges.
enum MacQuotaDisplay {
    // The standard 5-hour and weekly windows share the provider row. Any other
    // account-wide window, and every model cap, gets a row of its own.
    static func rows(_ presentation: ProviderPresentation, title: String) -> [MacQuotaRow] {
        let account = presentation.windows.filter { $0.window.scope == .provider }
        let short = account.first { isAbout($0, 300) } ?? account.first(where: isShort)
        let long = account.first { isAbout($0, 10_080) } ?? account.first { !isShort($0) }
        var rows = [MacQuotaRow(title: title, isModel: false, short: short, long: long)]
        for window in presentation.windows where window.window.id != short?.window.id && window.window.id != long?.window.id {
            rows.append(MacQuotaRow(title: window.window.label.uppercased(), isModel: window.window.scope == .model,
                                    short: isShort(window) ? window : nil, long: isShort(window) ? nil : window))
        }
        return rows
    }

    static func gauge(_ window: WindowPresentation) -> MacGauge {
        let used = window.window.usedPercent
        let text = "\(Int(used.rounded()))%"
        let name = window.window.label
        let label = shortLabel(window.window.durationMinutes)
        let fill = min(max(used, 0), 100)
        switch window.state {
        case .current:
            return MacGauge(label: label, percentText: text, fill: fill, tone: used >= 80 ? .warning : .normal,
                            isStruckThrough: false, resetsAt: window.window.resetsAt, help: "\(name): \(text) used")
        case .outdated:
            return MacGauge(label: label, percentText: text, fill: fill, tone: .neutral, isStruckThrough: false,
                            resetsAt: window.window.resetsAt,
                            help: "\(name): \(text) used at the last reading, which is out of date")
        case .resetPassedUnconfirmed:
            return MacGauge(label: label, percentText: text, fill: fill, tone: .neutral, isStruckThrough: true,
                            resetsAt: nil,
                            help: "\(name): this window reset after the last reading (\(text) used then). Waiting for a new reading.")
        }
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

    private static func isShort(_ window: WindowPresentation) -> Bool {
        (window.window.durationMinutes ?? .max) < 1_440
    }

    private static func isAbout(_ window: WindowPresentation, _ minutes: Int) -> Bool {
        window.window.durationMinutes.map { abs($0 - minutes) <= 1 } ?? false
    }

    private static func shortLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "lim" }
        if abs(minutes - 300) <= 1 { return "5h" }
        if abs(minutes - 10_080) <= 1 { return "wk" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
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
