import SwiftUI
import WidgetKit
import XCTest

final class QuotaPagingTests: XCTestCase {
    // Content heights after the system's margins: iPhone Pro Max sizes, and
    // the smallest current iPhone for a tighter check.
    private let largeHeight: CGFloat = 350
    private let mediumHeight: CGFloat = 138
    private let smallPhoneLargeHeight: CGFloat = 313
    private let smallPhoneMediumHeight: CGFloat = 123

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetPaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sections(_ snapshot: QuotaSnapshot = WidgetFixtures.snapshot()) -> [WidgetSection] {
        QuotaWidgetModel.sections(for: snapshot, now: WidgetFixtures.claudeObservedAt)
    }

    // Every row of every section, in display order, as (section, row) pairs.
    private func allRows(_ sections: [WidgetSection]) -> [String] {
        sections.flatMap { section in section.rows.map { "\(section.provider.rawValue)/\($0.id)" } }
    }

    private func shownRows(_ pages: [[WidgetPageSlice]], _ sections: [WidgetSection]) -> [String] {
        pages.flatMap { page in
            page.flatMap { slice in
                sections[slice.section].rows[slice.rows].map { "\(sections[slice.section].provider.rawValue)/\($0.id)" }
            }
        }
    }

    private func extrasShown(_ pages: [[WidgetPageSlice]], section: Int) -> Int {
        pages.flatMap { $0 }.filter { $0.section == section && $0.showsExtras }.count
    }

    // MARK: Scenario 2: overflow, long labels, text size, removed caps

    func testApprovedLayoutFitsOnOnePageAtTheDefaultTextSize() {
        let sections = sections()
        for height in [largeHeight, smallPhoneLargeHeight] {
            XCTAssertEqual(QuotaPaging.pages(for: sections, family: .systemLarge, height: height, typeSize: .large).count, 1)
        }
        for height in [mediumHeight, smallPhoneMediumHeight] {
            XCTAssertEqual(QuotaPaging.pages(for: sections, family: .systemMedium, height: height, typeSize: .large).count, 1)
        }
        // At the largest text a Home Screen widget draws, the Pro Max sizes still need no paging.
        let largest = QuotaPaging.largestWidgetTextSize
        XCTAssertEqual(QuotaPaging.pages(for: sections, family: .systemLarge, height: largeHeight, typeSize: largest).count, 1)
        XCTAssertEqual(QuotaPaging.pages(for: sections, family: .systemMedium, height: mediumHeight, typeSize: largest).count, 1)
    }

    func testOverflowingCapsWithLongLabelsAreAllReachableInStableOrder() {
        let caps = (1...8).map { WidgetFixtures.modelCap($0, used: Double($0 * 10)) }
        let snapshot = WidgetFixtures.snapshot(providers: [WidgetFixtures.codex(), WidgetFixtures.claude(extraCaps: caps)])
        let sections = sections(snapshot)
        // Provider-wide windows stay ahead of model caps.
        XCTAssertEqual(Array(sections[0].rows.prefix(2).map(\.id)), ["claude:5h", "claude:7d"])
        XCTAssertTrue(sections[0].rows.dropFirst(2).allSatisfy(\.isModelCap))

        for (family, height) in [(WidgetFamily.systemLarge, largeHeight), (.systemMedium, mediumHeight)] {
            let pages = QuotaPaging.pages(for: sections, family: family, height: height, typeSize: .large)
            XCTAssertGreaterThan(pages.count, 1, "\(family)")
            XCTAssertEqual(shownRows(pages, sections).sorted(), allRows(sections).sorted(), "every row exactly once: \(family)")
            XCTAssertEqual(shownRows(pages, sections).filter { $0.hasPrefix("claude") }, allRows([sections[0]]),
                           "Claude rows keep their order: \(family)")
            XCTAssertEqual(extrasShown(pages, section: 1), 1, "Codex extras appear once: \(family)")
        }
    }

    func testLargerTextSizesAddPagesButStillShowEveryRow() {
        let sections = sections()
        for (family, height) in [(WidgetFamily.systemLarge, largeHeight), (.systemMedium, mediumHeight)] {
            let regular = QuotaPaging.pages(for: sections, family: family, height: height, typeSize: .large)
            let huge = QuotaPaging.pages(for: sections, family: family, height: height, typeSize: .accessibility3)
            XCTAssertGreaterThan(huge.count, regular.count, "\(family)")
            XCTAssertEqual(shownRows(huge, sections).sorted(), allRows(sections).sorted(), "\(family)")
            XCTAssertEqual(extrasShown(huge, section: 1), 1, "\(family)")
        }
    }

    // Even a page too short for one row still makes progress instead of looping or dropping rows.
    func testTinyHeightStillShowsEveryRowOnePerPage() {
        let sections = sections()
        let pages = QuotaPaging.pages(for: sections, family: .systemLarge, height: 10, typeSize: .accessibility5)
        XCTAssertEqual(shownRows(pages, sections).sorted(), allRows(sections).sorted())
        XCTAssertLessThanOrEqual(pages.count, 12)
    }

    func testProviderWithoutRowsStillGetsASlotForItsMessage() {
        let sections = sections(WidgetFixtures.snapshot(providers: [WidgetFixtures.claude()]))
        let pages = QuotaPaging.pages(for: sections, family: .systemLarge, height: largeHeight, typeSize: .large)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].map(\.section), [0, 1])
        XCTAssertTrue(pages[0][1].showsMessage)
        XCTAssertFalse(pages[0][0].showsMessage)
    }

    func testRemovedCapsShrinkThePagesAndTheSavedPageClamps() {
        let caps = (1...8).map { WidgetFixtures.modelCap($0, used: 5) }
        let crowded = sections(WidgetFixtures.snapshot(providers: [WidgetFixtures.claude(extraCaps: caps), WidgetFixtures.codex()]))
        let crowdedPages = QuotaPaging.pages(for: crowded, family: .systemLarge, height: largeHeight, typeSize: .large)
        let savedPage = crowdedPages.count - 1
        XCTAssertGreaterThan(savedPage, 0)

        let trimmed = QuotaPaging.pages(for: sections(), family: .systemLarge, height: largeHeight, typeSize: .large)
        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(QuotaPaging.clamp(savedPage, pageCount: trimmed.count), 0)
    }

    func testInvalidPagesClampAndStepsStayInRange() {
        XCTAssertEqual(QuotaPaging.clamp(-4, pageCount: 3), 0)
        XCTAssertEqual(QuotaPaging.clamp(9, pageCount: 3), 2)
        XCTAssertEqual(QuotaPaging.clamp(1, pageCount: 3), 1)
        XCTAssertEqual(QuotaPaging.clamp(5, pageCount: 0), 0)
        XCTAssertEqual(QuotaPaging.step(from: 0, forward: true, pageCount: 3), 1)
        XCTAssertEqual(QuotaPaging.step(from: 2, forward: true, pageCount: 3), 2)
        XCTAssertEqual(QuotaPaging.step(from: 0, forward: false, pageCount: 3), 0)
        // A saved page past the end counts as the last page before stepping.
        XCTAssertEqual(QuotaPaging.step(from: 9, forward: false, pageCount: 3), 1)
        XCTAssertEqual(QuotaPaging.step(from: -3, forward: true, pageCount: 3), 1)
    }

    // MARK: Scenario 6: paging is local; rows open their own provider

    func testTurningThePageChangesOnlyThePage() throws {
        let cache = PhoneSnapshotCache(directory: directory)
        cache.bind(account: .available(accountHash: "hash-A"))
        XCTAssertEqual(cache.commit(WidgetFixtures.result(WidgetFixtures.snapshot()), ticket: cache.beginFetch()), .stored)
        let before = cache.read()

        XCTAssertEqual(QuotaPaging.turn(forward: true, pageCount: 3, cache: cache), 1)
        XCTAssertEqual(QuotaPaging.turn(forward: true, pageCount: 3, cache: cache), 2)
        XCTAssertEqual(QuotaPaging.turn(forward: true, pageCount: 3, cache: cache), 2)
        XCTAssertEqual(QuotaPaging.turn(forward: false, pageCount: 3, cache: cache), 1)

        let after = cache.read()
        XCTAssertEqual(after.page, 1)
        XCTAssertEqual(after.stored, before.stored)
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.accountHash, before.accountHash)

        // Data shrank since the last render: the saved page clamps first.
        cache.updatePage { _ in 9 }
        XCTAssertEqual(QuotaPaging.turn(forward: false, pageCount: 2, cache: cache), 0)
    }

    func testPageTurnIsRememberedOnlyBriefly() throws {
        let suite = "WidgetPageTurns-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let turns = WidgetPageTurns(defaults: defaults)
        let now = WidgetFixtures.claudeObservedAt
        XCTAssertFalse(turns.happenedRecently(now: now))
        turns.record(at: now)
        XCTAssertTrue(turns.happenedRecently(now: now.addingTimeInterval(5)))
        XCTAssertFalse(turns.happenedRecently(now: now.addingTimeInterval(120)))
        XCTAssertFalse(turns.happenedRecently(now: now.addingTimeInterval(-120)))
    }

    func testRowsLinkToTheirProviderAndTheBackgroundLinkIsSeparate() {
        let sections = sections()
        XCTAssertTrue(sections[0].rows.allSatisfy { $0.link.absoluteString == "ccusage://provider/claude" })
        XCTAssertTrue(sections[1].rows.allSatisfy { $0.link.absoluteString == "ccusage://provider/codex" })
        XCTAssertEqual(sections[0].link.absoluteString, "ccusage://provider/claude")
        XCTAssertEqual(sections[1].link.absoluteString, "ccusage://provider/codex")
        XCTAssertFalse(sections.map(\.link).contains(QuotaWidgetModel.backgroundLink))
    }

    func testPageIntentCarriesItsDirectionAndPageCount() {
        let intent = QuotaPageIntent(forward: false, pageCount: 4)
        XCTAssertFalse(intent.forward)
        XCTAssertEqual(intent.pageCount, 4)
    }
}
