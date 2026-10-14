import Foundation
import XCTest

// The null, absent, malformed, and scoped-cap cases were first pinned
// against the old ProviderLimits parser, then carried over unchanged.
final class ClaudeLimitsFetcherTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_792_003_341)

    private func parse(_ json: String) -> QuotaObservation? {
        ClaudeLimitsFetcher.parseUsage(Data(json.utf8), observedAt: observedAt)
    }

    private func window(_ observation: QuotaObservation?, _ id: String) -> QuotaWindow? {
        observation?.windows.first { $0.id == id }
    }

    func testExplicitNullWindowIsConfirmedZeroWithoutReset() throws {
        let observation = try XCTUnwrap(parse(#"{"five_hour": null, "seven_day": {"utilization": 17.0, "resets_at": "2026-10-19T07:00:00.528743+00:00"}}"#))
        XCTAssertEqual(observation.source, "claude-oauth-usage")
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(window(observation, "claude:5h"),
                       QuotaWindow(id: "claude:5h", label: "5-hour", durationMinutes: 300, usedPercent: 0, resetsAt: nil, scope: .provider))
        XCTAssertEqual(window(observation, "claude:7d"),
                       QuotaWindow(id: "claude:7d", label: "Weekly", durationMinutes: 10_080, usedPercent: 17,
                                   resetsAt: Date(timeIntervalSince1970: 1_792_393_200), scope: .provider))

        // A current explicit zero is a confirmed zero on every screen.
        let slot = ProviderSlot(provider: .claude, generation: "g", acceptedAttempt: 1, observation: observation, lastAttempt: nil)
        let fiveHour = QuotaPresentation(now: observedAt).provider(slot).windows.first { $0.window.id == "claude:5h" }
        XCTAssertEqual(fiveHour?.isConfirmedZero, true)
    }

    func testAbsentWindowIsUnknown() throws {
        let observation = try XCTUnwrap(parse(#"{"seven_day": {"utilization": 5}}"#))
        XCTAssertNil(window(observation, "claude:5h"))
        XCTAssertEqual(window(observation, "claude:7d")?.usedPercent, 5)
    }

    func testMalformedWindowIsUnknown() throws {
        let observation = try XCTUnwrap(parse(#"{"five_hour": {"utilization": 2}, "seven_day": {"resets_at": "2026-10-19T07:00:00+00:00"}}"#))
        XCTAssertEqual(window(observation, "claude:5h")?.usedPercent, 2)
        XCTAssertNil(window(observation, "claude:7d"), "a window without utilization is unknown, not zero")

        let stringWindow = try XCTUnwrap(parse(#"{"five_hour": "busy", "seven_day": {"utilization": 4}}"#))
        XCTAssertNil(window(stringWindow, "claude:5h"))
        XCTAssertEqual(window(stringWindow, "claude:7d")?.usedPercent, 4)

        let outOfRange = try XCTUnwrap(parse(#"{"five_hour": {"utilization": -3}, "seven_day": {"utilization": 4, "resets_at": "garbage"}}"#))
        XCTAssertNil(window(outOfRange, "claude:5h"))
        XCTAssertEqual(window(outOfRange, "claude:7d")?.usedPercent, 4)
        XCTAssertNil(window(outOfRange, "claude:7d")?.resetsAt)
    }

    func testNoRecognizableWindowIsAFailedRead() {
        XCTAssertNil(parse(#"{"five_hour": "busy"}"#))
        XCTAssertNil(parse(#"{}"#))
        XCTAssertNil(parse(#"[1, 2]"#))
        XCTAssertNil(parse("not json"))
    }

    func testScopedWeeklyCapsComeFromLimitsArray() throws {
        let observation = try XCTUnwrap(parse(#"""
        {"five_hour": {"utilization": 2}, "seven_day": {"utilization": 17},
         "limits": [
           {"kind": "weekly_scoped", "percent": 41.5, "resets_at": "2026-10-19T07:00:00.528743+00:00",
            "scope": {"model": {"display_name": "Fable"}}},
           {"kind": "weekly", "percent": 9, "scope": {"model": {"display_name": "Ignored"}}},
           {"kind": "weekly_scoped", "percent": 3, "scope": {"model": {"display_name": ""}}},
           {"kind": "weekly_scoped", "scope": {"model": {"display_name": "NoPercent"}}},
           {"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"display_name": "Fable"}}}
         ]}
        """#))
        let scoped = observation.windows.filter { $0.scope == .model }
        XCTAssertEqual(scoped, [
            QuotaWindow(id: "claude:model:fable", label: "Fable", durationMinutes: 10_080, usedPercent: 41.5,
                        resetsAt: Date(timeIntervalSince1970: 1_792_393_200), scope: .model)
        ])
    }

    func testMissingOrEmptyLimitsArrayHasNoScopedCaps() throws {
        XCTAssertEqual(try XCTUnwrap(parse(#"{"seven_day": {"utilization": 1}}"#)).windows.filter { $0.scope == .model }, [])
        XCTAssertEqual(try XCTUnwrap(parse(#"{"seven_day": {"utilization": 1}, "limits": []}"#)).windows.filter { $0.scope == .model }, [])
    }

    func testExpiredTokenIsSkipped() {
        let expired = #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}"#
        XCTAssertNil(ClaudeLimitsFetcher.extractAccessToken(from: expired))
        let valid = #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 4102444800000}}"#
        XCTAssertEqual(ClaudeLimitsFetcher.extractAccessToken(from: valid), "t")
    }

    // A Keychain prompt nobody answers must not hold up the refresh.
    func testHungKeychainLookupGivesUpAtTheTimeout() async {
        let started = ContinuousClock.now
        let raw = await ClaudeLimitsFetcher.readKeychainItem(timeout: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(30))
            return "late"
        }
        XCTAssertNil(raw, "a hung lookup falls through to the credentials file")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        let quick = await ClaudeLimitsFetcher.readKeychainItem(timeout: .seconds(5)) { "blob" }
        XCTAssertEqual(quick, "blob")
    }

    // MARK: - Account identity (local only)

    private func config(account: String?, org: String?, extra: String = "") -> Data {
        var fields: [String] = []
        if let account { fields.append(#""accountUuid": "\#(account)""#) }
        if let org { fields.append(#""organizationUuid": "\#(org)""#) }
        return Data(#"{"numStartups": 4\#(extra), "oauthAccount": {\#(fields.joined(separator: ", ")), "displayName": "x"}}"#.utf8)
    }

    func testAccountKeyComesFromAccountAndOrganizationOnly() throws {
        let key = try XCTUnwrap(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: "acct-1", org: "org-1")))
        XCTAssertFalse(key.contains("acct-1"))
        XCTAssertEqual(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: "acct-1", org: "org-1", extra: #", "tipsHistory": {}"#)), key,
                       "unrelated config changes, like a refreshed login, keep the same account")
        XCTAssertNotEqual(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: "acct-2", org: "org-1")), key)
        XCTAssertNotEqual(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: "acct-1", org: "org-2")), key)
        XCTAssertNotNil(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: "acct-1", org: nil)))
    }

    func testMissingIdentityGivesNoKey() {
        XCTAssertNil(ClaudeLimitsFetcher.accountKey(fromConfig: config(account: nil, org: "org-1")))
        XCTAssertNil(ClaudeLimitsFetcher.accountKey(fromConfig: Data(#"{"numStartups": 1}"#.utf8)))
        XCTAssertNil(ClaudeLimitsFetcher.accountKey(fromConfig: Data("not json".utf8)))
    }
}
