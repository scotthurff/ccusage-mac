import Foundation
import XCTest

// MARK: - Test doubles

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

// Returns queued results in order; an empty queue is a failed read.
private final class StubCollector: QuotaCollector, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [QuotaCollectionResult]
    init(_ results: [QuotaCollectionResult] = []) { queue = results }

    func push(_ result: QuotaCollectionResult) { lock.withLock { queue.append(result) } }

    func collect() async -> QuotaCollectionResult {
        lock.withLock { queue.isEmpty ? QuotaCollectionResult(accountKey: nil, observation: nil) : queue.removeFirst() }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_792_003_341)

private func window(_ id: String, _ label: String, minutes: Int, used: Double, resetsAt: Date?,
                    scope: WindowScope = .provider) -> QuotaWindow {
    QuotaWindow(id: id, label: label, durationMinutes: minutes, usedPercent: used, resetsAt: resetsAt, scope: scope)
}

private func claudeObservation(at date: Date, fiveHour: Double = 20, weekly: Double = 30, fable: Double? = 10,
                               fiveHourReset: Date? = nil) -> QuotaObservation {
    var windows = [
        window("claude:5h", "5-hour", minutes: 300, used: fiveHour, resetsAt: fiveHourReset ?? date.addingTimeInterval(3 * 3600)),
        window("claude:7d", "Weekly", minutes: 10_080, used: weekly, resetsAt: date.addingTimeInterval(3 * 86_400)),
    ]
    if let fable {
        windows.append(window("claude:model:fable", "Fable", minutes: 10_080, used: fable,
                              resetsAt: date.addingTimeInterval(3 * 86_400), scope: .model))
    }
    return QuotaObservation(source: "claude-oauth-usage", observedAt: date, windows: windows, resetCredits: nil, creditBalance: nil)
}

private func codexObservation(at date: Date, weekly: Double = 13) -> QuotaObservation {
    QuotaObservation(source: "codex-app-server", observedAt: date,
                     windows: [window("codex:codex:10080", "Weekly", minutes: 10_080, used: weekly,
                                      resetsAt: date.addingTimeInterval(5 * 86_400))],
                     resetCredits: ResetCreditsInfo(available: 3, nextExpiry: nil), creditBalance: 100)
}

private func success(_ observation: QuotaObservation, key: String? = "key-1") -> QuotaCollectionResult {
    QuotaCollectionResult(accountKey: key, observation: observation)
}

private func failure(key: String? = nil) -> QuotaCollectionResult {
    QuotaCollectionResult(accountKey: key, observation: nil)
}

private let usageJSON = #"""
{"daily":[{"period":"2026-10-13","inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,
"totalTokens":10,"totalCost":1.5,"modelsUsed":["claude-x"],"modelBreakdowns":[{"modelName":"claude-x",
"inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,"cost":1.5}]}],
"totals":{"inputTokens":1,"outputTokens":2,"cacheCreationTokens":3,"cacheReadTokens":4,"totalCost":1.5,"totalTokens":10}}
"""#

// MARK: - Tests

@MainActor
final class AppStateQuotaTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock: TestClock!
    private var claude: StubCollector!
    private var codex: StubCollector!

    override func setUp() async throws {
        suiteName = "AppStateQuotaTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = TestClock(t0)
        claude = StubCollector()
        codex = StubCollector()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeState() -> AppState {
        let clock = self.clock!
        return AppState(defaults: defaults, claudeCollector: claude, codexCollector: codex,
                        now: { clock.now }, startsAutomatically: false)
    }

    // MARK: Independent providers (AE4)

    func testClaudeAdvancesWhileCodexFailsAndCodexStaysUnknown() async {
        claude.push(success(claudeObservation(at: t0)))
        codex.push(failure())
        let state = makeState()
        XCTAssertFalse(state.hasAttemptedLimitsFetch)

        await state.refreshQuotas()

        XCTAssertTrue(state.hasAttemptedLimitsFetch)
        XCTAssertEqual(state.slot(.claude).observation, claudeObservation(at: t0))
        XCTAssertEqual(state.slot(.claude).acceptedAttempt, 1)
        XCTAssertEqual(state.slot(.claude).lastAttempt, CollectionAttempt(at: t0, outcome: .success))
        XCTAssertEqual(state.presentation(.claude).freshness, .current)

        XCTAssertNil(state.slot(.codex).observation)
        XCTAssertEqual(state.slot(.codex).lastAttempt, CollectionAttempt(at: t0, outcome: .failure))
        XCTAssertEqual(state.presentation(.codex).freshness, .unknown)
        XCTAssertEqual(state.presentation(.codex).windows, [])
    }

    func testFailuresKeepEarlierDatesAndMarkThemOutdated() async {
        claude.push(success(claudeObservation(at: t0)))
        codex.push(success(codexObservation(at: t0)))
        let state = makeState()
        await state.refreshQuotas()

        // Codex fails alone: Claude is untouched, Codex keeps its date.
        clock.advance(minutes: 10)
        claude.push(success(claudeObservation(at: clock.now, weekly: 31)))
        codex.push(failure())
        await state.refreshQuotas()
        XCTAssertEqual(state.slot(.claude).observation?.observedAt, clock.now)
        XCTAssertEqual(state.presentation(.claude).freshness, .current)
        XCTAssertEqual(state.slot(.codex).observation, codexObservation(at: t0))
        XCTAssertEqual(state.presentation(.codex).freshness, .outdated(.failedAttempt))
        XCTAssertEqual(state.presentation(.codex).windows.map(\.state), [.outdated])

        // Then both fail: both keep their own dates, both read as outdated.
        let claudeDate = clock.now
        clock.advance(minutes: 10)
        await state.refreshQuotas()
        XCTAssertEqual(state.slot(.claude).observation?.observedAt, claudeDate)
        XCTAssertEqual(state.slot(.codex).observation?.observedAt, t0)
        XCTAssertEqual(state.presentation(.claude).freshness, .outdated(.failedAttempt))
        XCTAssertEqual(state.presentation(.codex).freshness, .outdated(.failedAttempt))
        XCTAssertEqual(state.slot(.claude).acceptedAttempt, 3)
        XCTAssertNil(state.hottestLimit, "outdated numbers never feed the menu bar hint")
    }

    func testBothFailingBeforeAnySuccessShowsUnknownNotZero() async {
        let state = makeState()
        await state.refreshQuotas()
        XCTAssertEqual(state.presentation(.claude).freshness, .unknown)
        XCTAssertEqual(state.presentation(.codex).freshness, .unknown)
        XCTAssertFalse(state.hasLimitsData)
        XCTAssertNil(state.hottestLimit)
        XCTAssertEqual(state.menuBarLabel, "--")
        let row = MacQuotaDisplay.rows(state.presentation(.claude), title: "CLAUDE")
        XCTAssertEqual(row.count, 1)
        XCTAssertNil(row[0].short)
        XCTAssertNil(row[0].long)
    }

    // MARK: Ordering

    func testOnlyOneCollectionPerProviderAtATime() {
        let state = makeState()
        XCTAssertNotNil(state.beginCollection(.claude))
        XCTAssertNil(state.beginCollection(.claude))
        XCTAssertNotNil(state.beginCollection(.codex))
    }

    func testSupersededSuccessOrFailureCannotOverwriteALaterAcceptedResult() {
        let state = makeState()
        let late = state.beginCollection(.claude)!
        state.invalidate(.claude)
        let current = state.beginCollection(.claude)!
        clock.advance(minutes: 1)
        state.finishCollection(current, success(claudeObservation(at: clock.now, weekly: 50)))
        let accepted = state.slot(.claude)

        state.finishCollection(late, success(claudeObservation(at: t0, weekly: 5)))
        XCTAssertEqual(state.slot(.claude), accepted, "a late success is rejected")
        state.finishCollection(late, failure())
        XCTAssertEqual(state.slot(.claude), accepted, "a late failure is rejected")
        XCTAssertEqual(state.presentation(.claude).freshness, .current)
    }

    func testAFinishedTicketCannotBeAppliedTwice() {
        let state = makeState()
        let ticket = state.beginCollection(.codex)!
        state.finishCollection(ticket, success(codexObservation(at: t0)))
        let accepted = state.slot(.codex)
        clock.advance(minutes: 1)
        state.finishCollection(ticket, failure())
        XCTAssertEqual(state.slot(.codex), accepted)
    }

    // MARK: Account binding (KTD10)

    func testAccountSwitchDropsPriorReadingsAndRejectsTheOldAccountsLateResponse() {
        let state = makeState()
        let first = state.beginCollection(.claude)!
        state.finishCollection(first, success(claudeObservation(at: t0, fable: 10), key: "account-A"))
        let generationA = state.slot(.claude).generation

        // A read is in flight for account A when the switch to B is seen.
        let lateA = state.beginCollection(.claude)!
        state.invalidate(.claude)
        XCTAssertNil(state.slot(.claude).observation)
        XCTAssertNotEqual(state.slot(.claude).generation, generationA)

        clock.advance(minutes: 2)
        let readB = state.beginCollection(.claude)!
        state.finishCollection(readB, success(claudeObservation(at: clock.now, fable: nil), key: "account-B"))
        let accountB = state.slot(.claude)

        state.finishCollection(lateA, success(claudeObservation(at: t0, fable: 10), key: "account-A"))
        XCTAssertEqual(state.slot(.claude), accountB)
        XCTAssertFalse(accountB.observation!.windows.contains { $0.id == "claude:model:fable" })
    }

    func testANewAccountReportedByACollectorReplacesTheOldGeneration() {
        let state = makeState()
        var ticket = state.beginCollection(.codex)!
        state.finishCollection(ticket, success(codexObservation(at: t0), key: "account-A"))
        let before = state.slot(.codex)

        // The new account's read fails: the old account's numbers are dropped, not kept.
        clock.advance(minutes: 5)
        ticket = state.beginCollection(.codex)!
        state.finishCollection(ticket, failure(key: "account-B"))
        let switched = state.slot(.codex)
        XCTAssertNotEqual(switched.generation, before.generation)
        XCTAssertNil(switched.observation)
        XCTAssertEqual(switched.acceptedAttempt, 1)
        XCTAssertEqual(state.presentation(.codex).freshness, .unknown)

        // Its first success fills the new generation.
        clock.advance(minutes: 5)
        ticket = state.beginCollection(.codex)!
        state.finishCollection(ticket, success(codexObservation(at: clock.now, weekly: 70), key: "account-B"))
        XCTAssertEqual(state.slot(.codex).generation, switched.generation)
        XCTAssertEqual(state.slot(.codex).observation?.windows.first?.usedPercent, 70)
        XCTAssertEqual(state.slot(.codex).acceptedAttempt, 2)
    }

    func testTokenRotationOrMissingIdentityKeepsAStableAccountsReadings() {
        let state = makeState()
        var ticket = state.beginCollection(.claude)!
        state.finishCollection(ticket, success(claudeObservation(at: t0), key: "account-A"))
        let generation = state.slot(.claude).generation

        // An expired token fails the read but the account is the same.
        clock.advance(minutes: 15)
        ticket = state.beginCollection(.claude)!
        state.finishCollection(ticket, failure(key: "account-A"))
        XCTAssertEqual(state.slot(.claude).generation, generation)
        XCTAssertEqual(state.slot(.claude).observation, claudeObservation(at: t0))

        // No identity signal this time: not evidence of a switch.
        clock.advance(minutes: 15)
        ticket = state.beginCollection(.claude)!
        state.finishCollection(ticket, success(claudeObservation(at: clock.now, weekly: 40), key: nil))
        XCTAssertEqual(state.slot(.claude).generation, generation)

        clock.advance(minutes: 15)
        ticket = state.beginCollection(.claude)!
        state.finishCollection(ticket, success(claudeObservation(at: clock.now, weekly: 41), key: "account-A"))
        XCTAssertEqual(state.slot(.claude).generation, generation)
        XCTAssertEqual(state.slot(.claude).acceptedAttempt, 4)
    }

    func testRemovedScopedCapLeavesNoGhostRow() async {
        claude.push(success(claudeObservation(at: t0, fable: 10)))
        let state = makeState()
        await state.refreshQuotas()
        XCTAssertEqual(MacQuotaDisplay.rows(state.presentation(.claude), title: "CLAUDE").map(\.title), ["CLAUDE", "FABLE"])

        clock.advance(minutes: 15)
        claude.push(success(claudeObservation(at: clock.now, fable: nil)))
        await state.refreshQuotas()
        XCTAssertEqual(state.slot(.claude).observation?.windows.map(\.id), ["claude:5h", "claude:7d"])
        XCTAssertEqual(MacQuotaDisplay.rows(state.presentation(.claude), title: "CLAUDE").map(\.title), ["CLAUDE"])
    }

    // MARK: Migration and relaunch

    private func seedLegacyCaches(claudeFetchedAt: Date) throws {
        let legacyClaude = ProviderLimits(
            fiveHour: LimitWindow(usedPercent: 62, resetsAt: claudeFetchedAt.addingTimeInterval(-60)),
            weekly: LimitWindow(usedPercent: 0, resetsAt: nil),
            scopedWeekly: [ScopedLimit(name: "Fable", window: LimitWindow(usedPercent: 8, resetsAt: claudeFetchedAt.addingTimeInterval(86_400)))],
            fetchedAt: claudeFetchedAt)
        let legacyCodex = ProviderLimits(fiveHour: nil, weekly: LimitWindow(usedPercent: 11, resetsAt: t0.addingTimeInterval(86_400)),
                                         scopedWeekly: nil, fetchedAt: t0)
        defaults.set(try JSONEncoder().encode(legacyClaude), forKey: "cachedClaudeLimits")
        defaults.set(try JSONEncoder().encode(legacyCodex), forKey: "cachedCodexLimits")
        defaults.set(Data(usageJSON.utf8), forKey: "cachedUsageResponse")
        defaults.set(t0.addingTimeInterval(-300), forKey: "cacheTimestamp")
    }

    func testLegacyClaudeKeepsItsDateLegacyCodexIsDroppedAndCostDataIsUntouched() async throws {
        let legacyDate = t0.addingTimeInterval(-20 * 60)
        try seedLegacyCaches(claudeFetchedAt: legacyDate)
        let state = makeState()

        let claudeSlot = state.slot(.claude)
        XCTAssertEqual(claudeSlot.observation?.observedAt, legacyDate)
        XCTAssertEqual(claudeSlot.observation?.source, "claude-oauth-usage")
        XCTAssertEqual(claudeSlot.observation?.windows.map(\.id), ["claude:5h", "claude:7d", "claude:model:fable"])
        XCTAssertEqual(claudeSlot.observation?.windows.map(\.usedPercent), [62, 0, 8])
        XCTAssertNil(state.slot(.codex).observation, "log-derived Codex values are never presented as current")
        XCTAssertEqual(state.presentation(.codex).freshness, .unknown)

        // The migrated 5-hour reset already passed: it reads as unconfirmed, not 0%.
        let fiveHour = state.presentation(.claude).windows.first { $0.window.id == "claude:5h" }
        XCTAssertEqual(fiveHour?.state, .resetPassedUnconfirmed)

        // Cost data loads exactly as before and its cache bytes are unchanged.
        XCTAssertEqual(state.dailyData.map(\.date), ["2026-10-13"])
        XCTAssertEqual(state.totals?.totalCost, 1.5)
        XCTAssertEqual(state.lastRefresh, t0.addingTimeInterval(-300))
        await state.refreshQuotas()
        XCTAssertEqual(defaults.data(forKey: "cachedUsageResponse"), Data(usageJSON.utf8))
        XCTAssertEqual(defaults.object(forKey: "cacheTimestamp") as? Date, t0.addingTimeInterval(-300))
    }

    func testRelaunchKeepsObservationDatesAndDoesNotMigrateAgain() async throws {
        try seedLegacyCaches(claudeFetchedAt: t0.addingTimeInterval(-20 * 60))
        codex.push(success(codexObservation(at: t0)))
        let first = makeState()
        await first.refreshQuotas()
        let slots = first.providerSlots

        // A later legacy write must not be picked up again.
        defaults.set(try JSONEncoder().encode(ProviderLimits(fiveHour: LimitWindow(usedPercent: 99, resetsAt: nil),
                                                             weekly: nil, scopedWeekly: nil, fetchedAt: t0)),
                     forKey: "cachedClaudeLimits")
        clock.advance(minutes: 120)
        let relaunched = makeState()
        XCTAssertEqual(relaunched.providerSlots, slots)
        XCTAssertEqual(relaunched.slot(.codex).observation?.observedAt, t0)
        XCTAssertEqual(relaunched.presentation(.codex).freshness, .outdated(.aged))
        XCTAssertEqual(relaunched.dailyData.count, 1)
    }

    func testImplausibleLegacyClaudeDateIsNotMigrated() throws {
        try seedLegacyCaches(claudeFetchedAt: t0.addingTimeInterval(400 * 86_400 * 100))
        XCTAssertNil(makeState().slot(.claude).observation)
    }

    func testFreshInstallStartsUnknownForBothProviders() {
        let state = makeState()
        XCTAssertEqual(state.providerSlots.map(\.provider), [.claude, .codex])
        XCTAssertEqual(state.providerSlots.map(\.observation), [nil, nil])
        XCTAssertEqual(state.providerSlots.map(\.acceptedAttempt), [0, 0])
        XCTAssertNotEqual(state.slot(.claude).generation, state.slot(.codex).generation)
    }

    // MARK: Expired, unconfirmed windows on the Mac (AE6)

    func testMacUsesThePhonePolicyForAPassedReset() async {
        claude.push(success(claudeObservation(at: t0, fiveHour: 62, weekly: 30, fable: nil,
                                              fiveHourReset: t0.addingTimeInterval(20 * 60))))
        let state = makeState()
        await state.refreshQuotas()
        XCTAssertEqual(state.hottestLimit?.hint, "CL")
        XCTAssertEqual(state.hottestLimit?.percent, 62)

        clock.advance(minutes: 30)
        let presentation = state.presentation(.claude)
        XCTAssertEqual(presentation, QuotaPresentation(now: clock.now).provider(state.slot(.claude)),
                       "the Mac reads the same shared policy the phone uses")
        XCTAssertEqual(presentation.windows.map(\.state), [.resetPassedUnconfirmed, .current])

        let row = MacQuotaDisplay.rows(presentation, title: "CLAUDE")[0]
        let fiveHour = MacQuotaDisplay.gauge(try! XCTUnwrap(row.short))
        XCTAssertEqual(fiveHour.percentText, "62%", "never shown as a verified 0%")
        XCTAssertTrue(fiveHour.isStruckThrough)
        XCTAssertEqual(fiveHour.tone, .neutral)
        XCTAssertNil(fiveHour.resetsAt)

        let weekly = MacQuotaDisplay.gauge(try! XCTUnwrap(row.long))
        XCTAssertEqual(weekly.percentText, "30%")
        XCTAssertFalse(weekly.isStruckThrough)
        XCTAssertEqual(weekly.tone, .normal)
        XCTAssertNotNil(weekly.resetsAt)

        XCTAssertEqual(state.hottestLimit?.percent, 30, "the passed window drops out of the menu bar hint")
    }

    func testOutdatedNumbersLeaveTheMenuBarButStayInThePopover() async {
        claude.push(success(claudeObservation(at: t0, fiveHour: 85, weekly: 30, fable: 90)))
        let state = makeState()
        await state.refreshQuotas()
        XCTAssertEqual(state.hottestLimit?.hint, "FA")
        XCTAssertTrue(state.limitWarningActive)
        XCTAssertEqual(state.menuBarLabel, "FA 90%")

        clock.advance(minutes: 61)
        XCTAssertNil(state.hottestLimit)
        XCTAssertFalse(state.limitWarningActive)
        XCTAssertEqual(state.menuBarLabel, "--")

        let presentation = state.presentation(.claude)
        XCTAssertEqual(presentation.freshness, .outdated(.aged))
        XCTAssertEqual(MacQuotaDisplay.ageText(presentation), "1h ago")
        let gauge = MacQuotaDisplay.gauge(MacQuotaDisplay.rows(presentation, title: "CLAUDE")[0].short!)
        XCTAssertEqual(gauge.percentText, "85%")
        XCTAssertEqual(gauge.tone, .neutral, "dated history is shown without the warning color")
        XCTAssertFalse(gauge.isStruckThrough)
    }

    func testCurrentZeroIsAConfirmedZero() async {
        claude.push(success(claudeObservation(at: t0, fiveHour: 0, weekly: 30, fable: nil)))
        let state = makeState()
        await state.refreshQuotas()
        let gauge = MacQuotaDisplay.gauge(MacQuotaDisplay.rows(state.presentation(.claude), title: "CLAUDE")[0].short!)
        XCTAssertEqual(gauge.percentText, "0%")
        XCTAssertEqual(gauge.tone, .normal)
        XCTAssertEqual(MacQuotaDisplay.ageText(state.presentation(.claude)), "now")
    }

    func testRowsPlaceWindowsByLengthAndNeverDropOne() {
        let observation = QuotaObservation(source: "codex-app-server", observedAt: t0, windows: [
            window("codex:codex:10080", "Weekly", minutes: 10_080, used: 13, resetsAt: nil),
            window("codex:codex:300", "5-hour", minutes: 300, used: 40, resetsAt: nil),
            window("codex:codex:60", "1-hour", minutes: 60, used: 1, resetsAt: nil),
            window("codex:spark:300", "Spark", minutes: 300, used: 4, resetsAt: nil, scope: .model),
        ], resetCredits: nil, creditBalance: nil)
        let slot = ProviderSlot(provider: .codex, generation: "g", acceptedAttempt: 1, observation: observation, lastAttempt: nil)
        let rows = MacQuotaDisplay.rows(QuotaPresentation(now: t0).provider(slot), title: "CODEX")
        // The standard 5-hour and weekly windows own the provider row; any
        // other account-wide window gets a row of its own.
        XCTAssertEqual(rows.map(\.title), ["CODEX", "1-HOUR", "SPARK"])
        XCTAssertEqual(rows[0].short?.window.id, "codex:codex:300")
        XCTAssertEqual(rows[0].long?.window.id, "codex:codex:10080")
        XCTAssertEqual(rows[1].short?.window.id, "codex:codex:60")
        XCTAssertNil(rows[1].long)
        XCTAssertEqual(rows[2].short?.window.id, "codex:spark:300")
        XCTAssertFalse(rows[0].isModel)
        XCTAssertTrue(rows[2].isModel)
        XCTAssertEqual(MacQuotaDisplay.gauge(rows[0].short!).label, "5h")
        XCTAssertEqual(MacQuotaDisplay.gauge(rows[0].long!).label, "wk")
        XCTAssertEqual(MacQuotaDisplay.gauge(rows[1].short!).label, "1h")
    }
}
