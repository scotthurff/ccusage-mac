import Foundation
import XCTest

// MARK: - Fixtures (shaped like Codex CLI 0.154.0 output; identifiers are fake)

private enum CodexFixtures {
    static let observedAt = Date(timeIntervalSince1970: 1_792_003_341)
    static let weeklyReset = 1_792_473_300

    static let liveRateLimits = #"""
    {"accountId": "acct-fixture-1", "ordinaryUsageAllowed": true, "rateLimitUpsell": null,
     "rateLimits": {"limitId": "codex", "limitName": null, "planType": "pro",
       "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1792473300},
       "secondary": null,
       "credits": {"hasCredits": true, "unlimited": false, "balance": "62493.3825750000"}},
     "rateLimitsByLimitId": {"codex": {"limitId": "codex", "limitName": null, "planType": "pro",
       "normalModelSlug": null, "rateLimitReachedType": null, "spendControlReached": null, "individualLimit": null,
       "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1792473300},
       "secondary": null,
       "credits": {"hasCredits": true, "unlimited": false, "balance": "62493.3825750000"}}},
     "rateLimitResetCredits": {"availableCount": 3, "credits": [
       {"id": "r1", "resetType": "codexRateLimits", "status": "available", "title": "Full reset",
        "grantedAt": 1790000000, "expiresAt": 1793000000, "description": null},
       {"id": "r2", "resetType": "codexRateLimits", "status": "available", "title": "Full reset",
        "grantedAt": 1790000000, "expiresAt": 1792700000, "description": null},
       {"id": "r3", "resetType": "codexRateLimits", "status": "available", "title": "Full reset",
        "grantedAt": 1790000000, "expiresAt": null, "description": null},
       {"id": "r4", "resetType": "codexRateLimits", "status": "redeemed", "title": "Full reset",
        "grantedAt": 1790000000, "expiresAt": 1792100000, "description": null},
       {"id": "r5", "resetType": "codexRateLimits", "status": "available", "title": "Full reset",
        "grantedAt": 1790000000, "expiresAt": 1791000000, "description": null}]}}
    """#

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func parse(_ json: String) -> CodexLimitsReading? {
        CodexLimitsClient.parseRateLimits(object(json), observedAt: observedAt)
    }

    static let signedInAccount = #"{"account": {"type": "chatgpt", "email": "someone@example.com", "planType": "pro"}, "requiresOpenaiAuth": true}"#
}

// MARK: - Fake app-server

// Replays scripted output for each request and records everything written.
private final class FakeCodexTransport: CodexTransport, @unchecked Sendable {
    typealias Script = (_ method: String, _ id: Int?) -> [String]

    private let lock = NSLock()
    private let script: Script
    private let startError: Error?
    private var continuation: AsyncStream<Data>.Continuation?
    private var _written: [[String: Any]] = []
    private var _rawWritten = Data()
    private var _shutdowns = 0

    init(startError: Error? = nil, script: @escaping Script) {
        self.startError = startError
        self.script = script
    }

    var methods: [String] { lock.withLock { _written.compactMap { $0["method"] as? String } } }
    var written: [[String: Any]] { lock.withLock { _written } }
    var rawWritten: String { lock.withLock { String(decoding: _rawWritten, as: UTF8.self) } }
    var shutdowns: Int { lock.withLock { _shutdowns } }

    func start() throws -> AsyncStream<Data> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        lock.withLock { self.continuation = continuation }
        // The real server announces this right away.
        continuation.yield(Data(#"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#.utf8 + [0x0A]))
        return stream
    }

    func write(_ data: Data) {
        var lines: [[String: Any]] = []
        for line in data.split(separator: 0x0A) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                lines.append(object)
            }
        }
        let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
            _written += lines
            _rawWritten += data
            return self.continuation
        }
        for message in lines {
            guard let method = message["method"] as? String else { continue }
            for chunk in script(method, message["id"] as? Int) {
                if chunk == "<exit>" {
                    continuation?.finish()
                } else {
                    continuation?.yield(Data(chunk.utf8))
                }
            }
        }
    }

    func shutdown() {
        let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
            _shutdowns += 1
            return self.continuation
        }
        continuation?.finish()
    }
}

private func response(_ id: Int?, _ result: String) -> String {
    #"{"id":\#(id ?? -1),"result":\#(result)}"# + "\n"
}

// A well-behaved server: answers every read, with noise in between.
private func happyScript(rateLimits: String = CodexFixtures.liveRateLimits,
                         account: String = CodexFixtures.signedInAccount) -> FakeCodexTransport.Script {
    { method, id in
        switch method {
        case "initialize":
            return [response(id, #"{"userAgent":"codex/0.154.0","codexHome":"/tmp/x","platformFamily":"unix","platformOs":"macos"}"#)]
        case "account/read":
            return [#"{"method":"account/updated","params":{}}"# + "\n", response(id, account)]
        case "account/rateLimits/read":
            // An unrelated response, a garbage line, then the answer split
            // across three chunks with a notification in the same chunk.
            let answer = response(id, rateLimits.replacingOccurrences(of: "\n", with: " "))
            let third = answer.count / 3
            let a = String(answer.prefix(third))
            let b = String(answer.dropFirst(third).prefix(third))
            let c = String(answer.dropFirst(2 * third))
            return [response(99, #"{"unrelated":true}"#), "not json at all\n",
                    #"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"# + "\n" + a, b, c]
        default:
            return []
        }
    }
}

private func client(_ transport: FakeCodexTransport?, timeout: Duration = .seconds(15)) -> CodexLimitsClient {
    CodexLimitsClient(timeout: timeout, now: { CodexFixtures.observedAt }, makeTransport: { transport })
}

// MARK: - Response decoding

final class CodexRateLimitDecodingTests: XCTestCase {
    func testLiveShapeWeeklyWindowInPrimaryIsClassifiedByDuration() throws {
        let reading = try XCTUnwrap(CodexFixtures.parse(CodexFixtures.liveRateLimits))
        let observation = reading.observation
        XCTAssertEqual(observation.source, "codex-app-server")
        XCTAssertEqual(observation.observedAt, CodexFixtures.observedAt)
        XCTAssertEqual(observation.windows, [
            QuotaWindow(id: "codex:codex:10080", label: "Weekly", durationMinutes: 10_080, usedPercent: 13,
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(CodexFixtures.weeklyReset)), scope: .provider)
        ])
        XCTAssertEqual(observation.creditBalance ?? 0, 62_493.382575, accuracy: 0.000001)
        // Only available, unexpired credits count toward the next expiry.
        XCTAssertEqual(observation.resetCredits,
                       ResetCreditsInfo(available: 3, nextExpiry: Date(timeIntervalSince1970: 1_792_700_000)))
    }

    func testAccountIdBecomesALocalHashOnly() throws {
        let reading = try XCTUnwrap(CodexFixtures.parse(CodexFixtures.liveRateLimits))
        let key = try XCTUnwrap(reading.accountKey)
        XCTAssertFalse(key.contains("acct-fixture-1"))
        XCTAssertEqual(key, QuotaAccountKey.make(.codex, ["acct-fixture-1"]))

        let other = CodexFixtures.liveRateLimits.replacingOccurrences(of: "acct-fixture-1", with: "acct-fixture-2")
        XCTAssertNotEqual(CodexFixtures.parse(other)?.accountKey, key)

        let missing = CodexFixtures.liveRateLimits.replacingOccurrences(of: #""acct-fixture-1""#, with: "null")
        XCTAssertNil(try XCTUnwrap(CodexFixtures.parse(missing)).accountKey)
    }

    func testMultipleBucketsStaySeparateWithoutInventedModelAllowances() throws {
        let json = #"""
        {"accountId": "a", "rateLimits": {"limitId": "codex",
           "primary": {"usedPercent": 99, "windowDurationMins": 300, "resetsAt": null}},
         "rateLimitsByLimitId": {
           "codex_spark": {"limitId": "codex_spark", "limitName": "GPT-5.3-Codex-Spark",
             "primary": {"usedPercent": 4, "windowDurationMins": 300, "resetsAt": 1792010000},
             "secondary": {"usedPercent": 21.5, "windowDurationMins": 10080, "resetsAt": 1792473300}},
           "codex": {"limitId": "codex", "limitName": null,
             "primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1792010000},
             "secondary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1792473300}},
           "codex_mini": {"limitId": "codex_mini", "limitName": null,
             "primary": {"usedPercent": 2, "windowDurationMins": 10080, "resetsAt": null}, "secondary": null}}}
        """#
        let windows = try XCTUnwrap(CodexFixtures.parse(json)).observation.windows
        XCTAssertEqual(windows.map(\.id), [
            "codex:codex:300", "codex:codex:10080",
            "codex:codex_mini:10080",
            "codex:codex_spark:300", "codex:codex_spark:10080",
        ])
        XCTAssertEqual(Set(windows.map(\.id)).count, windows.count, "no duplicate windows")
        // The account-wide bucket is the only provider-scope allowance.
        XCTAssertEqual(windows.filter { $0.scope == .provider }.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(windows.filter { $0.scope == .model }.map(\.label),
                       ["codex_mini", "GPT-5.3-Codex-Spark 5-hour", "GPT-5.3-Codex-Spark weekly"])
        XCTAssertFalse(windows.contains { $0.usedPercent == 99 }, "the legacy singleton is ignored when the map exists")
    }

    func testLegacySingletonIsUsedOnlyWhenTheMapIsAbsent() throws {
        let json = #"""
        {"accountId": "a", "rateLimitsByLimitId": null, "rateLimits": {"limitId": null,
           "primary": {"usedPercent": 7, "windowDurationMins": 300, "resetsAt": 1792010000},
           "secondary": {"usedPercent": 30, "windowDurationMins": 10080, "resetsAt": 1792473300}}}
        """#
        let windows = try XCTUnwrap(CodexFixtures.parse(json)).observation.windows
        XCTAssertEqual(windows.map(\.id), ["codex:codex:300", "codex:codex:10080"])
        XCTAssertEqual(windows.map(\.scope), [.provider, .provider])

        let emptyMap = json.replacingOccurrences(of: #""rateLimitsByLimitId": null"#, with: #""rateLimitsByLimitId": {}"#)
        XCTAssertNil(CodexFixtures.parse(emptyMap), "an empty map means no quotas, not the legacy view")
    }

    func testMissingAndInvalidWindowsAreSkippedNotZeroed() throws {
        let json = #"""
        {"rateLimitsByLimitId": {"codex": {"limitId": "codex",
           "primary": null,
           "secondary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1792473300}},
          "codex_bad": {"limitId": "codex_bad",
           "primary": {"windowDurationMins": 300}, "secondary": {"usedPercent": -4, "windowDurationMins": 10080}},
          "codex_huge": {"limitId": "codex_huge", "primary": {"usedPercent": 5000, "windowDurationMins": 300}}}}
        """#
        let windows = try XCTUnwrap(CodexFixtures.parse(json)).observation.windows
        XCTAssertEqual(windows.map(\.id), ["codex:codex:10080"])
    }

    func testNoUsableWindowIsNoReading() {
        XCTAssertNil(CodexFixtures.parse(#"{"rateLimitsByLimitId": {"codex": {"primary": null, "secondary": null}}}"#))
        XCTAssertNil(CodexFixtures.parse(#"{"rateLimits": null, "rateLimitsByLimitId": null}"#))
        XCTAssertNil(CodexFixtures.parse(#"{}"#))
    }

    func testNonstandardDurationsKeepTheirReportedLength() throws {
        let json = #"""
        {"rateLimitsByLimitId": {"codex": {"limitId": "codex",
           "primary": {"usedPercent": 1, "windowDurationMins": 1440, "resetsAt": 1792010000},
           "secondary": {"usedPercent": 2, "windowDurationMins": 299, "resetsAt": 1792010000}},
          "codex_odd": {"limitId": "codex_odd", "limitName": "Odd",
           "primary": {"usedPercent": 3, "windowDurationMins": 90},
           "secondary": {"usedPercent": 4, "windowDurationMins": null}}}}
        """#
        let windows = try XCTUnwrap(CodexFixtures.parse(json)).observation.windows
        XCTAssertEqual(windows.map(\.id), ["codex:codex:1440", "codex:codex:299", "codex:codex_odd:90", "codex:codex_odd:secondary"])
        XCTAssertEqual(windows.map(\.label), ["1-day", "5-hour", "Odd 90-minute", "Odd limit"])
        XCTAssertEqual(windows.map(\.durationMinutes), [1440, 299, 90, nil])
    }

    func testRepeatedDurationInOneBucketIsNotDuplicated() throws {
        let json = #"""
        {"rateLimitsByLimitId": {"codex": {"limitId": "codex",
           "primary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1792473300},
           "secondary": {"usedPercent": 11, "windowDurationMins": 10080, "resetsAt": 1792473300}}}}
        """#
        let windows = try XCTUnwrap(CodexFixtures.parse(json)).observation.windows
        XCTAssertEqual(windows.map(\.id), ["codex:codex:10080"])
        XCTAssertEqual(windows.first?.usedPercent, 10)
    }

    func testResetCreditsWithoutDetailsKeepTheCount() throws {
        let json = #"""
        {"rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 1, "windowDurationMins": 10080}}},
         "rateLimitResetCredits": {"availableCount": 2, "credits": null}}
        """#
        let observation = try XCTUnwrap(CodexFixtures.parse(json)).observation
        XCTAssertEqual(observation.resetCredits, ResetCreditsInfo(available: 2, nextExpiry: nil))
        XCTAssertNil(observation.creditBalance)

        let none = json.replacingOccurrences(of: #""rateLimitResetCredits": {"availableCount": 2, "credits": null}"#,
                                             with: #""rateLimitResetCredits": null"#)
        XCTAssertNil(try XCTUnwrap(CodexFixtures.parse(none)).observation.resetCredits)
    }

    func testLineBufferJoinsFragmentsAndSplitsBatches() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"a":"#.utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\r\n\n{\"b\":2}\n{\"c\"".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"c":3}"#])
    }
}

// MARK: - Subprocess conversation

final class CodexLimitsClientTests: XCTestCase {
    func testHappyPathReadsLimitsWithOnlyReadOnlyRequests() async throws {
        let transport = FakeCodexTransport(script: happyScript())
        let reading = try await client(transport).read().get()

        XCTAssertEqual(reading.observation.windows.map(\.id), ["codex:codex:10080"])
        XCTAssertEqual(reading.observation.observedAt, CodexFixtures.observedAt)
        XCTAssertEqual(reading.accountKey, QuotaAccountKey.make(.codex, ["acct-fixture-1"]))
        XCTAssertEqual(transport.methods, ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        XCTAssertEqual(transport.shutdowns, 1)

        let sent = transport.written
        XCTAssertEqual((sent[0]["params"] as? [String: Any]).flatMap { $0["clientInfo"] as? [String: String] },
                       ["name": "ccusagebar", "version": "1.0"])
        XCTAssertNil(sent[1]["id"], "initialized is a notification")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["refreshToken"] as? Bool, false)
        XCTAssertEqual((sent[3]["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool, false)
        XCTAssertFalse(transport.rawWritten.contains("supportsLunaReserve"))
        XCTAssertFalse(transport.rawWritten.contains("turn/"))
        XCTAssertFalse(transport.rawWritten.contains("thread/"))
        XCTAssertFalse(transport.rawWritten.contains("consume"))
    }

    func testCollectMapsSuccessToAnObservation() async {
        let result = await client(FakeCodexTransport(script: happyScript())).collect()
        XCTAssertEqual(result.observation?.windows.count, 1)
        XCTAssertEqual(result.accountKey, QuotaAccountKey.make(.codex, ["acct-fixture-1"]))
    }

    func testProtocolErrorFailsAndCleansUpOnce() async {
        let transport = FakeCodexTransport { method, id in
            if method == "account/rateLimits/read" {
                return [#"{"id":\#(id ?? -1),"error":{"code":-32603,"message":"backend unavailable"}}"# + "\n"]
            }
            return happyScript()(method, id)
        }
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .requestFailed("account/rateLimits/read"))
        XCTAssertEqual(transport.shutdowns, 1)
        let failed = await client(FakeCodexTransport(script: { method, id in
            method == "account/rateLimits/read" ? [response(id, "null")] : happyScript()(method, id)
        })).collect()
        XCTAssertNil(failed.observation)
    }

    func testSignedOutStopsBeforeAskingForLimits() async {
        let transport = FakeCodexTransport(script: happyScript(account: #"{"account": null, "requiresOpenaiAuth": true}"#))
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .notSignedIn)
        XCTAssertFalse(transport.methods.contains("account/rateLimits/read"))
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testApiKeyLoginIsUnsupported() async {
        let transport = FakeCodexTransport(script: happyScript(account: #"{"account": {"type": "apiKey"}, "requiresOpenaiAuth": true}"#))
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .unsupportedLogin)
        XCTAssertFalse(transport.methods.contains("account/rateLimits/read"))
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testMissingQuotasFail() async {
        let transport = FakeCodexTransport(script: happyScript(rateLimits: #"{"rateLimitsByLimitId": {}, "rateLimits": null}"#))
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .noQuotas)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testProcessExitBeforeTheAnswerFails() async {
        let transport = FakeCodexTransport { method, id in
            method == "account/read" ? ["{\"id\":2,\"res", "<exit>"] : happyScript()(method, id)
        }
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .processExited)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testTimeoutStopsASilentServer() async {
        let transport = FakeCodexTransport { _, _ in [] }
        let started = Date()
        let result = await client(transport, timeout: .milliseconds(300)).read()
        XCTAssertEqual(result.failure, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(transport.shutdowns, 1)
        XCTAssertEqual(transport.methods, ["initialize"])
    }

    func testCancellationStopsTheRead() async {
        let transport = FakeCodexTransport { _, _ in [] }
        let codex = client(transport)
        let task = Task { await codex.read() }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testLaunchFailureCleansUpOnce() async {
        struct LaunchError: Error {}
        let transport = FakeCodexTransport(startError: LaunchError()) { _, _ in [] }
        let result = await client(transport).read()
        XCTAssertEqual(result.failure, .launchFailed)
        XCTAssertEqual(transport.shutdowns, 1)
        XCTAssertEqual(transport.methods, [])
    }

    func testMissingBinaryFails() async {
        let result = await client(nil).read()
        XCTAssertEqual(result.failure, .binaryNotFound)
    }
}

// MARK: - Real pipes (harmless system commands, never the Codex CLI)

final class CodexProcessTransportTests: XCTestCase {
    private func collect(_ stream: AsyncStream<Data>) async -> [String] {
        var buffer = LineBuffer()
        var lines: [String] = []
        for await chunk in stream {
            lines += buffer.append(chunk).map { String(decoding: $0, as: UTF8.self) }
        }
        return lines
    }

    func testLinesRoundTripAndClosingInputEndsTheProcess() async throws {
        let transport = CodexProcessTransport(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let stream = try transport.start()
        transport.write(Data(#"{"id":1,"result":{}}"#.utf8 + [0x0A]))
        transport.write(Data(#"{"method":"note"}"#.utf8 + [0x0A]))
        let reader = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(200))
        transport.shutdown()
        transport.shutdown()  // a second call is harmless
        let lines = await reader.value
        XCTAssertEqual(lines, [#"{"id":1,"result":{}}"#, #"{"method":"note"}"#])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(transport.isRunning)
    }

    func testProcessExitEndsTheStreamAndLateWritesDoNotCrash() async throws {
        let transport = CodexProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"])
        let stream = try transport.start()
        let lines = await collect(stream)
        XCTAssertEqual(lines, [])
        // Writing into a pipe nobody reads must fail quietly, not raise SIGPIPE.
        transport.write(Data("{}\n".utf8))
        transport.shutdown()
    }

    func testAServerThatIgnoresClosedInputIsStopped() async throws {
        let transport = CodexProcessTransport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        _ = try transport.start()
        XCTAssertTrue(transport.isRunning)
        transport.shutdown()
        try await Task.sleep(for: .milliseconds(3_000))
        XCTAssertFalse(transport.isRunning)
    }

    func testMissingExecutableFailsToLaunch() {
        let transport = CodexProcessTransport(executable: URL(fileURLWithPath: "/nonexistent/codex"))
        XCTAssertThrowsError(try transport.start())
        transport.shutdown()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
