import Foundation

// The latest usage-limit readings the Mac publishes and the phone reads.
// Holds only limit values and display metadata: never credentials, emails,
// account identifiers, or session contents. Shared by Mac, app, and widget.
struct QuotaSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let maxEncodedBytes = 64 * 1024

    var version: Int
    var revision: Int64
    var publishedAt: Date
    var providers: [ProviderSlot]
}

struct QuotaProvider: RawRepresentable, Codable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let claude = QuotaProvider(rawValue: "claude")
    static let codex = QuotaProvider(rawValue: "codex")

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        default: rawValue.capitalized
        }
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// One provider's state. A provider that has never been observed keeps an
// empty observation, which displays as unknown rather than zero.
struct ProviderSlot: Codable, Equatable {
    var provider: QuotaProvider
    // Opaque marker of the signed-in account context; changes on account switch.
    var generation: String
    // Increases with each accepted collection attempt within a generation.
    var acceptedAttempt: Int64
    var observation: QuotaObservation?
    var lastAttempt: CollectionAttempt?
}

struct QuotaObservation: Codable, Equatable {
    var source: String
    // When the provider reported these values. Caching, uploading, and
    // downloading never change it.
    var observedAt: Date
    var windows: [QuotaWindow]
    var resetCredits: ResetCreditsInfo?
    var creditBalance: Double?
}

enum WindowScope: String, Codable {
    case provider   // the account-wide allowance
    case model      // a model-specific cap inside it, e.g. Fable
}

struct QuotaWindow: Codable, Equatable {
    var id: String
    var label: String
    var durationMinutes: Int?
    var usedPercent: Double
    var resetsAt: Date?
    var scope: WindowScope
}

struct CollectionAttempt: Codable, Equatable {
    enum Outcome: String, Codable {
        case success, failure
    }

    var at: Date
    var outcome: Outcome
}

// Codex "Full reset" credits: each one resets the limit to zero.
struct ResetCreditsInfo: Codable, Equatable {
    var available: Int
    var nextExpiry: Date?
}

enum SnapshotDecodeError: Error, Equatable {
    case oversized
    case malformed
    case unsupportedVersion(Int)
    case invalidValue(String)
}

extension JSONEncoder {
    static var quota: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var quota: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

extension QuotaSnapshot {
    // 2020-01-01 through 2100-01-01. Collectors use the same bounds, so a
    // collected reading can always be published.
    static let plausibleDates = Date(timeIntervalSince1970: 1_577_836_800)...Date(timeIntervalSince1970: 4_102_444_800)
    // Up to 1000% tolerates a provider reporting overage.
    static let usedPercentRange: ClosedRange<Double> = 0...1_000

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder.quota.encode(self)
        guard data.count <= Self.maxEncodedBytes else { throw SnapshotDecodeError.oversized }
        return data
    }

    // Checks the size first, then the version, then every value. A failure
    // returns an error and never a substitute snapshot.
    static func decode(from data: Data) -> Result<QuotaSnapshot, SnapshotDecodeError> {
        guard data.count <= maxEncodedBytes else { return .failure(.oversized) }
        struct VersionProbe: Decodable { let version: Int }
        guard let probe = try? JSONDecoder.quota.decode(VersionProbe.self, from: data) else {
            return .failure(.malformed)
        }
        guard probe.version == currentVersion else { return .failure(.unsupportedVersion(probe.version)) }
        guard let snapshot = try? JSONDecoder.quota.decode(QuotaSnapshot.self, from: data) else {
            return .failure(.malformed)
        }
        do {
            try snapshot.validate()
        } catch let error as SnapshotDecodeError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
        return .success(snapshot)
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw SnapshotDecodeError.unsupportedVersion(version) }
        guard revision >= 0 else { throw SnapshotDecodeError.invalidValue("revision") }
        try Self.check(publishedAt, "publishedAt")
        for slot in providers {
            guard slot.acceptedAttempt >= 0 else { throw SnapshotDecodeError.invalidValue("acceptedAttempt") }
            if let attempt = slot.lastAttempt { try Self.check(attempt.at, "lastAttempt") }
            guard let observation = slot.observation else { continue }
            try Self.check(observation.observedAt, "observedAt")
            if let balance = observation.creditBalance, !balance.isFinite {
                throw SnapshotDecodeError.invalidValue("creditBalance")
            }
            if let credits = observation.resetCredits {
                guard credits.available >= 0 else { throw SnapshotDecodeError.invalidValue("resetCredits") }
                if let expiry = credits.nextExpiry { try Self.check(expiry, "nextExpiry") }
            }
            for window in observation.windows {
                guard window.usedPercent.isFinite, Self.usedPercentRange.contains(window.usedPercent) else {
                    throw SnapshotDecodeError.invalidValue("usedPercent")
                }
                if let minutes = window.durationMinutes, minutes <= 0 {
                    throw SnapshotDecodeError.invalidValue("durationMinutes")
                }
                if let reset = window.resetsAt { try Self.check(reset, "resetsAt") }
            }
        }
    }

    private static func check(_ date: Date, _ field: String) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, plausibleDates.contains(date) else {
            throw SnapshotDecodeError.invalidValue(field)
        }
    }
}
