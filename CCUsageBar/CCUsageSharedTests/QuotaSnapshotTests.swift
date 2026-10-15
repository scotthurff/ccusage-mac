import XCTest

final class QuotaSnapshotTests: XCTestCase {
    func testRoundTripPreservesProvidersWindowsAndDates() throws {
        let snapshot = Fixtures.snapshot()
        let decoded = try QuotaSnapshot.decode(from: snapshot.encoded()).get()
        XCTAssertEqual(decoded, snapshot)
        let claude = try XCTUnwrap(decoded.providers.first { $0.provider == .claude }?.observation)
        XCTAssertEqual(claude.windows.map(\.label), ["5-hour", "Weekly", "Fable", "Opus"])
        XCTAssertEqual(claude.windows.map(\.durationMinutes), [300, 10_080, 10_080, 10_080])
        XCTAssertEqual(claude.observedAt, Fixtures.observedAt)
    }

    func testEncodedFieldsAreLimitedToTheAllowlist() throws {
        let object = try JSONSerialization.jsonObject(with: Fixtures.snapshot().encoded())
        XCTAssertEqual(Self.keyPaths(object), [
            "providers", "publishedAt", "revision", "version",
            "providers.acceptedAttempt", "providers.generation", "providers.lastAttempt", "providers.observation", "providers.provider",
            "providers.lastAttempt.at", "providers.lastAttempt.outcome",
            "providers.observation.creditBalance", "providers.observation.observedAt", "providers.observation.resetCredits",
            "providers.observation.source", "providers.observation.windows",
            "providers.observation.resetCredits.available", "providers.observation.resetCredits.nextExpiry",
            "providers.observation.windows.durationMinutes", "providers.observation.windows.id",
            "providers.observation.windows.label", "providers.observation.windows.resetsAt",
            "providers.observation.windows.scope", "providers.observation.windows.usedPercent",
        ])
    }

    func testUnknownFieldsAndProvidersAreTolerated() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.snapshot().encoded()) as? [String: Any])
        object["futureTopLevelField"] = "ignored"
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers[0]["futureSlotField"] = 7
        providers.append(["provider": "gemini", "generation": "g", "acceptedAttempt": 1])
        object["providers"] = providers
        let decoded = try QuotaSnapshot.decode(from: JSONSerialization.data(withJSONObject: object)).get()
        XCTAssertEqual(decoded.providers.map(\.provider.rawValue), ["claude", "codex", "gemini"])
    }

    func testRejectsUnsupportedVersion() throws {
        var snapshot = Fixtures.snapshot()
        snapshot.version = 2
        let data = try JSONEncoder.quota.encode(snapshot)
        XCTAssertEqual(QuotaSnapshot.decode(from: data).failure, .unsupportedVersion(2))
    }

    func testRejectsMalformedJSON() {
        XCTAssertEqual(QuotaSnapshot.decode(from: Data("{\"version\":1,".utf8)).failure, .malformed)
    }

    func testRejectsOutOfRangeAndNonfinitePercentages() throws {
        for bad in [-1.0, 1_001, .nan, .infinity] {
            var snapshot = Fixtures.snapshot()
            snapshot.providers[0].observation?.windows[0].usedPercent = bad
            XCTAssertThrowsError(try snapshot.validate(), "\(bad)") { error in
                XCTAssertEqual(error as? SnapshotDecodeError, .invalidValue("usedPercent"))
            }
        }
        var snapshot = Fixtures.snapshot()
        snapshot.providers[0].observation?.windows[0].usedPercent = -5
        let data = try JSONEncoder.quota.encode(snapshot)
        XCTAssertEqual(QuotaSnapshot.decode(from: data).failure, .invalidValue("usedPercent"))
    }

    func testRejectsInvalidDates() throws {
        var snapshot = Fixtures.snapshot()
        snapshot.providers[1].observation?.observedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONEncoder.quota.encode(snapshot)
        XCTAssertEqual(QuotaSnapshot.decode(from: data).failure, .invalidValue("observedAt"))
    }

    func testRejectsOversizedPayloadBeforeDecoding() {
        let data = Data(repeating: 0x20, count: QuotaSnapshot.maxEncodedBytes + 1)
        XCTAssertEqual(QuotaSnapshot.decode(from: data).failure, .oversized)
    }

    func testEncodingRefusesInvalidSnapshot() {
        var snapshot = Fixtures.snapshot()
        snapshot.providers[0].observation?.windows[0].usedPercent = .nan
        XCTAssertThrowsError(try snapshot.encoded())
    }

    private static func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        var paths = Set<String>()
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                paths.insert(path)
                paths.formUnion(keyPaths(child, prefix: path))
            }
        } else if let array = value as? [Any] {
            for child in array { paths.formUnion(keyPaths(child, prefix: prefix)) }
        }
        return paths
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

enum Fixtures {
    static let observedAt = Date(timeIntervalSince1970: 1_792_003_341)

    static func window(_ id: String, _ label: String, minutes: Int?, used: Double,
                       resetsIn: TimeInterval?, scope: WindowScope = .provider) -> QuotaWindow {
        QuotaWindow(id: id, label: label, durationMinutes: minutes, usedPercent: used,
                    resetsAt: resetsIn.map { observedAt.addingTimeInterval($0) }, scope: scope)
    }

    static func snapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            version: QuotaSnapshot.currentVersion,
            revision: 42,
            publishedAt: observedAt.addingTimeInterval(5),
            providers: [
                ProviderSlot(
                    provider: .claude, generation: "claude-gen-1", acceptedAttempt: 7,
                    observation: QuotaObservation(
                        source: "claude-oauth-usage", observedAt: observedAt,
                        windows: [
                            window("claude:5h", "5-hour", minutes: 300, used: 2, resetsIn: 3 * 3600),
                            window("claude:7d", "Weekly", minutes: 10_080, used: 17, resetsIn: 3 * 86_400),
                            window("claude:fable", "Fable", minutes: 10_080, used: 0, resetsIn: 3 * 86_400, scope: .model),
                            window("claude:opus", "Opus", minutes: 10_080, used: 31.5, resetsIn: 3 * 86_400, scope: .model),
                        ],
                        resetCredits: nil, creditBalance: nil),
                    lastAttempt: CollectionAttempt(at: observedAt, outcome: .success)),
                ProviderSlot(
                    provider: .codex, generation: "codex-gen-1", acceptedAttempt: 3,
                    observation: QuotaObservation(
                        source: "codex-app-server", observedAt: observedAt.addingTimeInterval(-900),
                        windows: [window("codex:codex:10080", "Weekly", minutes: 10_080, used: 13, resetsIn: 5 * 86_400)],
                        resetCredits: ResetCreditsInfo(available: 3, nextExpiry: observedAt.addingTimeInterval(8 * 86_400)),
                        creditBalance: 62_493.38),
                    lastAttempt: CollectionAttempt(at: observedAt.addingTimeInterval(-900), outcome: .success)),
            ])
    }
}
