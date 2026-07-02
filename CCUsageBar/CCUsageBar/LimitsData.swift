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

struct ProviderLimits: Codable {
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    let fetchedAt: Date
}
