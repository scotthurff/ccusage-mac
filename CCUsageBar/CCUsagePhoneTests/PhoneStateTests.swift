import XCTest

@MainActor
final class PhoneStateTests: XCTestCase {
    private var harness: PhoneHarness!

    override func setUp() async throws {
        harness = try PhoneHarness()
    }

    override func tearDown() async throws {
        harness.cleanUp()
        harness = nil
    }

    // MARK: Setup states (scenario 1, AE1)

    func testNoRecordYetShowsWaitingForTheMacAndNoBars() async {
        harness.responses = [.missing]
        let state = harness.makeState()
        XCTAssertEqual(state.notice?.kind, .checking)

        await state.refresh()

        XCTAssertNil(state.stored)
        XCTAssertEqual(state.notice?.kind, .waitingForFirstReading)
        XCTAssertTrue(state.providers(at: harness.now).isEmpty, "no provider rows means no fabricated 0% bars")
    }

    func testSignedOutOfICloudIsDistinctFromWaitingAndSkipsTheFetch() async {
        harness.account = .noAccount
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.notice?.kind, .signedOut)
        XCTAssertEqual(harness.fetchCount, 0)
        XCTAssertTrue(state.providers(at: harness.now).isEmpty)

        harness.account = .restricted
        await state.refresh()
        XCTAssertEqual(state.notice?.kind, .restricted)
        XCTAssertEqual(harness.fetchCount, 0)
    }

    func testFirstValidRecordShowsBothProvidersAndReloadsTheWidget() async {
        harness.responses = [PhoneFixtures.result(revision: 1)]
        let state = harness.makeState()
        await state.refresh()

        XCTAssertNil(state.notice)
        XCTAssertEqual(state.stored?.metadata.revision, 1)
        XCTAssertEqual(state.checkedAt, harness.now)
        let providers = state.providers(at: harness.now)
        XCTAssertEqual(providers.map(\.provider), [.claude, .codex])
        XCTAssertEqual(providers.first?.windows.map(\.window.usedPercent), [2, 17, 0])
        XCTAssertEqual(harness.widgetReloads, 1)
    }

    func testProviderMissingFromTheSnapshotShowsAsUnknownNotZero() async {
        var snapshot = PhoneFixtures.snapshot(revision: 1)
        snapshot.providers.removeAll { $0.provider == .codex }
        harness.responses = [.snapshot(snapshot, PhoneFixtures.metadata(revision: 1))]
        let state = harness.makeState()
        await state.refresh()

        let codex = state.providers(at: harness.now).last
        XCTAssertEqual(codex?.provider, .codex)
        XCTAssertEqual(codex?.freshness, .unknown)
        XCTAssertEqual(codex?.windows, [])
    }

    // MARK: Refresh keeps observation time (scenario 2, AE7)

    func testRefreshingAnUnchangedTenMinuteOldRecordKeepsItsAge() async {
        harness.responses = [PhoneFixtures.result(revision: 5), PhoneFixtures.result(revision: 5)]
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.providers(at: harness.now).first?.age, 600)

        await state.refresh()
        let claude = state.providers(at: harness.now).first
        XCTAssertEqual(claude?.age, 600)
        XCTAssertEqual(claude?.observedAt, PhoneFixtures.observedAt)
        XCTAssertEqual(claude.map { PhoneText.readingAge($0, now: harness.now) }, "Read on your Mac 10 minutes ago")
        XCTAssertEqual(harness.fetchCount, 2)
        XCTAssertEqual(harness.widgetReloads, 1, "an unchanged record doesn't reload the widget again")
    }

    // MARK: Offline and corrupt cache (scenario 3, AE5)

    func testOfflineLaunchShowsTheCacheFirstAndKeepsItsDates() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.account = .temporarilyUnavailable
        let state = harness.makeState()
        XCTAssertEqual(state.stored?.metadata.revision, 9, "cache renders before any network work")
        XCTAssertNil(state.notice, "data on screen while the first check runs")

        await state.refresh()

        XCTAssertEqual(state.stored?.metadata.revision, 9)
        XCTAssertEqual(state.notice?.kind, .unreachable)
        XCTAssertEqual(harness.fetchCount, 0, "an unverified account never fetches")
        let later = harness.now.addingTimeInterval(2 * 3600)
        let claude = state.providers(at: later).first
        XCTAssertEqual(claude?.freshness, .outdated(.aged))
        XCTAssertEqual(claude?.observedAt, PhoneFixtures.observedAt)
        XCTAssertEqual(claude?.windows.map(\.window.usedPercent), [2, 17, 0], "dated values, not zeros")
    }

    func testFetchFailureKeepsTheCache() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.responses = [.timedOut]
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.stored?.metadata.revision, 9)
        XCTAssertEqual(state.notice?.kind, .unreachable)
    }

    func testCorruptCacheWithNoNetworkShowsUnknownWithoutCrashing() async throws {
        try Data("not json at all".utf8).write(to: harness.cache.fileURL)
        harness.responses = [.unavailable("offline")]
        let state = harness.makeState()
        XCTAssertNil(state.stored)

        await state.refresh()

        XCTAssertNil(state.stored)
        XCTAssertEqual(state.notice?.kind, .unreachable)
        XCTAssertTrue(state.providers(at: harness.now).isEmpty)
    }

    func testMissingRecordKeepsTheLastReading() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.responses = [.missing]
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.stored?.metadata.revision, 9)
        XCTAssertEqual(state.notice?.kind, .noRecordKeepingCache)
    }

    // MARK: Account changes (scenario 5)

    func testResponseFromBeforeAnAccountChangeCannotRepopulateTheCache() async {
        harness.seedCache(revision: 9, account: "hash-A")
        let state = harness.makeState()
        harness.holdNextFetch = true
        harness.responses = [PhoneFixtures.result(revision: 1, incarnation: "inc-new-account",
                                                  createdAt: PhoneFixtures.incarnationCreatedAt.addingTimeInterval(-500))]
        let refresh = Task { await state.refresh() }
        await harness.waitForHeldFetch()

        harness.account = .available(accountHash: "hash-B")
        let change = Task { await state.accountChanged() }
        for _ in 0..<10_000 where state.stored != nil { await Task.yield() }
        XCTAssertEqual(harness.cache.read().accountHash, "hash-B", "the old account's data is gone before the fetch returns")
        harness.releaseHeldFetch(with: PhoneFixtures.result(revision: 10))
        await change.value
        await refresh.value

        // The late revision 10 from the old account was dropped; the rerun
        // fetched the new account's record.
        XCTAssertEqual(state.stored?.metadata.incarnation, "inc-new-account")
        XCTAssertEqual(harness.cache.read().accountHash, "hash-B")
        XCTAssertEqual(harness.fetchCount, 2)
    }

    func testTransientAccountFailureRetainsDatedData() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.account = .temporarilyUnavailable
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.stored?.metadata.revision, 9)
        XCTAssertEqual(harness.cache.read().generation, 0)
        XCTAssertEqual(harness.widgetReloads, 0)
    }

    func testSigningOutClearsDataAndReloadsTheWidget() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.account = .noAccount
        let state = harness.makeState()
        await state.refresh()
        XCTAssertNil(state.stored)
        XCTAssertEqual(state.notice?.kind, .signedOut)
        XCTAssertEqual(harness.widgetReloads, 1)
    }

    // MARK: Future schema (scenario 6)

    func testFutureSchemaKeepsTheCacheAndAsksForAnAppUpdate() async {
        harness.seedCache(revision: 9, account: "hash-A")
        harness.responses = [.unsupported(version: 2)]
        let state = harness.makeState()
        await state.refresh()
        XCTAssertEqual(state.stored?.metadata.revision, 9)
        XCTAssertEqual(state.notice?.kind, .updateRequired)
        XCTAssertTrue(state.notice?.title.contains("Update") ?? false)
    }

    // MARK: Deep links

    func testProviderLinksFocusThatProvider() {
        XCTAssertEqual(PhoneState.provider(fromDeepLink: URL(string: "ccusage://provider/claude")!), .claude)
        XCTAssertEqual(PhoneState.provider(fromDeepLink: URL(string: "ccusage://provider/codex")!), .codex)
        XCTAssertEqual(PhoneState.provider(fromDeepLink: URL(string: "CCUSAGE://Provider/Codex")!), .codex)
        XCTAssertNil(PhoneState.provider(fromDeepLink: URL(string: "ccusage://provider/gemini")!))
        XCTAssertNil(PhoneState.provider(fromDeepLink: URL(string: "ccusage://settings/claude")!))
        XCTAssertNil(PhoneState.provider(fromDeepLink: URL(string: "https://provider/claude")!))

        let state = harness.makeState()
        state.open(URL(string: "ccusage://provider/codex")!)
        XCTAssertEqual(state.focusedProvider, .codex)
    }

    // MARK: Wording, local time, and VoiceOver (scenario 7)

    func testReadingAgeSaysTheTimeBelongsToTheMac() {
        let presentation = QuotaPresentation(now: harness.now)
        let snapshot = PhoneFixtures.snapshot()
        func age(after seconds: TimeInterval) -> String {
            let now = PhoneFixtures.observedAt.addingTimeInterval(seconds)
            return PhoneText.readingAge(QuotaPresentation(now: now).provider(snapshot.providers[0]), now: now)
        }
        XCTAssertEqual(age(after: 20), "Read on your Mac just now")
        XCTAssertEqual(age(after: 60), "Read on your Mac 1 minute ago")
        XCTAssertEqual(age(after: 12 * 60), "Read on your Mac 12 minutes ago")
        XCTAssertEqual(age(after: 65 * 60), "Read on your Mac 1 hr 5 min ago")
        XCTAssertEqual(age(after: 3 * 3600), "Read on your Mac 3 hours ago")
        XCTAssertEqual(age(after: 2 * 86_400 + 60), "Read on your Mac 2 days ago")

        let unknown = presentation.provider(ProviderSlot(provider: .codex, generation: "g", acceptedAttempt: 0,
                                                         observation: nil, lastAttempt: nil))
        XCTAssertEqual(PhoneText.readingAge(unknown, now: harness.now), "Your Mac hasn't read Codex limits yet")
    }

    func testFreshnessWording() {
        XCTAssertEqual(PhoneText.freshness(.current), "Current")
        XCTAssertEqual(PhoneText.freshness(.outdated(.aged)), "Outdated · over an hour old")
        XCTAssertEqual(PhoneText.freshness(.outdated(.failedAttempt)), "Outdated · your Mac's last check failed")
        XCTAssertEqual(PhoneText.freshness(.unknown), "No reading yet")
        XCTAssertEqual(PhoneText.freshness(.unverified), "Unverified time")
    }

    func testResetTimesFollowTheTimeZone() {
        let reset = Self.utc(2026, 10, 17, 21, 59)       // Saturday 2:59 PM in Los Angeles
        let now = Self.utc(2026, 10, 14, 19, 0)
        XCTAssertEqual(Self.plain(PhoneText.localTime(reset, now: now, calendar: Self.calendar("America/Los_Angeles"),
                                                      locale: Self.english)), "Saturday 2:59 PM")
        XCTAssertEqual(Self.plain(PhoneText.localTime(reset, now: now, calendar: Self.calendar("Asia/Tokyo"),
                                                      locale: Self.english)), "Sunday 6:59 AM")
        let sameDay = Self.utc(2026, 10, 14, 23, 59)
        XCTAssertEqual(Self.plain(PhoneText.localTime(sameDay, now: now, calendar: Self.calendar("America/Los_Angeles"),
                                                      locale: Self.english)), "today 4:59 PM")
        let farOff = Self.utc(2026, 10, 23, 21, 59)
        XCTAssertEqual(Self.plain(PhoneText.localTime(farOff, now: now, calendar: Self.calendar("America/Los_Angeles"),
                                                      locale: Self.english)), "Oct 23 at 2:59 PM")
    }

    func testWindowLabelsAndVoiceOverText() throws {
        let la = Self.calendar("America/Los_Angeles")
        let now = Self.utc(2026, 10, 14, 19, 0)
        let observedAt = now.addingTimeInterval(-600)
        let slot = ProviderSlot(
            provider: .claude, generation: "g", acceptedAttempt: 1,
            observation: QuotaObservation(source: "test", observedAt: observedAt, windows: [
                PhoneFixtures.window("claude:5h", "5-hour", minutes: 300, used: 2, resetsAt: now.addingTimeInterval(-60)),
                PhoneFixtures.window("claude:7d", "Weekly", minutes: 10_080, used: 17, resetsAt: Self.utc(2026, 10, 17, 21, 59)),
                PhoneFixtures.window("claude:fable", "Fable", minutes: 10_080, used: 0,
                                     resetsAt: Self.utc(2026, 10, 17, 22, 0), scope: .model),
            ], resetCredits: nil, creditBalance: nil),
            lastAttempt: nil)
        let provider = QuotaPresentation(now: now).provider(slot)
        let windows = provider.windows
        func label(_ index: Int, _ p: ProviderPresentation = provider) -> String {
            Self.plain(PhoneText.accessibilityLabel(p.windows[index], provider: p, now: now, calendar: la, locale: Self.english))
        }

        XCTAssertEqual(label(1), "Claude weekly, 17 percent used, resets Saturday 2:59 PM")
        XCTAssertEqual(label(0), "Claude 5-hour, 2 percent used, reset time passed today 11:59 AM, not yet confirmed")
        XCTAssertEqual(label(2), "Claude Fable model limit, 0 percent used, resets Saturday 3:00 PM")
        XCTAssertEqual(PhoneText.windowLabel(windows[2].window), "Fable · model limit")
        XCTAssertEqual(PhoneText.percentUsed(windows[1].window), "17% used")
        XCTAssertEqual(Self.plain(PhoneText.reset(windows[1], now: now, calendar: la, locale: Self.english) ?? ""),
                       "Resets Saturday 2:59 PM")
        XCTAssertEqual(Self.plain(PhoneText.reset(windows[0], now: now, calendar: la, locale: Self.english) ?? ""),
                       "Reset time passed today 11:59 AM · not yet confirmed")

        let outdated = QuotaPresentation(now: now.addingTimeInterval(7200)).provider(slot)
        XCTAssertEqual(label(2, outdated), "Claude Fable model limit, 0 percent used, resets Saturday 3:00 PM, outdated reading")
    }

    func testCodexCreditsWording() {
        let now = Self.utc(2026, 10, 14, 19, 0)
        let la = Self.calendar("America/Los_Angeles")
        let credits = ResetCreditsInfo(available: 3, nextExpiry: Self.utc(2026, 10, 22, 18, 41))
        XCTAssertEqual(Self.plain(PhoneText.resetCredits(credits, now: now, calendar: la, locale: Self.english)),
                       "3 full resets · next expires Oct 22 at 11:41 AM")
        XCTAssertEqual(PhoneText.resetCredits(ResetCreditsInfo(available: 1, nextExpiry: nil), now: now,
                                              calendar: la, locale: Self.english), "1 full reset")
        XCTAssertEqual(PhoneText.resetCredits(ResetCreditsInfo(available: 0, nextExpiry: nil), now: now,
                                              calendar: la, locale: Self.english), "No full resets")
        XCTAssertEqual(PhoneText.creditBalance(62_493.38, locale: Self.english), "62,493 credits")
        XCTAssertEqual(PhoneText.checked(now.addingTimeInterval(-120), now: now), "Checked iCloud 2 minutes ago")
    }

    // MARK: Helpers

    private static let english = Locale(identifier: "en_US")

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar("UTC").date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // iOS formats "2:59 PM" with a narrow no-break space; compare as plain spaces.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

@MainActor
private final class PhoneHarness {
    let directory: URL
    var account: CloudAccountStatus = .available(accountHash: "hash-A")
    var responses: [CloudFetchResult] = []
    var holdNextFetch = false
    var now = PhoneFixtures.observedAt.addingTimeInterval(600)
    private(set) var fetchCount = 0
    private(set) var widgetReloads = 0
    private var heldFetch: CheckedContinuation<CloudFetchResult, Never>?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var cache: PhoneSnapshotCache { PhoneSnapshotCache(directory: directory) }

    func makeState() -> PhoneState {
        PhoneState(cache: cache,
                   fetchLatest: { await self.fetch() },
                   checkAccount: { self.account },
                   reloadWidgets: { self.widgetReloads += 1 },
                   clock: { self.now })
    }

    func seedCache(revision: Int64, account: String) {
        let cache = cache
        cache.bind(account: .available(accountHash: account))
        cache.commit(PhoneFixtures.result(revision: revision), ticket: cache.beginFetch())
    }

    private func fetch() async -> CloudFetchResult {
        fetchCount += 1
        if holdNextFetch {
            holdNextFetch = false
            return await withCheckedContinuation { heldFetch = $0 }
        }
        return responses.isEmpty ? .missing : responses.removeFirst()
    }

    func waitForHeldFetch(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where heldFetch == nil { await Task.yield() }
        if heldFetch == nil { XCTFail("the fetch never started", file: file, line: line) }
    }

    func releaseHeldFetch(with result: CloudFetchResult) {
        heldFetch?.resume(returning: result)
        heldFetch = nil
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
