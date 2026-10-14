import Foundation

// How old a reading is and what each window may claim, given a clock.
// Mac, app, and widget all use this so they agree on stale and unknown.
struct QuotaPresentation {
    static let outdatedAfter: TimeInterval = 60 * 60
    // Small clock differences between devices are not "from the future".
    static let futureTolerance: TimeInterval = 5 * 60

    let now: Date

    func providers(in snapshot: QuotaSnapshot) -> [ProviderPresentation] {
        snapshot.providers
            .sorted { Self.providerRank($0.provider) < Self.providerRank($1.provider) }
            .map(provider)
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
