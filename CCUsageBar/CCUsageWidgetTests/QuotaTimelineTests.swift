import XCTest

// Sample readings shaped like the Mac's real October 14 collection.
enum WidgetFixtures {
    // Wednesday, October 14, 2026, 11:42:21 AM in Los Angeles.
    static let claudeObservedAt = Date(timeIntervalSinceReferenceDate: 813_696_141)
    static let codexObservedAt = Date(timeIntervalSinceReferenceDate: 813_695_200)
    static let fiveHourReset = Date(timeIntervalSinceReferenceDate: 813_713_399)  // 4:29:59 PM
    static let weeklyReset = Date(timeIntervalSinceReferenceDate: 813_967_199)    // Sat 2:59:59 PM
    static let codexWeeklyReset = Date(timeIntervalSinceReferenceDate: 814_166_108)
    static let creditExpiry = Date(timeIntervalSinceReferenceDate: 814_394_460)   // Oct 22
    static let incarnationCreatedAt = Date(timeIntervalSinceReferenceDate: 813_000_000)

    static let locale = Locale(identifier: "en_US")
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    static func claude(fiveHour: Double = 2, weekly: Double = 17, fable: Double? = 0,
                       observedAt: Date = claudeObservedAt, extraCaps: [QuotaWindow] = []) -> ProviderSlot {
        var windows = [
            // Deliberately out of order: the widget sorts them.
            QuotaWindow(id: "claude:7d", label: "Weekly", durationMinutes: 10_080, usedPercent: weekly,
                        resetsAt: weeklyReset, scope: .provider),
            QuotaWindow(id: "claude:5h", label: "5-hour", durationMinutes: 300, usedPercent: fiveHour,
                        resetsAt: fiveHourReset, scope: .provider),
        ]
        if let fable {
            windows.insert(QuotaWindow(id: "claude:model:fable", label: "Fable", durationMinutes: 10_080,
                                       usedPercent: fable, resetsAt: weeklyReset.addingTimeInterval(1), scope: .model), at: 0)
        }
        windows += extraCaps
        return ProviderSlot(provider: .claude, generation: "gen-claude", acceptedAttempt: 4,
                            observation: QuotaObservation(source: "oauth-usage", observedAt: observedAt, windows: windows,
                                                          resetCredits: nil, creditBalance: nil),
                            lastAttempt: CollectionAttempt(at: observedAt, outcome: .success))
    }

    static func codex(weekly: Double = 13, observedAt: Date = codexObservedAt) -> ProviderSlot {
        ProviderSlot(provider: .codex, generation: "gen-codex", acceptedAttempt: 9,
                     observation: QuotaObservation(
                        source: "codex-app-server", observedAt: observedAt,
                        windows: [QuotaWindow(id: "codex:codex:10080", label: "Weekly", durationMinutes: 10_080,
                                              usedPercent: weekly, resetsAt: codexWeeklyReset, scope: .provider)],
                        resetCredits: ResetCreditsInfo(available: 3, nextExpiry: creditExpiry),
                        creditBalance: 62_493.38),
                     lastAttempt: CollectionAttempt(at: observedAt, outcome: .success))
    }

    static func snapshot(revision: Int64 = 10, providers: [ProviderSlot]? = nil) -> QuotaSnapshot {
        QuotaSnapshot(version: QuotaSnapshot.currentVersion, revision: revision,
                      publishedAt: claudeObservedAt.addingTimeInterval(5),
                      providers: providers ?? [codex(), claude()])
    }

    static func result(_ snapshot: QuotaSnapshot) -> CloudFetchResult {
        .snapshot(snapshot, CloudSnapshotMetadata(incarnation: "inc-A", incarnationCreatedAt: incarnationCreatedAt,
                                                  revision: snapshot.revision))
    }

    static func modelCap(_ index: Int, used: Double) -> QuotaWindow {
        QuotaWindow(id: "claude:model:cap-\(index)",
                    label: "Extremely long experimental model name number \(index)",
                    durationMinutes: 10_080, usedPercent: used, resetsAt: weeklyReset, scope: .model)
    }
}

// Runs closures and counts the calls, so tests can prove no cloud work happened.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func hit() { lock.lock(); value += 1; lock.unlock() }
}

final class QuotaTimelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seededCache(_ snapshot: QuotaSnapshot = WidgetFixtures.snapshot()) -> PhoneSnapshotCache {
        let cache = PhoneSnapshotCache(directory: directory)
        cache.bind(account: .available(accountHash: "hash-A"))
        XCTAssertEqual(cache.commit(WidgetFixtures.result(snapshot), ticket: cache.beginFetch()), .stored)
        return cache
    }

    private func loader(cache: PhoneSnapshotCache,
                        account: CloudAccountStatus = .available(accountHash: "hash-A"),
                        accountDelay: Duration = .zero,
                        fetch: @escaping () async -> CloudFetchResult = { .unavailable("offline") },
                        pagedRecently: Bool = false,
                        deadline: Duration = .seconds(5),
                        now: Date,
                        calls: CallCounter = CallCounter()) -> QuotaTimelineLoader {
        QuotaTimelineLoader(
            cache: cache,
            checkAccount: {
                calls.hit()
                if accountDelay > .zero { try? await Task.sleep(for: accountDelay) }
                return account
            },
            fetchLatest: {
                calls.hit()
                return await fetch()
            },
            pagedRecently: { pagedRecently },
            deadline: deadline,
            now: { now })
    }

    private func normalized(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: Scenario 1 (AE2): both providers, a model cap, resets, and each provider's own age

    func testBothProvidersRenderPercentagesResetsAndTheirOwnReadingTimes() throws {
        let now = WidgetFixtures.claudeObservedAt.addingTimeInterval(5 * 60)
        let sections = QuotaWidgetModel.sections(for: WidgetFixtures.snapshot(), now: now)

        XCTAssertEqual(sections.map(\.name), ["Claude", "Codex"])
        let claude = sections[0], codex = sections[1]
        XCTAssertEqual(claude.observedAt, WidgetFixtures.claudeObservedAt)
        XCTAssertEqual(codex.observedAt, WidgetFixtures.codexObservedAt)
        XCTAssertEqual(claude.freshness, .current)
        XCTAssertEqual(codex.freshness, .current)

        // Account-wide windows first, shorter first, then the model cap.
        XCTAssertEqual(claude.rows.map(\.id), ["claude:5h", "claude:7d", "claude:model:fable"])
        XCTAssertEqual(claude.rows.map(\.label), ["5-hour", "Weekly", "Fable weekly"])
        XCTAssertEqual(claude.rows.map(\.shortLabel), ["5h", "Wk", "Fable"])
        XCTAssertEqual(claude.rows.map(\.tint), [.claude, .claude, .fable])
        XCTAssertEqual(claude.rows.map(\.isModelCap), [false, false, true])
        XCTAssertEqual(codex.rows.map(\.shortLabel), ["Wk"])
        XCTAssertEqual(codex.rows.map(\.tint), [.codex])

        let fiveHour = claude.rows[0]
        XCTAssertEqual(QuotaWidgetModel.percentText(fiveHour, density: .full), "2% used")
        XCTAssertEqual(QuotaWidgetModel.percentText(fiveHour, density: .compact), "2% used")
        XCTAssertEqual(QuotaWidgetModel.percentText(fiveHour, density: .mini), "2%")
        let tz = WidgetFixtures.timeZone, locale = WidgetFixtures.locale
        XCTAssertEqual(normalized(QuotaWidgetModel.resetText(fiveHour, density: .full, locale: locale, timeZone: tz)),
                       "· resets 4:29 PM")
        XCTAssertEqual(normalized(QuotaWidgetModel.resetText(fiveHour, density: .compact, locale: locale, timeZone: tz)),
                       "4:29 PM")
        XCTAssertNil(QuotaWidgetModel.resetText(fiveHour, density: .mini, locale: locale, timeZone: tz))
        XCTAssertEqual(normalized(QuotaWidgetModel.resetText(claude.rows[1], density: .full, locale: locale, timeZone: tz)),
                       "· resets Sat 2:59 PM")

        // Codex extras: full resets with the next expiry, and the credit balance.
        let credits = try XCTUnwrap(codex.resetCredits)
        XCTAssertEqual(QuotaWidgetModel.resetCreditsText(credits, now: now, density: .full, locale: locale, timeZone: tz),
                       "3 full resets · next expires Oct 22")
        XCTAssertEqual(QuotaWidgetModel.resetCreditsText(credits, now: now, density: .mini, locale: locale, timeZone: tz),
                       "3 full resets")
        let soon = ResetCreditsInfo(available: 1, nextExpiry: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(QuotaWidgetModel.resetCreditsText(soon, now: now, density: .compact, locale: locale, timeZone: tz),
                       "1 full reset · next expires Fri")
        XCTAssertEqual(QuotaWidgetModel.creditBalanceText(try XCTUnwrap(codex.creditBalance), locale: locale),
                       "62,493 credits")
        XCTAssertEqual(codex.extrasLineCount, 2)
        XCTAssertEqual(claude.extrasLineCount, 0)

        // VoiceOver gets the provider, the window, the percentage, and the reset.
        let spoken = normalized(QuotaWidgetModel.accessibilityLabel(claude.rows[2], in: claude, locale: locale, timeZone: tz))
        XCTAssertEqual(spoken, "Claude Fable weekly model limit, 0 percent used, resets Saturday 3:00 PM")
    }

    func testSmallSizeShowsAModelCapOnlyWhenItIsCloserToItsLimitThanEveryAccountWideWindow() {
        let now = WidgetFixtures.claudeObservedAt
        func smallIDs(fable: Double) -> [String] {
            let snapshot = WidgetFixtures.snapshot(providers: [WidgetFixtures.claude(fiveHour: 2, weekly: 17, fable: fable)])
            return QuotaWidgetModel.sections(for: snapshot, now: now)[0].smallRows.map(\.id)
        }
        XCTAssertEqual(smallIDs(fable: 0), ["claude:5h", "claude:7d"])
        XCTAssertEqual(smallIDs(fable: 17), ["claude:5h", "claude:7d"])
        XCTAssertEqual(smallIDs(fable: 40), ["claude:5h", "claude:7d", "claude:model:fable"])

        // Several caps past every account-wide window: only the closest to its limit fits.
        let crowded = WidgetFixtures.snapshot(providers: [WidgetFixtures.claude(
            fiveHour: 2, weekly: 17, fable: 40,
            extraCaps: [WidgetFixtures.modelCap(1, used: 70), WidgetFixtures.modelCap(2, used: 10)])])
        XCTAssertEqual(QuotaWidgetModel.sections(for: crowded, now: now)[0].smallRows.map(\.id),
                       ["claude:5h", "claude:7d", "claude:model:cap-1"])
    }

    // R10: one provider without a reading doesn't hide the other.
    func testProviderWithoutAReadingShowsAsUnknownBesideTheOther() {
        let snapshot = WidgetFixtures.snapshot(providers: [WidgetFixtures.claude()])
        let sections = QuotaWidgetModel.sections(for: snapshot, now: WidgetFixtures.claudeObservedAt)
        XCTAssertEqual(sections.map(\.provider), [.claude, .codex])
        XCTAssertEqual(sections[1].freshness, .unknown)
        XCTAssertNil(sections[1].observedAt)
        XCTAssertTrue(sections[1].rows.isEmpty)
        XCTAssertEqual(sections[0].rows.count, 3)
    }

    // MARK: Scenario 3 (AE6): offline time passes; values go outdated, never zero

    func testOfflineTimelineCrossesResetAndAgeBoundariesWithoutZeroing() async throws {
        let observed = WidgetFixtures.claudeObservedAt
        let now = observed.addingTimeInterval(10 * 60)
        let reset = observed.addingTimeInterval(20 * 60)
        var claude = WidgetFixtures.claude(fiveHour: 42)
        claude.observation?.windows[2].resetsAt = reset   // the 5-hour window
        let snapshot = WidgetFixtures.snapshot(providers: [claude, WidgetFixtures.codex()])
        let cache = seededCache(snapshot)

        let timeline = await loader(cache: cache, now: now).timeline()
        let dates = timeline.entries.map(\.date)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(dates.contains(reset), "an entry at the reset time")
        XCTAssertTrue(dates.contains(observed.addingTimeInterval(QuotaPresentation.outdatedAfter)), "Claude's one-hour mark")
        XCTAssertTrue(dates.contains(WidgetFixtures.codexObservedAt.addingTimeInterval(QuotaPresentation.outdatedAfter)),
                      "Codex's one-hour mark")
        XCTAssertTrue(dates.contains(WidgetFixtures.weeklyReset))
        XCTAssertEqual(Set(dates).count, dates.count, "no duplicate entries")

        for entry in timeline.entries {
            // Every entry carries the same reading: time passing never makes a new one.
            XCTAssertEqual(entry.snapshot, snapshot)
            let row = try XCTUnwrap(QuotaWidgetModel.sections(for: try XCTUnwrap(entry.snapshot), now: entry.date)[0]
                .rows.first { $0.id == "claude:5h" })
            XCTAssertEqual(row.usedPercent, 42)
            XCTAssertEqual(QuotaWidgetModel.percentText(row, density: .compact), "42% used")
        }

        let atReset = try XCTUnwrap(timeline.entries.first { $0.date == reset })
        let resetRow = QuotaWidgetModel.sections(for: snapshot, now: atReset.date)[0].rows[0]
        XCTAssertEqual(resetRow.state, .resetPassedUnconfirmed)
        XCTAssertTrue(resetRow.isStale)
        XCTAssertEqual(QuotaWidgetModel.resetText(resetRow, density: .compact), "reset passed")
        XCTAssertTrue(normalized(QuotaWidgetModel.resetText(resetRow, density: .full))?.hasSuffix(", unconfirmed") ?? false)

        let aged = try XCTUnwrap(timeline.entries.first { $0.date == observed.addingTimeInterval(QuotaPresentation.outdatedAfter) })
        let agedClaude = QuotaWidgetModel.sections(for: snapshot, now: aged.date)[0]
        XCTAssertEqual(agedClaude.freshness, .outdated(.aged))
        XCTAssertTrue(agedClaude.rows.allSatisfy(\.isStale))
        XCTAssertEqual(agedClaude.rows.map(\.usedPercent), [42, 17, 0])
    }

    func testNextRefreshIsAboutThirtyMinutesOut() {
        let now = WidgetFixtures.claudeObservedAt
        XCTAssertEqual(QuotaTimelineLoader.nextRefresh(after: now), now.addingTimeInterval(30 * 60))
    }

    // MARK: Scenario 4 (AE5): a stalled or failed cloud read still completes with the cache

    func testStalledCloudFetchCompletesWithCachedReadings() async {
        let cache = seededCache()
        let started = Date()
        let entry = await loader(cache: cache,
                                 fetch: { try? await Task.sleep(for: .seconds(30)); return .timedOut },
                                 deadline: .milliseconds(300),
                                 now: WidgetFixtures.claudeObservedAt).load()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot())
        XCTAssertNil(entry.notice)
    }

    func testStalledAccountCheckCompletesWithCachedReadings() async {
        let cache = seededCache()
        let started = Date()
        let entry = await loader(cache: cache, accountDelay: .seconds(30), deadline: .milliseconds(300),
                                 now: WidgetFixtures.claudeObservedAt).load()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot())
    }

    func testFailedCloudFetchKeepsCachedReadingsAndTheirObservationTimes() async {
        let cache = seededCache()
        for failure: CloudFetchResult in [.unavailable("offline"), .timedOut, .malformed, .missing, .unsupported(version: 2)] {
            let entry = await loader(cache: cache, fetch: { failure }, now: WidgetFixtures.claudeObservedAt).load()
            XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot(), "\(failure)")
        }
        XCTAssertEqual(cache.read().stored?.snapshot.providers.first { $0.provider == .claude }?.observation?.observedAt,
                       WidgetFixtures.claudeObservedAt)
    }

    func testNewerCloudSnapshotIsSavedAndShown() async {
        let cache = seededCache()
        let newer = WidgetFixtures.snapshot(revision: 11, providers: [WidgetFixtures.claude(fiveHour: 30), WidgetFixtures.codex()])
        let entry = await loader(cache: cache, fetch: { WidgetFixtures.result(newer) },
                                 now: WidgetFixtures.claudeObservedAt).load()
        XCTAssertEqual(entry.snapshot, newer)
        XCTAssertEqual(cache.read().stored?.snapshot.revision, 11)
    }

    func testTransientAccountTroubleSkipsTheFetchAndKeepsTheCache() async {
        let cache = seededCache()
        let calls = CallCounter()
        let entry = await loader(cache: cache, account: .temporarilyUnavailable,
                                 fetch: { XCTFail("fetched without a confirmed account"); return .missing },
                                 now: WidgetFixtures.claudeObservedAt, calls: calls).load()
        XCTAssertEqual(calls.count, 1, "only the account check ran")
        XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot())
    }

    // MARK: Scenario 5 (AE1): honest placeholders before any data exists

    func testGalleryPlaceholderCarriesNoReadings() {
        let entry = QuotaTimelineLoader.placeholderEntry(now: WidgetFixtures.claudeObservedAt)
        XCTAssertNil(entry.snapshot)
        XCTAssertEqual(entry.notice, .preview)
        XCTAssertEqual(entry.page, 0)
    }

    func testFirstInstallWaitsForTheMacWithoutBars() async {
        let cache = PhoneSnapshotCache(directory: directory)
        let timeline = await loader(cache: cache, fetch: { .missing }, now: WidgetFixtures.claudeObservedAt).timeline()
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertNil(timeline.entries[0].snapshot)
        XCTAssertEqual(timeline.entries[0].notice, .waitingForFirstReading)
        XCTAssertTrue(QuotaWidgetModel.noticeText(.waitingForFirstReading).title.contains("Waiting for your Mac"))
    }

    func testICloudOffSaysSoAndClearsTheCache() async {
        let cache = seededCache()
        let entry = await loader(cache: cache, account: .noAccount, now: WidgetFixtures.claudeObservedAt).load()
        XCTAssertNil(entry.snapshot)
        XCTAssertEqual(entry.notice, .iCloudOff)
        XCTAssertNil(cache.read().stored)
        XCTAssertTrue(QuotaWidgetModel.noticeText(.iCloudOff).title.contains("iCloud is off"))
    }

    func testRestrictedICloudWithoutDataSaysSo() async {
        let cache = PhoneSnapshotCache(directory: directory)
        let entry = await loader(cache: cache, account: .restricted, now: WidgetFixtures.claudeObservedAt).load()
        XCTAssertEqual(entry.notice, .iCloudRestricted)
    }

    func testCachedEntryForSnapshotsReadsOnlyTheCache() {
        let calls = CallCounter()
        let cache = seededCache()
        let entry = loader(cache: cache, now: WidgetFixtures.claudeObservedAt, calls: calls).cachedEntry()
        XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot())
        XCTAssertEqual(calls.count, 0)
        let empty = loader(cache: PhoneSnapshotCache(directory: directory.appendingPathComponent("none")),
                           now: WidgetFixtures.claudeObservedAt).cachedEntry()
        XCTAssertNil(empty.snapshot)
        XCTAssertEqual(empty.notice, .waitingForFirstReading)
    }

    // MARK: Scenario 6: the reload after a page turn uses only local data

    func testReloadAfterAPageTurnSkipsICloud() async {
        let cache = seededCache()
        cache.updatePage { _ in 1 }
        let calls = CallCounter()
        let entry = await loader(cache: cache, fetch: { XCTFail("fetched after a page turn"); return .missing },
                                 pagedRecently: true, now: WidgetFixtures.claudeObservedAt, calls: calls).load()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(entry.page, 1)
        XCTAssertEqual(entry.snapshot, WidgetFixtures.snapshot())
    }
}
