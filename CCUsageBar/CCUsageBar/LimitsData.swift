import Foundation

struct LimitWindow: Codable {
    let usedPercent: Double
    let resetsAt: Date?

    // R9 expiry gate: consumers read effective* — never usedPercent directly.
    // Cached snapshots loaded on relaunch never re-pass through a reader, so
    // expiry-zeroing must happen at display time.
    var effectivePercent: Double {
        if let resetsAt, resetsAt <= Date() { return 0 }
        return usedPercent
    }

    var effectiveResetsAt: Date? {
        if let resetsAt, resetsAt <= Date() { return nil }
        return resetsAt
    }
}

// Per-model weekly cap (e.g. Fable) from the endpoint's `limits[]` array.
struct ScopedLimit: Codable {
    let name: String
    let window: LimitWindow
}

struct ProviderLimits: Codable {
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    var scopedWeekly: [ScopedLimit]?
    let fetchedAt: Date
}
