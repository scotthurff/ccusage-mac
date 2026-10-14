import XCTest

final class QuotaPresentationTests: XCTestCase {
    private let observedAt = Fixtures.observedAt

    private func slot(observedAt: Date?, windows: [QuotaWindow], lastAttempt: CollectionAttempt? = nil) -> ProviderSlot {
        ProviderSlot(
            provider: .claude, generation: "g", acceptedAttempt: 1,
            observation: observedAt.map {
                QuotaObservation(source: "test", observedAt: $0, windows: windows, resetCredits: nil, creditBalance: nil)
            },
            lastAttempt: lastAttempt)
    }

    private func present(_ slot: ProviderSlot, at offset: TimeInterval) -> ProviderPresentation {
        QuotaPresentation(now: observedAt.addingTimeInterval(offset)).provider(slot)
    }

    func testRecentReadingIsCurrent() {
        let shown = present(slot(observedAt: observedAt, windows: [Fixtures.window("w", "Weekly", minutes: 10_080, used: 17, resetsIn: 86_400)]), at: 600)
        XCTAssertEqual(shown.freshness, .current)
        XCTAssertEqual(shown.windows.first?.state, .current)
        XCTAssertEqual(shown.age, 600)
    }

    func testReadingBecomesOutdatedAtSixtyMinutes() {
        let reading = slot(observedAt: observedAt, windows: [Fixtures.window("w", "Weekly", minutes: 10_080, used: 17, resetsIn: 86_400)])
        XCTAssertEqual(present(reading, at: 3_599).freshness, .current)
        let outdated = present(reading, at: 3_600)
        XCTAssertEqual(outdated.freshness, .outdated(.aged))
        XCTAssertEqual(outdated.windows.first?.state, .outdated)
        XCTAssertEqual(outdated.windows.first?.window.usedPercent, 17, "last-known value stays as dated history")
    }

    // AE6: a reset that passes without a confirming read never becomes a verified zero.
    func testPassedResetKeepsLastValueAndIsNeverConfirmedZero() {
        let reading = slot(observedAt: observedAt, windows: [Fixtures.window("w", "5-hour", minutes: 300, used: 42, resetsIn: 1_800)])
        let before = present(reading, at: 1_799).windows[0]
        XCTAssertEqual(before.state, .current)
        let after = present(reading, at: 1_800).windows[0]
        XCTAssertEqual(after.state, .resetPassedUnconfirmed)
        XCTAssertEqual(after.window.usedPercent, 42)
        XCTAssertFalse(after.isConfirmedZero)
        XCTAssertEqual(present(reading, at: 7_200).windows[0].state, .resetPassedUnconfirmed)
    }

    func testFailedAttemptAfterObservationMarksOutdatedImmediately() {
        let reading = slot(observedAt: observedAt,
                           windows: [Fixtures.window("w", "Weekly", minutes: 10_080, used: 17, resetsIn: 86_400)],
                           lastAttempt: CollectionAttempt(at: observedAt.addingTimeInterval(60), outcome: .failure))
        XCTAssertEqual(present(reading, at: 120).freshness, .outdated(.failedAttempt))
        XCTAssertEqual(present(reading, at: 120).windows[0].state, .outdated)
    }

    func testFailedAttemptBeforeObservationIsIgnored() {
        let reading = slot(observedAt: observedAt,
                           windows: [Fixtures.window("w", "Weekly", minutes: 10_080, used: 17, resetsIn: 86_400)],
                           lastAttempt: CollectionAttempt(at: observedAt.addingTimeInterval(-60), outcome: .failure))
        XCTAssertEqual(present(reading, at: 120).freshness, .current)
    }

    // AE4: one provider never observed while the other is valid.
    func testMissingProviderIsUnknownWithoutAffectingTheOther() {
        var snapshot = Fixtures.snapshot()
        snapshot.providers[1].observation = nil
        snapshot.providers[1].lastAttempt = CollectionAttempt(at: observedAt, outcome: .failure)
        let shown = QuotaPresentation(now: observedAt.addingTimeInterval(60)).providers(in: snapshot)
        XCTAssertEqual(shown.map(\.provider), [.claude, .codex])
        XCTAssertEqual(shown[0].freshness, .current)
        XCTAssertEqual(shown[1].freshness, .unknown)
        XCTAssertTrue(shown[1].windows.isEmpty)
        XCTAssertNil(shown[1].age)
    }

    func testFreshExplicitZeroIsConfirmedAndDistinctFromUnknown() {
        let zero = present(slot(observedAt: observedAt, windows: [Fixtures.window("w", "Fable", minutes: 10_080, used: 0, resetsIn: 86_400)]), at: 60)
        XCTAssertTrue(zero.windows[0].isConfirmedZero)
        let unknown = present(slot(observedAt: nil, windows: []), at: 60)
        XCTAssertEqual(unknown.freshness, .unknown)
        XCTAssertTrue(unknown.windows.isEmpty)
        let stale = present(slot(observedAt: observedAt, windows: [Fixtures.window("w", "Fable", minutes: 10_080, used: 0, resetsIn: 86_400)]), at: 3_600)
        XCTAssertFalse(stale.windows[0].isConfirmedZero, "an old zero is history, not a confirmed zero")
    }

    func testFutureObservationIsUnverifiedBeyondTolerance() {
        let reading = slot(observedAt: observedAt, windows: [Fixtures.window("w", "Weekly", minutes: 10_080, used: 17, resetsIn: 86_400)])
        XCTAssertEqual(present(reading, at: -60).freshness, .current, "small clock skew is tolerated")
        let future = present(reading, at: -600)
        XCTAssertEqual(future.freshness, .unverified)
        XCTAssertEqual(future.windows[0].state, .outdated)
        XCTAssertFalse(future.windows[0].isConfirmedZero)
    }

    func testProvidersAndWindowsHaveStableOrder() {
        var snapshot = Fixtures.snapshot()
        snapshot.providers.reverse()
        snapshot.providers[1].observation?.windows.reverse()
        let shown = QuotaPresentation(now: observedAt.addingTimeInterval(60)).providers(in: snapshot)
        XCTAssertEqual(shown.map(\.provider), [.claude, .codex])
        XCTAssertEqual(shown[0].windows.map(\.window.id), ["claude:5h", "claude:7d", "claude:fable", "claude:opus"])
    }

    func testShortNamesMatchTheLengthNames() {
        let minutes = [300, 299, 10_080, 10_081, 4_320, 120, 90]
        XCTAssertEqual(minutes.map { QuotaWindow.shortName(minutes: $0) }, ["5h", "5h", "Wk", "Wk", "3d", "2h", "90m"])
        XCTAssertEqual(minutes.map { QuotaWindow.lengthName(minutes: $0) },
                       ["5-hour", "5-hour", "Weekly", "Weekly", "3-day", "2-hour", "90-minute"])
    }
}
