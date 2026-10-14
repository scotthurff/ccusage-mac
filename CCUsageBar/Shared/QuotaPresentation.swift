import Foundation

// How old a reading is and what each window may claim, given a clock.
// Mac, app, and widget all use this so they agree on stale and unknown.
struct QuotaPresentation {
    static let outdatedAfter: TimeInterval = 60 * 60
    // Small clock differences between devices are not "from the future".
    static let futureTolerance: TimeInterval = 5 * 60

    let now: Date

    // Dates closer than this read as a weekday; farther ones as a date.
    static let weekdayWindow: TimeInterval = 6 * 86_400

    func providers(in snapshot: QuotaSnapshot) -> [ProviderPresentation] {
        snapshot.providers
            .sorted { Self.providerRank($0.provider) < Self.providerRank($1.provider) }
            .map(provider)
    }

    // Like providers(in:), plus Claude and Codex as unknown when the snapshot
    // lacks them, so both always appear on the phone and widget.
    func providersIncludingDefaults(in snapshot: QuotaSnapshot) -> [ProviderPresentation] {
        var snapshot = snapshot
        for provider in [QuotaProvider.claude, .codex] where !snapshot.providers.contains(where: { $0.provider == provider }) {
            snapshot.providers.append(ProviderSlot(provider: provider, generation: "", acceptedAttempt: 0,
                                                   observation: nil, lastAttempt: nil))
        }
        return providers(in: snapshot)
    }

    func provider(_ slot: ProviderSlot) -> ProviderPresentation {
        guard let observation = slot.observation else {
            return ProviderPresentation(provider: slot.provider, freshness: .unknown, observedAt: nil, age: nil,
                                        windows: [], resetCredits: nil, creditBalance: nil)
        }
        let age = now.timeIntervalSince(observation.observedAt)
        let freshness: Freshness
        if age < -Self.futureTolerance {
            freshness = .unverified
        } else if let attempt = slot.lastAttempt, attempt.outcome == .failure, attempt.at > observation.observedAt {
            freshness = .outdated(.failedAttempt)
        } else if age >= Self.outdatedAfter {
            freshness = .outdated(.aged)
        } else {
            freshness = .current
        }
        let windows = observation.windows
            .sorted(by: Self.windowOrder)
            .map { window -> WindowPresentation in
                // A passed reset is the more specific fact, except for a
                // reading from the future, whose times can't be trusted.
                let state: WindowState
                if freshness == .unverified {
                    state = .outdated
                } else if let reset = window.resetsAt, reset <= now {
                    state = .resetPassedUnconfirmed
                } else if freshness != .current {
                    state = .outdated
                } else {
                    state = .current
                }
                return WindowPresentation(window: window, state: state)
            }
        return ProviderPresentation(provider: slot.provider, freshness: freshness, observedAt: observation.observedAt,
                                    age: max(0, age), windows: windows,
                                    resetCredits: observation.resetCredits, creditBalance: observation.creditBalance)
    }

    private static func providerRank(_ provider: QuotaProvider) -> String {
        switch provider {
        case .claude: "0"
        case .codex: "1"
        default: "2" + provider.rawValue
        }
    }

    // Account-wide windows before model caps, shorter windows first, then id.
    private static func windowOrder(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        if a.scope != b.scope { return a.scope == .provider }
        let aMinutes = a.durationMinutes ?? .max, bMinutes = b.durationMinutes ?? .max
        if aMinutes != bMinutes { return aMinutes < bMinutes }
        return a.id < b.id
    }
}

enum Freshness: Equatable {
    case unknown
    case current
    case outdated(OutdatedReason)
    case unverified

    enum OutdatedReason: Equatable {
        case aged, failedAttempt
    }
}

enum WindowState: Equatable {
    // A current reading; an explicit 0% here is a confirmed zero.
    case current
    // Dated history from an outdated or unverified reading.
    case outdated
    // The reset time passed with no newer reading to confirm the new value.
    case resetPassedUnconfirmed
}

struct ProviderPresentation: Equatable {
    let provider: QuotaProvider
    let freshness: Freshness
    let observedAt: Date?
    let age: TimeInterval?
    let windows: [WindowPresentation]
    let resetCredits: ResetCreditsInfo?
    let creditBalance: Double?
}

struct WindowPresentation: Equatable {
    let window: QuotaWindow
    let state: WindowState

    var isConfirmedZero: Bool { state == .current && window.usedPercent == 0 }
}

extension QuotaWindow {
    // "5-hour", "Weekly", or the length in plain units.
    static func lengthName(minutes: Int) -> String {
        if abs(minutes - 300) <= 1 { return "5-hour" }
        if abs(minutes - 10_080) <= 1 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

extension ResetCreditsInfo {
    // e.g. "62,493 credits"
    static func balanceText(_ balance: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(balance.formatted(.number.precision(.fractionLength(0)).locale(locale))) credits"
    }
}
