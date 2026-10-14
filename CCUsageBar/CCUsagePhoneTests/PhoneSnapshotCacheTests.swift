import XCTest

final class PhoneSnapshotCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func cache() -> PhoneSnapshotCache { PhoneSnapshotCache(directory: directory) }

    func testEmptyDirectoryReadsAsEmpty() {
        XCTAssertEqual(cache().read(), .empty)
    }

    func testStoredSnapshotSurvivesANewInstanceWithItsObservationDates() {
        let cache = cache()
        let outcome = cache.commit(PhoneFixtures.result(revision: 10), ticket: cache.beginFetch())
        XCTAssertEqual(outcome, .stored)

        // A second instance stands in for the other process.
        let stored = try? XCTUnwrap(PhoneSnapshotCache(directory: directory).read().stored)
        XCTAssertEqual(stored?.snapshot, PhoneFixtures.snapshot(revision: 10))
        XCTAssertEqual(stored?.metadata, PhoneFixtures.metadata(revision: 10))
        XCTAssertEqual(stored?.snapshot.providers.first?.observation?.observedAt, PhoneFixtures.observedAt)
    }

    // Scenario 4: two processes finish their fetches in reverse order.
    func testOlderResponseFinishingLastDoesNotReplaceNewer() {
        let app = cache(), widget = cache()
        let appTicket = app.beginFetch(), widgetTicket = widget.beginFetch()
        XCTAssertEqual(widget.commit(PhoneFixtures.result(revision: 11), ticket: widgetTicket), .stored)
        XCTAssertEqual(app.commit(PhoneFixtures.result(revision: 10), ticket: appTicket), .kept)
        XCTAssertEqual(app.read().stored?.metadata.revision, 11)
        XCTAssertEqual(app.commit(PhoneFixtures.result(revision: 11), ticket: appTicket), .kept)
    }

    func testRecreatedRecordReplacesCacheEvenWithLowerRevision() {
        let cache = cache()
        cache.commit(PhoneFixtures.result(revision: 90), ticket: cache.beginFetch())
        let recreated = PhoneFixtures.result(revision: 1, incarnation: "inc-B",
                                             createdAt: PhoneFixtures.incarnationCreatedAt.addingTimeInterval(60))
        XCTAssertEqual(cache.commit(recreated, ticket: cache.beginFetch()), .stored)
        XCTAssertEqual(cache.read().stored?.metadata.incarnation, "inc-B")
        // A delayed copy of the former record never wins it back.
        XCTAssertEqual(cache.commit(PhoneFixtures.result(revision: 91), ticket: cache.beginFetch()), .kept)
        XCTAssertEqual(cache.read().stored?.metadata.revision, 1)
    }

    // Scenario 6 and KTD10: nothing but a newer snapshot changes the file.
    func testFailuresMissingRecordAndFutureSchemaKeepThePriorCache() throws {
        let cache = cache()
        cache.commit(PhoneFixtures.result(revision: 10), ticket: cache.beginFetch())
        let before = try Data(contentsOf: cache.fileURL)
        let results: [CloudFetchResult] = [.missing, .malformed, .unsupported(version: 2), .timedOut, .unavailable("offline")]
        for result in results {
            XCTAssertEqual(cache.commit(result, ticket: cache.beginFetch()), .kept, "\(result)")
        }
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before)
        XCTAssertEqual(cache.read().stored?.metadata.revision, 10)
    }

    // Scenario 3: a corrupt file never crashes and is replaced by the next good write.
    func testCorruptFileReadsAsEmptyAndIsReplacedByTheNextSnapshot() throws {
        try Data("{\"generation\": 4, \"payl".utf8).write(to: cache().fileURL)
        let cache = cache()
        XCTAssertNil(cache.read().stored)
        XCTAssertEqual(cache.commit(PhoneFixtures.result(revision: 3), ticket: cache.beginFetch()), .stored)
        XCTAssertEqual(cache.read().stored?.metadata.revision, 3)
    }

    func testUnreadableSnapshotKeepsAccountBindingAndGeneration() throws {
        let cache = cache()
        cache.bind(account: .available(accountHash: "hash-A"))
        cache.bind(account: .available(accountHash: "hash-B"))
        cache.commit(PhoneFixtures.result(revision: 10), ticket: cache.beginFetch())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL)) as? [String: Any])
        object["payload"] = Data("garbage".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: cache.fileURL)

        let state = cache.read()
        XCTAssertNil(state.stored)
        XCTAssertEqual(state.accountHash, "hash-B")
        XCTAssertEqual(state.generation, 1)
    }

    // Scenario 4: paging touches only the page, even with a stale copy in hand.
    func testPagingChangesOnlyThePage() {
        let app = cache(), widget = cache()
        app.commit(PhoneFixtures.result(revision: 10), ticket: app.beginFetch())
        let staleCopy = widget.read()
        app.commit(PhoneFixtures.result(revision: 12), ticket: app.beginFetch())

        XCTAssertEqual(widget.updatePage { $0 + 1 }, 1)
        XCTAssertEqual(widget.updatePage { $0 + 1 }, 2)
        XCTAssertEqual(widget.updatePage { $0 - 5 }, 0, "pages never go below zero")
        widget.updatePage { _ in 3 }

        let state = app.read()
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(staleCopy.stored?.metadata.revision, 10)
        XCTAssertEqual(state.stored?.metadata.revision, 12)
    }

    // Scenario 4: many writers in two "processes" at once. Every page step must
    // survive (no lost update), the newest revision must win, and the file
    // must always be complete JSON.
    func testConcurrentWritersNeverLoseUpdatesOrLeavePartialFiles() throws {
        let instances = [cache(), cache()]
        let operations = 120
        let probe = ReadProbe()
        let readerDone = DispatchSemaphore(value: 0)
        let fileURL = instances[0].fileURL
        Thread {
            while !probe.stopped {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                probe.record(complete: (try? JSONSerialization.jsonObject(with: data)) != nil)
            }
            readerDone.signal()
        }.start()

        DispatchQueue.concurrentPerform(iterations: operations) { index in
            let cache = instances[index % 2]
            if index % 3 == 0 {
                let ticket = cache.beginFetch()
                cache.commit(PhoneFixtures.result(revision: Int64(index)), ticket: ticket)
            } else {
                cache.updatePage { $0 + 1 }
            }
        }
        probe.stop()
        readerDone.wait()

        let pageSteps = (0..<operations).filter { $0 % 3 != 0 }.count
        let maxRevision = Int64((0..<operations).filter { $0 % 3 == 0 }.max()!)
        let state = instances[1].read()
        XCTAssertEqual(state.page, pageSteps)
        XCTAssertEqual(state.stored?.metadata.revision, maxRevision)
        XCTAssertEqual(probe.partialReads, 0)
        XCTAssertGreaterThan(probe.completeReads, 0)
    }

    // Scenario 5: a widget fetch is suspended while the app sees a different
    // iCloud account. The late response must not repopulate the cache.
    func testLateResponseFromBeforeAnAccountChangeIsDropped() {
        let app = cache(), widget = cache()
        app.bind(account: .available(accountHash: "hash-A"))
        app.commit(PhoneFixtures.result(revision: 10), ticket: app.beginFetch())
        widget.updatePage { _ in 2 }

        let suspendedWidgetTicket = widget.beginFetch()
        XCTAssertTrue(app.bind(account: .available(accountHash: "hash-B")))
        let cleared = app.read()
        XCTAssertNil(cleared.stored)
        XCTAssertEqual(cleared.page, 0)
        XCTAssertEqual(cleared.accountHash, "hash-B")

        XCTAssertEqual(widget.commit(PhoneFixtures.result(revision: 11), ticket: suspendedWidgetTicket), .staleGeneration)
        XCTAssertNil(app.read().stored)
        // A fetch that starts after the change is accepted.
        XCTAssertEqual(widget.commit(PhoneFixtures.result(revision: 1), ticket: widget.beginFetch()), .stored)
    }

    func testAccountBindingRules() {
        let cache = cache()
        cache.commit(PhoneFixtures.result(revision: 10), ticket: cache.beginFetch())

        // First binding adopts the account without discarding data.
        XCTAssertFalse(cache.bind(account: .available(accountHash: "hash-A")))
        XCTAssertNotNil(cache.read().stored)
        XCTAssertFalse(cache.bind(account: .available(accountHash: "hash-A")))

        // Transient problems never discard dated data.
        XCTAssertFalse(cache.bind(account: .temporarilyUnavailable))
        XCTAssertFalse(cache.bind(account: .restricted))
        XCTAssertEqual(cache.read().stored?.metadata.revision, 10)
        XCTAssertEqual(cache.read().generation, 0)

        // A confirmed sign-out clears data and the binding, and advances the generation.
        XCTAssertTrue(cache.bind(account: .noAccount))
        var state = cache.read()
        XCTAssertNil(state.stored)
        XCTAssertNil(state.accountHash)
        XCTAssertEqual(state.generation, 1)
        XCTAssertFalse(cache.bind(account: .noAccount), "nothing left to clear")

        // Signing back in binds again without another clear.
        XCTAssertFalse(cache.bind(account: .available(accountHash: "hash-A")))
        state = cache.read()
        XCTAssertEqual(state.accountHash, "hash-A")
        XCTAssertEqual(state.generation, 1)
    }

    func testAccountHashIsStableAndDoesNotContainTheIdentifier() {
        let recordName = "_0123456789abcdef0123456789abcdef"
        let hash = CloudAccountIdentity.hash(recordName: recordName)
        XCTAssertEqual(hash, CloudAccountIdentity.hash(recordName: recordName))
        XCTAssertNotEqual(hash, CloudAccountIdentity.hash(recordName: recordName + "x"))
        XCTAssertEqual(hash.count, 64)
        XCTAssertFalse(hash.contains("0123456789abcdef0123456789abcdef"))
    }

    func testCacheFileHoldsOnlyTheHashedAccountAndSnapshot() throws {
        let cache = cache()
        cache.bind(account: .available(accountHash: CloudAccountIdentity.hash(recordName: "_secret-user-record")))
        cache.commit(PhoneFixtures.result(revision: 10), ticket: cache.beginFetch())
        let text = try String(contentsOf: cache.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("secret-user-record"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "generation", "accountHash", "page", "payload",
                                          "incarnation", "incarnationCreatedAt", "revision"])
    }
}

private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private(set) var partialReads = 0
    private(set) var completeReads = 0

    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return isStopped }
    func stop() { lock.lock(); isStopped = true; lock.unlock() }
    func record(complete: Bool) {
        lock.lock()
        if complete { completeReads += 1 } else { partialReads += 1 }
        lock.unlock()
    }
}

// Shared by both phone test files; the phone test target can't see the
// shared test target's fixtures.
enum PhoneFixtures {
    static let observedAt = Date(timeIntervalSince1970: 1_792_003_341)
    static let incarnationCreatedAt = Date(timeIntervalSince1970: 1_791_000_000)

    static func window(_ id: String, _ label: String, minutes: Int?, used: Double,
                       resetsAt: Date?, scope: WindowScope = .provider) -> QuotaWindow {
        QuotaWindow(id: id, label: label, durationMinutes: minutes, usedPercent: used, resetsAt: resetsAt, scope: scope)
    }

    static func snapshot(revision: Int64 = 42, observedAt: Date = observedAt) -> QuotaSnapshot {
        QuotaSnapshot(
            version: QuotaSnapshot.currentVersion,
            revision: revision,
            publishedAt: observedAt.addingTimeInterval(5),
            providers: [
                ProviderSlot(
                    provider: .claude, generation: "claude-gen-1", acceptedAttempt: 7,
                    observation: QuotaObservation(
                        source: "claude-oauth-usage", observedAt: observedAt,
                        windows: [
                            window("claude:5h", "5-hour", minutes: 300, used: 2, resetsAt: observedAt.addingTimeInterval(3 * 3600)),
                            window("claude:7d", "Weekly", minutes: 10_080, used: 17, resetsAt: observedAt.addingTimeInterval(3 * 86_400)),
                            window("claude:fable", "Fable", minutes: 10_080, used: 0,
                                   resetsAt: observedAt.addingTimeInterval(3 * 86_400), scope: .model),
                        ],
                        resetCredits: nil, creditBalance: nil),
                    lastAttempt: CollectionAttempt(at: observedAt, outcome: .success)),
                ProviderSlot(
                    provider: .codex, generation: "codex-gen-1", acceptedAttempt: 3,
                    observation: QuotaObservation(
                        source: "codex-app-server", observedAt: observedAt.addingTimeInterval(-900),
                        windows: [window("codex:codex:10080", "Weekly", minutes: 10_080, used: 13,
                                         resetsAt: observedAt.addingTimeInterval(5 * 86_400))],
                        resetCredits: ResetCreditsInfo(available: 3, nextExpiry: observedAt.addingTimeInterval(8 * 86_400)),
                        creditBalance: 62_493.38),
                    lastAttempt: CollectionAttempt(at: observedAt.addingTimeInterval(-900), outcome: .success)),
            ])
    }

    static func metadata(revision: Int64, incarnation: String = "inc-A",
                         createdAt: Date = incarnationCreatedAt) -> CloudSnapshotMetadata {
        CloudSnapshotMetadata(incarnation: incarnation, incarnationCreatedAt: createdAt, revision: revision)
    }

    static func result(revision: Int64, observedAt: Date = observedAt, incarnation: String = "inc-A",
                       createdAt: Date = incarnationCreatedAt) -> CloudFetchResult {
        .snapshot(snapshot(revision: revision, observedAt: observedAt),
                  metadata(revision: revision, incarnation: incarnation, createdAt: createdAt))
    }
}
