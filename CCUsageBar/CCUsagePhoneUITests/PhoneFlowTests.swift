import XCTest

// Drives the iPhone app against made-up readings, never iCloud. Each test
// launches the app with `-uiTestFixture <name>`. Debug builds of the app then
// swap iCloud for fixed fake data; see UITestFixture in CCUsagePhoneApp.swift.
// Release builds ignore the argument.
//
// Covers the setup guidance, the full details for both providers, a failed
// refresh that keeps the saved readings, and a widget link that scrolls to
// the Codex card.
final class PhoneFlowTests: XCTestCase {

    // iCloud is on but the Mac hasn't published yet: guidance and nothing else.
    @MainActor
    func testPendingSetupShowsWaitingGuidanceAndNoReadings() {
        let app = launch(fixture: "waitingForFirstReading")
        let notice = element("notice", in: app)
        waitFor(notice, labelContains: "Waiting for the first reading from your Mac")
        XCTAssertTrue(notice.label.contains("Open CCUsageBar on your Mac and refresh it."), notice.label)
        assertNoReadings(in: app)
        attachScreenshot(of: app, named: "pending-setup")
    }

    @MainActor
    func testICloudOffShowsSignInGuidanceAndNoReadings() {
        let app = launch(fixture: "iCloudOff")
        let notice = element("notice", in: app)
        waitFor(notice, labelContains: "iCloud is off on this iPhone")
        XCTAssertTrue(notice.label.contains("Sign in to iCloud in Settings"), notice.label)
        assertNoReadings(in: app)
        attachScreenshot(of: app, named: "icloud-off")
    }

    // The cache starts empty; the fake iCloud returns a snapshot.
    @MainActor
    func testPopulatedDetailsShowBothProvidersInFull() {
        let app = launch(fixture: "populated")

        let claude = element("provider-header-claude", in: app)
        waitFor(claude, labelContains: "Read on your Mac")
        assertLabel(of: claude, contains: ["Claude", "Current"])
        assertLabel(of: claude, matches: ".*Read on your Mac [0-9]+ minutes ago.*")

        let claudeRows = rows("claude", in: app)
        XCTAssertEqual(claudeRows.count, 3)
        assertLabel(of: claudeRows.element(boundBy: 0), hasPrefix: "Claude 5-hour, 23 percent used, resets ")
        assertLabel(of: claudeRows.element(boundBy: 1), hasPrefix: "Claude weekly, 41 percent used, resets ")
        assertLabel(of: claudeRows.element(boundBy: 2), hasPrefix: "Claude Fable model limit, 9 percent used, resets ")

        let codex = element("provider-header-codex", in: app)
        assertLabel(of: codex, contains: ["Codex", "Current"])
        assertLabel(of: codex, matches: ".*Read on your Mac [0-9]+ minutes ago.*")

        let codexRows = rows("codex", in: app)
        XCTAssertEqual(codexRows.count, 1)
        assertLabel(of: codexRows.element(boundBy: 0), hasPrefix: "Codex weekly, 13 percent used, resets ")
        assertLabel(of: element("reset-credits-codex", in: app), hasPrefix: "2 full resets · next expires ")
        XCTAssertEqual(element("credit-balance-codex", in: app).label, "1,234 credits")
        XCTAssertFalse(element("reset-credits-claude", in: app).exists)
        XCTAssertFalse(element("credit-balance-claude", in: app).exists)

        // A good fetch leaves no notice, only the time iCloud was checked.
        XCTAssertFalse(element("notice", in: app).exists)
        XCTAssertEqual(element("checked-icloud", in: app).label, "Checked iCloud just now")
        attachScreenshot(of: app, named: "populated")
    }

    // The cache starts with a two-hour-old snapshot. At launch the fake
    // iCloud returns that same snapshot; from three seconds after launch every
    // fetch fails. A refresh from the button then adds a failure notice and
    // keeps the saved readings with their age, instead of blanking them.
    @MainActor
    func testFailedRefreshKeepsSavedReadingsWithTheirAgeAndANotice() {
        let app = launch(fixture: "failedRefresh")
        let refresh = app.buttons["refresh"]
        let notice = element("notice", in: app)

        waitFor(element("checked-icloud", in: app), label: "Checked iCloud just now")
        XCTAssertFalse(notice.exists)
        assertRetainedReadings(in: app)
        attachScreenshot(of: app, named: "failed-refresh-before")

        pause(seconds: 3, reason: "the fake iCloud stops answering")
        waitFor(refresh, label: "Refresh")
        refresh.tap()

        waitFor(notice, labelContains: "Couldn't get a new reading from iCloud")
        assertLabel(of: notice, contains: ["Showing the readings saved on this iPhone."])
        waitFor(refresh, label: "Refresh")
        XCTAssertTrue(refresh.isEnabled)
        assertRetainedReadings(in: app)
        XCTAssertFalse(element("checked-icloud", in: app).exists)
        attachScreenshot(of: app, named: "failed-refresh-after")
    }

    // The control for the link test: with many Claude limits, the Codex card
    // starts below the bottom of the screen.
    @MainActor
    func testWithoutALinkTheCodexCardStartsBelowTheScreen() {
        let app = launch(fixture: "manyLimits")
        let firstClaudeRow = rows("claude", in: app).firstMatch
        XCTAssertTrue(firstClaudeRow.waitForExistence(timeout: 10))
        let codex = element("provider-header-codex", in: app)
        XCTAssertTrue(codex.exists)
        XCTAssertTrue(isOnScreen(firstClaudeRow, in: app))
        XCTAssertFalse(isOnScreen(codex, in: app), "Codex should start off screen; frame \(codex.frame)")
        attachScreenshot(of: app, named: "many-limits-top")
    }

    // ccusage://provider/codex, as a widget tap sends it, scrolls the Codex
    // card on screen and the top of the Claude card off it.
    @MainActor
    func testCodexLinkScrollsTheCodexCardOnScreen() {
        let app = launch(fixture: "manyLimits", link: "ccusage://provider/codex")
        let codex = element("provider-header-codex", in: app)
        XCTAssertTrue(codex.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.isOnScreen(codex, in: app) },
                      "Codex card never came on screen; frame \(codex.frame)")
        XCTAssertTrue(isOnScreen(rows("codex", in: app).firstMatch, in: app))
        XCTAssertFalse(isOnScreen(rows("claude", in: app).firstMatch, in: app))
        attachScreenshot(of: app, named: "codex-link")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(fixture: String, link: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // English and a US locale pin wording and number formatting.
        app.launchArguments = ["-uiTestFixture", fixture, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let link { app.launchArguments += ["-uiTestOpenURL", link] }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func rows(_ provider: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "window-row-\(provider)")
    }

    // Both providers as the failedRefresh fixture saved them two hours ago.
    @MainActor
    private func assertRetainedReadings(in app: XCUIApplication, line: UInt = #line) {
        let claude = element("provider-header-claude", in: app)
        assertLabel(of: claude, contains: ["Claude", "Outdated · over an hour old"], line: line)
        // "2 hours ago", or "2 hr 1 min ago" if a minute ticks over mid-test.
        assertLabel(of: claude, matches: ".*Read on your Mac 2 h.*", line: line)
        XCTAssertEqual(rows("claude", in: app).count, 3, line: line)
        assertLabel(of: rows("claude", in: app).element(boundBy: 0),
                    hasPrefix: "Claude 5-hour, 23 percent used, resets ", line: line)

        let codex = element("provider-header-codex", in: app)
        assertLabel(of: codex, contains: ["Codex", "Outdated · over an hour old"], line: line)
        assertLabel(of: codex, matches: ".*Read on your Mac 2 h.*", line: line)
        XCTAssertEqual(rows("codex", in: app).count, 1, line: line)
        XCTAssertEqual(element("credit-balance-codex", in: app).label, "1,234 credits", line: line)
    }

    @MainActor
    private func assertNoReadings(in app: XCUIApplication, line: UInt = #line) {
        XCTAssertFalse(element("provider-header-claude", in: app).exists, line: line)
        XCTAssertFalse(element("provider-header-codex", in: app).exists, line: line)
        let windowRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'window-row-'"))
        XCTAssertEqual(windowRows.count, 0, line: line)
        let percentages = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'percent used' OR label CONTAINS '% used'"))
        XCTAssertEqual(percentages.count, 0, line: line)
        XCTAssertFalse(element("checked-icloud", in: app).exists, line: line)
    }

    // On screen means hittable and wholly inside the app's window.
    @MainActor
    private func isOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return app.windows.firstMatch.frame.contains(element.frame)
    }

    private func pause(seconds: TimeInterval, reason: String) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: reason)], timeout: seconds)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, labelContains text: String,
                         timeout: TimeInterval = 10, line: UInt = #line) {
        wait(for: element, NSPredicate(format: "exists == true AND label CONTAINS %@", text),
             timeout: timeout, line: line)
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, label text: String,
                         timeout: TimeInterval = 10, line: UInt = #line) {
        wait(for: element, NSPredicate(format: "exists == true AND label == %@", text),
             timeout: timeout, line: line)
    }

    @MainActor
    private func wait(for element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval, line: UInt) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        let label = element.exists ? element.label : "(missing)"
        XCTAssertEqual(result, .completed, "Waited for \(predicate) on \(element); label is \(label)", line: line)
    }

    @MainActor
    private func assertLabel(of element: XCUIElement, contains parts: [String], line: UInt = #line) {
        XCTAssertTrue(element.exists, "\(element) is missing", line: line)
        for part in parts {
            XCTAssertTrue(element.label.contains(part), "\"\(element.label)\" lacks \"\(part)\"", line: line)
        }
    }

    @MainActor
    private func assertLabel(of element: XCUIElement, hasPrefix prefix: String, line: UInt = #line) {
        XCTAssertTrue(element.exists, "\(element) is missing", line: line)
        XCTAssertTrue(element.label.hasPrefix(prefix), "\"\(element.label)\" doesn't start with \"\(prefix)\"", line: line)
    }

    @MainActor
    private func assertLabel(of element: XCUIElement, matches pattern: String, line: UInt = #line) {
        XCTAssertTrue(element.exists, "\(element) is missing", line: line)
        XCTAssertNotNil(element.label.range(of: "(?s)^\(pattern)$", options: .regularExpression),
                        "\"\(element.label)\" doesn't match \(pattern)", line: line)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
