import CloudKit
import Foundation
import XCTest

// MARK: - Test doubles

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(minutes: Double) { lock.withLock { current = current.addingTimeInterval(minutes * 60) } }
    func advance(seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

// Holds callers until released; stays open afterwards.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

// Returns queued results in order; an empty queue is a failed read.
private final class QueuedCollector: QuotaCollector, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [QuotaCollectionResult] = []
    func push(_ result: QuotaCollectionResult) { lock.withLock { queue.append(result) } }
    func collect() async -> QuotaCollectionResult {
        lock.withLock { queue.isEmpty ? QuotaCollectionResult(accountKey: nil, observation: nil) : queue.removeFirst() }
    }
}

// A private database per iCloud account, with CloudKit's conditional-save
// rules: a save succeeds only from the server's current copy, and a new
// record only when none exists. A save is routed to the account signed in
// when it was sent, as CloudKit does.
private final class FakeCloudDatabase: CloudQuotaDatabase, @unchecked Sendable {
    struct Stored {
        var payload: Data?
        var revision: Int64?
        var incarnation: String?
        var createdAt: Date
        var version: Int
    }

    struct Write {
        let account: String
        let snapshot: QuotaSnapshot
        let external: Bool
    }

    struct Calls: Equatable {
        var account = 0
        var fetch = 0
        var save = 0
    }

    private let lock = NSLock()
    private let clock: Clock
    private var accountState: CloudAccountCheck
    private var servers: [String: Stored] = [:]
    private var issued: [(record: CKRecord, account: String, version: Int)] = []
    private var fetchErrors: [Error] = []
    private var saveErrors: [Error] = []
    private var duringSave: (() async -> Void)?
    private var saveGate: AsyncGate?
    private var callLog = Calls()
    private var writeLog: [Write] = []

    init(clock: Clock, account: CloudAccountCheck = .available(accountHash: accountA)) {
        self.clock = clock
        self.accountState = account
    }

    var account: CloudAccountCheck {
        get { lock.withLock { accountState } }
        set { lock.withLock { accountState = newValue } }
    }

    var calls: Calls { lock.withLock { callLog } }

    func failNextFetch(_ error: Error) { lock.withLock { fetchErrors.append(error) } }
    func failNextSave(_ error: Error) { lock.withLock { saveErrors.append(error) } }
    // Runs inside the next save, after it was sent and before the server applies it.
    func duringNextSave(_ hook: @escaping () async -> Void) { lock.withLock { duringSave = hook } }

    func holdSaves() -> AsyncGate {
        let gate = AsyncGate()
        lock.withLock { saveGate = gate }
        return gate
    }

    func writes(in account: String = accountA) -> [QuotaSnapshot] {
        lock.withLock { writeLog.filter { $0.account == account }.map(\.snapshot) }
    }

    func ownWrites(in account: String = accountA) -> [QuotaSnapshot] {
        lock.withLock { writeLog.filter { $0.account == account && !$0.external }.map(\.snapshot) }
    }

    // What a phone reading this account's record would get.
    func latest(in account: String = accountA) -> CloudFetchResult {
        guard let stored = lock.withLock({ servers[account] }) else { return .missing }
        return CloudQuotaStore.map(record: Self.makeRecord(stored), creationDate: stored.createdAt)
    }

    func published(in account: String = accountA) -> (snapshot: QuotaSnapshot, metadata: CloudSnapshotMetadata)? {
        guard case .snapshot(let snapshot, let metadata) = latest(in: account) else { return nil }
        return (snapshot, metadata)
    }

    // Another writer replaces the record: the Mac's copy becomes stale.
    func externalWrite(_ snapshot: QuotaSnapshot, in account: String = accountA) {
        lock.withLock {
            let payload = try! snapshot.encoded()
            if var stored = servers[account] {
                stored.payload = payload
                stored.revision = snapshot.revision
                stored.version += 1
                servers[account] = stored
            } else {
                servers[account] = Stored(payload: payload, revision: snapshot.revision, incarnation: UUID().uuidString,
                                          createdAt: clock.now, version: 1)
            }
            writeLog.append(Write(account: account, snapshot: snapshot, external: true))
        }
    }

    func deleteRecord(in account: String = accountA) {
        lock.withLock { servers[account] = nil }
    }

    // MARK: CloudQuotaDatabase

    func account() async -> CloudAccountCheck {
        lock.withLock {
            callLog.account += 1
            return accountState
        }
    }

    func fetch() async throws -> FetchedQuotaRecord? {
        try lock.withLock {
            callLog.fetch += 1
            if !fetchErrors.isEmpty { throw fetchErrors.removeFirst() }
            let account = try signedInAccount()
            guard let stored = servers[account] else { return nil }
            return issue(stored, account: account)
        }
    }

    func saveIfUnchanged(_ record: CKRecord) async throws -> FetchedQuotaRecord {
        let (account, hook, gate) = try lock.withLock { () throws -> (String, (() async -> Void)?, AsyncGate?) in
            callLog.save += 1
            if !saveErrors.isEmpty { throw saveErrors.removeFirst() }
            let hook = duringSave
            duringSave = nil
            return (try signedInAccount(), hook, saveGate)
        }
        await hook?()
        await gate?.wait()
        return try lock.withLock {
            let source = issued.first { $0.record === record }
            if let stored = servers[account] {
                guard let source, source.account == account, source.version == stored.version else {
                    throw CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: Self.makeRecord(stored)])
                }
                var updated = stored
                updated.payload = record[CloudQuotaRecord.payloadKey] as? Data
                updated.revision = record[CloudQuotaRecord.revisionKey] as? Int64
                updated.incarnation = record[CloudQuotaRecord.incarnationKey] as? String
                updated.version += 1
                servers[account] = updated
            } else {
                guard source == nil else { throw CKError(.unknownItem) }
                servers[account] = Stored(payload: record[CloudQuotaRecord.payloadKey] as? Data,
                                          revision: record[CloudQuotaRecord.revisionKey] as? Int64,
                                          incarnation: record[CloudQuotaRecord.incarnationKey] as? String,
                                          createdAt: clock.now, version: 1)
            }
            let stored = servers[account]!
            if let payload = stored.payload, case .success(let snapshot) = QuotaSnapshot.decode(from: payload) {
                writeLog.append(Write(account: account, snapshot: snapshot, external: false))
            }
            return issue(stored, account: account)
        }
    }

    // MARK: Helpers (call with the lock held)

    private func signedInAccount() throws -> String {
        guard case .available(let hash) = accountState else { throw CKError(.notAuthenticated) }
        return hash
    }

    private func issue(_ stored: Stored, account: String) -> FetchedQuotaRecord {
        let record = Self.makeRecord(stored)
        issued.append((record, account, stored.version))
        return FetchedQuotaRecord(record: record, creationDate: stored.createdAt)
    }

    private static func makeRecord(_ stored: Stored) -> CKRecord {
        let record = CKRecord(recordType: CloudQuotaRecord.recordType,
                              recordID: CKRecord.ID(recordName: CloudQuotaRecord.recordName))
        record[CloudQuotaRecord.payloadKey] = stored.payload
        record[CloudQuotaRecord.revisionKey] = stored.revision
        record[CloudQuotaRecord.incarnationKey] = stored.incarnation
        return record
    }
}

// MARK: - Fixtures

private let accountA = "account-A"
private let accountB = "account-B"
private let t0 = Date(timeIntervalSince1970: 1_792_003_341)

private func claudeReading(at date: Date, weekly: Double = 30) -> QuotaObservation {
    QuotaObservation(source: "claude-oauth-usage", observedAt: date, windows: [
        QuotaWindow(id: "claude:5h", label: "5-hour", durationMinutes: 300, usedPercent: 20,
                    resetsAt: date.addingTimeInterval(3 * 3600), scope: .provider),
        QuotaWindow(id: "claude:7d", label: "Weekly", durationMinutes: 10_080, usedPercent: weekly,
                    resetsAt: date.addingTimeInterval(3 * 86_400), scope: .provider),
        QuotaWindow(id: "claude:model:fable", label: "Fable", durationMinutes: 10_080, usedPercent: 10,
                    resetsAt: date.addingTimeInterval(3 * 86_400), scope: .model),
    ], resetCredits: nil, creditBalance: nil)
}

private func codexReading(at date: Date, weekly: Double = 13) -> QuotaObservation {
    QuotaObservation(source: "codex-app-server", observedAt: date, windows: [
        QuotaWindow(id: "codex:codex:10080", label: "Weekly", durationMinutes: 10_080, usedPercent: weekly,
                    resetsAt: date.addingTimeInterval(5 * 86_400), scope: .provider),
    ], resetCredits: ResetCreditsInfo(available: 3, nextExpiry: date.addingTimeInterval(8 * 86_400)), creditBalance: 100)
}

private func reading(_ provider: QuotaProvider, at date: Date, weekly: Double) -> QuotaObservation {
    provider == .claude ? claudeReading(at: date, weekly: weekly) : codexReading(at: date, weekly: weekly)
}

// A slot as AppState would hold it. `failedAt` records a later failed attempt
// that kept the earlier observation.
private func slot(_ provider: QuotaProvider, _ generation: String, attempt: Int64, observedAt: Date?,
                  weekly: Double = 30, failedAt: Date? = nil) -> ProviderSlot {
    let observation = observedAt.map { reading(provider, at: $0, weekly: weekly) }
    let lastAttempt = failedAt.map { CollectionAttempt(at: $0, outcome: .failure) }
        ?? observedAt.map { CollectionAttempt(at: $0, outcome: .success) }
    return ProviderSlot(provider: provider, generation: generation, acceptedAttempt: attempt,
                        observation: observation, lastAttempt: lastAttempt)
}

private func snapshot(revision: Int64, at date: Date, _ providers: [ProviderSlot]) -> QuotaSnapshot {
    QuotaSnapshot(version: QuotaSnapshot.currentVersion, revision: revision, publishedAt: date, providers: providers)
}

private func success(_ observation: QuotaObservation) -> QuotaCollectionResult {
    QuotaCollectionResult(accountKey: "key-1", observation: observation)
}

private let failure = QuotaCollectionResult(accountKey: nil, observation: nil)
private let networkDown = CKError(.networkUnavailable)

// Polls in real time; the test clock is unrelated.
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

// MARK: - Tests

@MainActor
final class QuotaPublisherTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock: Clock!
    private var database: FakeCloudDatabase!
    private var claude: QueuedCollector!
    private var codex: QueuedCollector!

    override func setUp() async throws {
        suiteName = "QuotaPublisherTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Clock(t0)
        database = FakeCloudDatabase(clock: clock)
        claude = QueuedCollector()
        codex = QueuedCollector()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makePublisher(defaults: UserDefaults? = nil) -> QuotaPublisher {
        let clock = self.clock!
        return QuotaPublisher(database: database, defaults: defaults ?? self.defaults, now: { clock.now })
    }

    private func makeState(_ publisher: QuotaPublisher) -> AppState {
        let clock = self.clock!
        return AppState(defaults: defaults, claudeCollector: claude, codexCollector: codex,
                        publisher: publisher, now: { clock.now }, startsAutomatically: false)
    }

    private func publish(_ publisher: QuotaPublisher, _ providers: [ProviderSlot]) async {
        publisher.submit(providers)
        await publisher.waitUntilIdle()
    }

    private func refresh(_ state: AppState, _ publisher: QuotaPublisher) async {
        await state.refreshQuotas()
        await publisher.waitUntilIdle()
    }

    // MARK: Record contract

    func testWrittenRecordRoundTripsThroughThePhoneReader() throws {
        let original = snapshot(revision: 42, at: t0, [slot(.claude, "g1", attempt: 3, observedAt: t0),
                                                      slot(.codex, "g2", attempt: 1, observedAt: nil, failedAt: t0)])
        let record = CloudQuotaWriter.newRecord(incarnation: "incarnation-1")
        try CloudQuotaWriter.fill(record, with: original)

        XCTAssertEqual(record.recordType, CloudQuotaRecord.recordType)
        XCTAssertEqual(record.recordID.recordName, CloudQuotaRecord.recordName)
        XCTAssertEqual(record[CloudQuotaRecord.revisionKey] as? Int64, 42)
        XCTAssertEqual(CloudQuotaStore.map(record: record, creationDate: t0),
                       .snapshot(original, CloudSnapshotMetadata(incarnation: "incarnation-1",
                                                                 incarnationCreatedAt: t0, revision: 42)))

        // Refilling a fetched record keeps its incarnation.
        var next = original
        next.revision = 43
        try CloudQuotaWriter.fill(record, with: next)
        XCTAssertEqual(CloudQuotaStore.map(record: record, creationDate: t0),
                       .snapshot(next, CloudSnapshotMetadata(incarnation: "incarnation-1",
                                                             incarnationCreatedAt: t0, revision: 43)))

        // An invalid snapshot is refused and the record is left as it was.
        var invalid = next
        invalid.revision = 44
        invalid.providers[0].acceptedAttempt = -1
        XCTAssertThrowsError(try CloudQuotaWriter.fill(record, with: invalid))
        XCTAssertEqual(record[CloudQuotaRecord.revisionKey] as? Int64, 43)
    }

    func testReconcileKeepsTheLaterStatePerProvider() {
        let local = [slot(.claude, "g1", attempt: 4, observedAt: t0), slot(.codex, "h2", attempt: 1, observedAt: nil)]
        let server = [slot(.claude, "g1", attempt: 6, observedAt: t0.addingTimeInterval(60)),
                      slot(.codex, "h1", attempt: 9, observedAt: t0)]
        let merged = QuotaPublisher.reconcile(local: local, server: server)
        XCTAssertEqual(merged[0], server[0], "same account context: the higher accepted attempt wins")
        XCTAssertEqual(merged[1], local[1], "a new context on the Mac supersedes the server's readings")

        let sameAttempt = [slot(.claude, "g1", attempt: 6, observedAt: t0.addingTimeInterval(60.000_000_1))]
        XCTAssertEqual(QuotaPublisher.reconcile(local: sameAttempt, server: server), [server[0]],
                       "the same accepted attempt keeps the server's copy")

        XCTAssertEqual(QuotaPublisher.reconcile(local: local, server: nil), local)
        XCTAssertEqual(QuotaPublisher.reconcile(local: local, server: [server[0]]), [server[0], local[1]])
        let newerLocal = [slot(.claude, "g1", attempt: 7, observedAt: t0.addingTimeInterval(120))]
        XCTAssertEqual(QuotaPublisher.reconcile(local: newerLocal, server: server), newerLocal)
    }

    func testPublishingKeepsEveryObservationDate() async throws {
        clock.advance(minutes: 30)
        let providers = [slot(.claude, "g1", attempt: 1, observedAt: t0),
                         slot(.codex, "h1", attempt: 1, observedAt: t0.addingTimeInterval(-600))]
        let publisher = makePublisher()
        await publish(publisher, providers)

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot.providers, providers, "uploading never changes a reading or its date")
        XCTAssertEqual(published.snapshot.publishedAt, clock.now)
        XCTAssertEqual(published.metadata.revision, 1)
        XCTAssertEqual(published.metadata.incarnationCreatedAt, clock.now)
        XCTAssertNil(publisher.pending)
        XCTAssertEqual(publisher.baseline, QuotaPublisher.Baseline(incarnation: published.metadata.incarnation,
                                                                    incarnationCreatedAt: clock.now, revision: 1))
    }

    func testReadingsTheServerAlreadyHasTakeNoNewRevision() async throws {
        // A live reading's date has a fraction of a second, which the JSON
        // payload keeps only to about a ten-millionth of a second.
        let observed = Date(timeIntervalSinceReferenceDate: t0.timeIntervalSinceReferenceDate + 0.123_456_789)
        let providers = [slot(.claude, "g", attempt: 1, observedAt: observed), slot(.codex, "h", attempt: 1, observedAt: observed)]
        let publisher = makePublisher()
        await publish(publisher, providers)
        XCTAssertNotEqual(database.published()?.snapshot.providers, providers, "the fixture must exercise the rounding")

        // The same readings again, as after a save whose response was lost.
        clock.advance(minutes: 1)
        await publish(publisher, providers)
        XCTAssertEqual(database.published()?.metadata.revision, 1)
        XCTAssertEqual(database.ownWrites().count, 1)
        XCTAssertNil(publisher.pending)
    }

    // MARK: 1. One provider fails (AE4)

    func testClaudeAdvancesWhileCodexFailsAndThePhoneKeepsCodexsDate() async throws {
        let publisher = makePublisher()
        let state = makeState(publisher)
        claude.push(success(claudeReading(at: t0)))
        codex.push(success(codexReading(at: t0)))
        await refresh(state, publisher)
        XCTAssertEqual(database.published()?.metadata.revision, 1)

        clock.advance(minutes: 15)
        claude.push(success(claudeReading(at: clock.now, weekly: 31)))
        codex.push(failure)
        await refresh(state, publisher)

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 2)
        XCTAssertEqual(published.snapshot.providers, state.providerSlots)
        let phone = QuotaPresentation(now: clock.now)
        let claudeSlot = published.snapshot.providers[0], codexSlot = published.snapshot.providers[1]
        XCTAssertEqual(claudeSlot.observation?.observedAt, clock.now)
        XCTAssertEqual(phone.provider(claudeSlot).freshness, .current)
        XCTAssertEqual(codexSlot.observation?.observedAt, t0, "Codex keeps its earlier observation date")
        XCTAssertEqual(codexSlot.lastAttempt, CollectionAttempt(at: clock.now, outcome: .failure))
        XCTAssertEqual(phone.provider(codexSlot).freshness, .outdated(.failedAttempt))
    }

    func testAProviderThatNeverSucceededReachesThePhoneAsUnknown() async throws {
        let publisher = makePublisher()
        let state = makeState(publisher)
        claude.push(success(claudeReading(at: t0)))
        codex.push(failure)
        await refresh(state, publisher)

        let codexSlot = try XCTUnwrap(database.published()?.snapshot.providers.first { $0.provider == .codex })
        XCTAssertNil(codexSlot.observation)
        XCTAssertEqual(QuotaPresentation(now: t0).provider(codexSlot).freshness, .unknown)
        XCTAssertEqual(QuotaPresentation(now: t0).provider(codexSlot).windows, [], "never a fabricated 0%")
    }

    // MARK: 2. Failed upload, restart, newer reading (AE5)

    func testAFailedUploadSurvivesARestartAndTheNewerReadingIsSentWithItsOwnDate() async throws {
        let older = [slot(.claude, "g1", attempt: 1, observedAt: t0), slot(.codex, "h1", attempt: 1, observedAt: t0)]
        database.failNextFetch(networkDown)
        let first = makePublisher()
        await publish(first, older)
        XCTAssertEqual(first.pending, older)
        XCTAssertNil(database.published())

        // Restart: the unsent snapshot is still waiting.
        let relaunched = makePublisher()
        XCTAssertEqual(relaunched.pending, older)

        clock.advance(minutes: 20)
        let newer = [slot(.claude, "g1", attempt: 2, observedAt: clock.now, weekly: 35),
                     slot(.codex, "h1", attempt: 2, observedAt: t0, failedAt: clock.now)]
        clock.advance(minutes: 10)
        await publish(relaunched, newer)

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot.providers, newer)
        XCTAssertEqual(published.snapshot.providers[0].observation?.observedAt, t0.addingTimeInterval(20 * 60),
                       "the retry keeps the reading's own date, not the upload time")
        XCTAssertEqual(published.snapshot.providers[1].observation?.observedAt, t0)
        XCTAssertEqual(published.snapshot.publishedAt, t0.addingTimeInterval(30 * 60))
        XCTAssertEqual(database.writes().map(\.providers), [newer], "the older snapshot is never sent")
        XCTAssertNil(makePublisher().pending, "nothing is left waiting after the next restart")
    }

    func testPublishingFailuresNeverTouchCollectionOrTheMenuBar() async throws {
        database.account = .unavailable
        let publisher = makePublisher()
        let state = makeState(publisher)
        claude.push(success(claudeReading(at: t0, weekly: 85)))
        codex.push(success(codexReading(at: t0)))
        await refresh(state, publisher)
        XCTAssertEqual(database.calls.fetch + database.calls.save, 0)

        database.account = .available(accountHash: accountA)
        database.failNextSave(CKError(.serverResponseLost))
        clock.advance(minutes: 15)
        claude.push(success(claudeReading(at: clock.now, weekly: 86)))
        codex.push(failure)
        await refresh(state, publisher)

        XCTAssertEqual(state.slot(.claude).observation, claudeReading(at: clock.now, weekly: 86))
        XCTAssertEqual(state.slot(.claude).lastAttempt, CollectionAttempt(at: clock.now, outcome: .success))
        XCTAssertEqual(state.slot(.codex).observation, codexReading(at: t0))
        XCTAssertEqual(state.presentation(.claude).freshness, .current)
        XCTAssertEqual(state.menuBarLabel, "CL 86%")
        XCTAssertTrue(state.limitWarningActive)
        XCTAssertEqual(publisher.pending, state.providerSlots, "kept for the next refresh")
        XCTAssertNil(database.published())
    }

    // MARK: 3. Conflicts with a newer server revision

    func testADelayedWriteCannotOverwriteNewerServerValuesOrTakeARevisionToWin() async throws {
        database.externalWrite(snapshot(revision: 1, at: t0, [slot(.claude, "g", attempt: 1, observedAt: t0),
                                                             slot(.codex, "h", attempt: 1, observedAt: t0)]))
        let newerOnServer = snapshot(revision: 2, at: t0.addingTimeInterval(1200),
                                     [slot(.claude, "g", attempt: 3, observedAt: t0.addingTimeInterval(1200), weekly: 50),
                                      slot(.codex, "h", attempt: 2, observedAt: t0.addingTimeInterval(1200), weekly: 40)])
        // A newer write lands between this Mac's read and its save.
        database.duringNextSave { [database] in database!.externalWrite(newerOnServer) }
        clock.advance(minutes: 25)
        let publisher = makePublisher()
        await publish(publisher, [slot(.claude, "g", attempt: 2, observedAt: t0.addingTimeInterval(600), weekly: 40),
                                  slot(.codex, "h", attempt: 1, observedAt: t0)])

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot, newerOnServer, "the server's newer values stay")
        XCTAssertEqual(published.metadata.revision, 2, "no new revision was taken just to win")
        XCTAssertEqual(database.ownWrites(), [], "the old payload was never replayed")
        XCTAssertEqual(database.calls.save, 1)
        XCTAssertEqual(database.calls.fetch, 2, "the conflict was followed by a fresh read")
        XCTAssertNil(publisher.pending)
        XCTAssertEqual(publisher.baseline?.revision, 2)
    }

    func testAConflictMergesSoEachProviderKeepsItsLaterState() async throws {
        database.externalWrite(snapshot(revision: 1, at: t0, [slot(.claude, "g", attempt: 1, observedAt: t0),
                                                             slot(.codex, "h", attempt: 1, observedAt: t0)]))
        let serverClaude = slot(.claude, "g", attempt: 3, observedAt: t0.addingTimeInterval(1200), weekly: 50)
        database.duringNextSave { [database] in
            database!.externalWrite(snapshot(revision: 2, at: t0.addingTimeInterval(1200),
                                             [serverClaude, slot(.codex, "h", attempt: 1, observedAt: t0)]))
        }
        clock.advance(minutes: 25)
        let localCodex = slot(.codex, "h", attempt: 2, observedAt: t0.addingTimeInterval(900), weekly: 44)
        let publisher = makePublisher()
        await publish(publisher, [slot(.claude, "g", attempt: 1, observedAt: t0), localCodex])

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 3)
        XCTAssertEqual(published.snapshot.providers, [serverClaude, localCodex])
        XCTAssertEqual(database.ownWrites().map(\.revision), [3])
    }

    // MARK: 4. Lost local state and record recreation

    func testLostRevisionStateReconcilesBeforeChoosingARevisionAndKeepsNewerServerReadings() async throws {
        let serverClaude = slot(.claude, "g", attempt: 5, observedAt: t0.addingTimeInterval(3000), weekly: 60)
        database.externalWrite(snapshot(revision: 7, at: t0.addingTimeInterval(3000),
                                        [serverClaude, slot(.codex, "h", attempt: 5, observedAt: t0.addingTimeInterval(3000))]))
        clock.advance(minutes: 60)
        // Fresh settings: no baseline. Claude's local reading is older than the server's.
        let publisher = makePublisher()
        XCTAssertNil(publisher.baseline)
        let newerCodex = slot(.codex, "h", attempt: 6, observedAt: clock.now, weekly: 20)
        await publish(publisher, [slot(.claude, "g", attempt: 3, observedAt: t0, weekly: 10), newerCodex])

        var published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 8, "continues from the server, not from 1")
        XCTAssertEqual(published.snapshot.providers, [serverClaude, newerCodex],
                       "an older local Claude reading is not promoted over the server's")

        // Nothing newer at all: no write and no new revision.
        await publish(publisher, [slot(.claude, "g", attempt: 4, observedAt: t0), newerCodex])
        published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 8)
        XCTAssertEqual(database.ownWrites().count, 1)
    }

    func testARecreatedRecordHasANewIncarnationThePhoneAcceptsOnceAndOrdersAboveTheOldOne() async throws {
        let first = makePublisher()
        await publish(first, [slot(.claude, "g", attempt: 1, observedAt: t0)])
        clock.advance(minutes: 1)
        await publish(first, [slot(.claude, "g", attempt: 2, observedAt: clock.now)])
        let phoneHeld = try XCTUnwrap(database.published()?.metadata)
        XCTAssertEqual(phoneHeld.revision, 2)

        // The record is deleted and this Mac's revision state is lost too.
        database.deleteRecord()
        clock.advance(minutes: 1)
        let otherDefaults = UserDefaults(suiteName: suiteName + "-lost")!
        defer { otherDefaults.removePersistentDomain(forName: suiteName + "-lost") }
        let relaunched = makePublisher(defaults: otherDefaults)
        await publish(relaunched, [slot(.claude, "g", attempt: 3, observedAt: clock.now)])

        let recreated = try XCTUnwrap(database.published()?.metadata)
        XCTAssertEqual(recreated.revision, 1, "a lower revision than the phone holds")
        XCTAssertNotEqual(recreated.incarnation, phoneHeld.incarnation)
        XCTAssertGreaterThan(recreated.incarnationCreatedAt, phoneHeld.incarnationCreatedAt)
        XCTAssertTrue(recreated.isNewer(than: phoneHeld), "the phone accepts the new incarnation")
        XCTAssertFalse(recreated.isNewer(than: recreated), "and accepts it only once")
        let delayedFormer = CloudSnapshotMetadata(incarnation: phoneHeld.incarnation,
                                                  incarnationCreatedAt: phoneHeld.incarnationCreatedAt, revision: 3)
        XCTAssertFalse(delayedFormer.isNewer(than: recreated), "a delayed former-incarnation response is rejected")

        // With its baseline intact, the first Mac continues its count in a new incarnation.
        database.deleteRecord()
        clock.advance(minutes: 1)
        await publish(first, [slot(.claude, "g", attempt: 4, observedAt: clock.now)])
        let again = try XCTUnwrap(database.published()?.metadata)
        XCTAssertEqual(again.revision, 3)
        XCTAssertNotEqual(again.incarnation, recreated.incarnation)
    }

    func testARecordDeletedMidPublishIsRecreatedNotResaved() async throws {
        let publisher = makePublisher()
        await publish(publisher, [slot(.claude, "g", attempt: 1, observedAt: t0)])
        let before = try XCTUnwrap(database.published()?.metadata)

        clock.advance(minutes: 1)
        database.duringNextSave { [database] in database!.deleteRecord() }
        let latest = [slot(.claude, "g", attempt: 2, observedAt: clock.now)]
        await publish(publisher, latest)

        let after = try XCTUnwrap(database.published())
        XCTAssertEqual(after.snapshot.providers, latest)
        XCTAssertNotEqual(after.metadata.incarnation, before.incarnation)
        XCTAssertTrue(after.metadata.isNewer(than: before))
        XCTAssertNil(publisher.pending)
    }

    func testLostGenerationStateDiscardsTheOldOutboxAndWaitsForFreshCollection() async throws {
        let firstPublisher = makePublisher()
        let firstState = makeState(firstPublisher)
        claude.push(success(claudeReading(at: t0)))
        codex.push(success(codexReading(at: t0)))
        await refresh(firstState, firstPublisher)

        clock.advance(minutes: 15)
        claude.push(success(claudeReading(at: clock.now, weekly: 70)))
        codex.push(success(codexReading(at: clock.now, weekly: 70)))
        database.failNextFetch(networkDown)
        await refresh(firstState, firstPublisher)
        let unsent = firstState.providerSlots
        XCTAssertEqual(firstPublisher.pending, unsent)

        // The Mac's provider state is lost; the outbox survives on disk.
        defaults.removeObject(forKey: "quotaState")
        let calls = database.calls
        let publisher = makePublisher()
        let state = makeState(publisher)
        await publisher.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(database.calls, calls, "nothing is published before a fresh collection")
        XCTAssertNotEqual(state.slot(.claude).generation, unsent[0].generation)

        clock.advance(minutes: 15)
        claude.push(success(claudeReading(at: clock.now, weekly: 40)))
        codex.push(failure)
        await refresh(state, publisher)

        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot.providers, state.providerSlots)
        XCTAssertEqual(published.snapshot.providers[0].observation?.observedAt, clock.now)
        XCTAssertNil(published.snapshot.providers[1].observation,
                     "Codex's context was not re-established by a live read, so it is unknown")
        XCTAssertFalse(database.writes().contains { $0.providers == unsent }, "the old outbox was never sent")
    }

    // MARK: 5. Throttling and a stuck publisher

    func testRetryAfterIsHonoredWhileCollectionContinuesAndOnlyTheNewestIsSent() async throws {
        let publisher = makePublisher()
        let state = makeState(publisher)
        database.failNextSave(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0]))
        claude.push(success(claudeReading(at: t0)))
        codex.push(success(codexReading(at: t0)))
        await refresh(state, publisher)
        XCTAssertNil(database.published())
        let calls = database.calls

        clock.advance(seconds: 60)
        claude.push(success(claudeReading(at: clock.now, weekly: 31)))
        codex.push(failure)
        await refresh(state, publisher)
        XCTAssertEqual(state.slot(.claude).observation?.observedAt, clock.now, "collection is not held up")
        XCTAssertEqual(database.calls, calls, "no CloudKit call before the retry-after time")
        XCTAssertEqual(publisher.pending, state.providerSlots, "only the newest waits")

        clock.advance(seconds: 61)
        claude.push(success(claudeReading(at: clock.now, weekly: 32)))
        codex.push(success(codexReading(at: clock.now, weekly: 15)))
        await refresh(state, publisher)
        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot.providers, state.providerSlots)
        XCTAssertEqual(published.metadata.revision, 1)
        XCTAssertEqual(database.ownWrites().count, 1)
    }

    func testCollectionStaysResponsiveWhileAPublishIsStuck() async throws {
        let publisher = makePublisher()
        let state = makeState(publisher)
        let gate = database.holdSaves()

        claude.push(success(claudeReading(at: t0, weekly: 40)))
        codex.push(success(codexReading(at: t0)))
        let firstRound = expectation(description: "first collection finished")
        Task { await state.refreshQuotas(); firstRound.fulfill() }
        await fulfillment(of: [firstRound], timeout: 3)
        let saveStarted = await eventually { database.calls.save == 1 }
        XCTAssertTrue(saveStarted)

        clock.advance(minutes: 15)
        claude.push(success(claudeReading(at: clock.now, weekly: 45)))
        codex.push(success(codexReading(at: clock.now, weekly: 20)))
        let secondRound = expectation(description: "second collection finished")
        Task { await state.refreshQuotas(); secondRound.fulfill() }
        await fulfillment(of: [secondRound], timeout: 3)
        XCTAssertEqual(state.slot(.claude).observation?.observedAt, clock.now)
        XCTAssertEqual(state.menuBarLabel, "CL 45%")
        XCTAssertEqual(publisher.pending, state.providerSlots)

        gate.release()
        await publisher.waitUntilIdle()
        let published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.snapshot.providers, state.providerSlots, "the newest readings follow the stuck write")
        XCTAssertEqual(published.metadata.revision, 2)
        XCTAssertNil(publisher.pending)
    }

    // MARK: 6. Account replacement and provider invalidation

    func testAccountReplacementCancelsQueuedWritesAndSendsNothingOldToTheNewAccount() async throws {
        let publisher = makePublisher()
        let firstProviders = [slot(.claude, "g", attempt: 1, observedAt: t0), slot(.codex, "h", attempt: 1, observedAt: t0)]
        await publish(publisher, firstProviders)
        let accountAIncarnation = try XCTUnwrap(database.published(in: accountA)?.metadata.incarnation)

        clock.advance(minutes: 5)
        database.failNextSave(networkDown)
        await publish(publisher, [slot(.claude, "g", attempt: 2, observedAt: clock.now),
                                  slot(.codex, "h", attempt: 2, observedAt: clock.now)])
        XCTAssertNotNil(publisher.pending)
        let beforeSwitch = clock.now

        clock.advance(minutes: 1)
        database.account = .available(accountHash: accountB)
        await publisher.accountMayHaveChanged()
        XCTAssertNil(publisher.pending, "the queued write is cancelled")
        XCTAssertNil(publisher.baseline, "the revision baseline belonged to the old account")

        // The next fresh collection: Claude read after the switch; Codex failed
        // and still holds a reading from before it.
        clock.advance(minutes: 10)
        let fresh = [slot(.claude, "g", attempt: 3, observedAt: clock.now, weekly: 33),
                     slot(.codex, "h", attempt: 3, observedAt: beforeSwitch, failedAt: clock.now)]
        await publish(publisher, fresh)

        let published = try XCTUnwrap(database.published(in: accountB))
        XCTAssertEqual(published.metadata.revision, 1)
        XCTAssertNotEqual(published.metadata.incarnation, accountAIncarnation)
        XCTAssertEqual(published.snapshot.providers[0], fresh[0])
        XCTAssertNil(published.snapshot.providers[1].observation, "no reading from before the switch reaches the new account")
        XCTAssertEqual(QuotaPresentation(now: clock.now).provider(published.snapshot.providers[1]).freshness, .unknown)
        XCTAssertEqual(database.writes(in: accountB).count, 1)
        XCTAssertEqual(database.writes(in: accountA).map(\.providers), [firstProviders])
    }

    func testASubmissionQueuedBeforeTheSwitchWasNoticedIsNotSentToTheNewAccount() async throws {
        let publisher = makePublisher()
        await publish(publisher, [slot(.claude, "g", attempt: 1, observedAt: t0)])

        clock.advance(minutes: 5)
        database.account = .available(accountHash: accountB)
        await publish(publisher, [slot(.claude, "g", attempt: 2, observedAt: clock.now)])
        XCTAssertNil(database.published(in: accountB))
        XCTAssertNil(publisher.pending)
        XCTAssertEqual(database.calls.fetch, 1, "only the first account was ever read")

        clock.advance(minutes: 15)
        let fresh = [slot(.claude, "g", attempt: 3, observedAt: clock.now)]
        await publish(publisher, fresh)
        XCTAssertEqual(database.published(in: accountB)?.snapshot.providers, fresh)
        XCTAssertEqual(database.published(in: accountB)?.metadata.revision, 1)
    }

    func testALateCompletionFromThePreviousAccountIsRejected() async throws {
        let publisher = makePublisher()
        await publish(publisher, [slot(.claude, "g", attempt: 1, observedAt: t0)])
        let accountAIncarnation = try XCTUnwrap(database.published()?.metadata.incarnation)

        // The account changes while a save to the old account is in flight.
        clock.advance(minutes: 5)
        database.duringNextSave { [database] in
            database!.account = .available(accountHash: accountB)
            await publisher.accountMayHaveChanged()
        }
        await publish(publisher, [slot(.claude, "g", attempt: 2, observedAt: clock.now)])
        XCTAssertNil(publisher.baseline, "the old account's result is not recorded for the new one")
        XCTAssertNil(publisher.pending)
        XCTAssertNil(database.published(in: accountB))

        clock.advance(minutes: 15)
        let fresh = [slot(.claude, "g", attempt: 3, observedAt: clock.now)]
        await publish(publisher, fresh)
        let published = try XCTUnwrap(database.published(in: accountB))
        XCTAssertEqual(published.snapshot.providers, fresh)
        XCTAssertEqual(published.metadata.revision, 1)
        XCTAssertNotEqual(published.metadata.incarnation, accountAIncarnation)
    }

    func testTransientAccountProblemsKeepTheOutboxAndSignOutClearsIt() async throws {
        database.account = .unavailable
        let publisher = makePublisher()
        let providers = [slot(.claude, "g", attempt: 1, observedAt: t0)]
        await publish(publisher, providers)
        XCTAssertEqual(publisher.pending, providers)
        XCTAssertEqual(database.calls.fetch, 0)

        database.account = .available(accountHash: accountA)
        await publish(publisher, providers)
        XCTAssertEqual(database.published()?.snapshot.providers, providers, "the first account adopts existing readings")
        XCTAssertNotNil(publisher.baseline)

        database.account = .noAccount
        clock.advance(minutes: 15)
        await publish(publisher, [slot(.claude, "g", attempt: 2, observedAt: clock.now)])
        XCTAssertNil(publisher.pending)
        XCTAssertNil(publisher.baseline)
        XCTAssertEqual(database.writes().count, 1)
    }

    func testProviderOnlyInvalidationReachesThePhoneAsUnknownAndKeepsTheOtherProvider() async throws {
        let publisher = makePublisher()
        let state = makeState(publisher)
        claude.push(success(claudeReading(at: t0)))
        codex.push(success(codexReading(at: t0)))
        await refresh(state, publisher)
        let claudeBefore = state.slot(.claude)
        let codexBefore = state.slot(.codex)

        // A Codex read for the old context is still in flight.
        let lateCodex = try XCTUnwrap(state.beginCollection(.codex))
        clock.advance(minutes: 1)
        state.invalidate(.codex)
        await publisher.waitUntilIdle()

        var published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 2)
        XCTAssertEqual(published.snapshot.providers[0], claudeBefore)
        let codexSlot = published.snapshot.providers[1]
        XCTAssertNotEqual(codexSlot.generation, codexBefore.generation)
        XCTAssertNil(codexSlot.observation)
        XCTAssertEqual(QuotaPresentation(now: clock.now).provider(codexSlot).freshness, .unknown)

        // The old read finishes late and the next Codex read fails: old data stays gone.
        state.finishCollection(lateCodex, success(codexReading(at: t0, weekly: 99)))
        clock.advance(minutes: 14)
        claude.push(success(claudeReading(at: clock.now)))
        codex.push(failure)
        await refresh(state, publisher)
        published = try XCTUnwrap(database.published())
        XCTAssertEqual(published.metadata.revision, 3)
        XCTAssertNil(published.snapshot.providers[1].observation)
        XCTAssertEqual(published.snapshot.providers[1].generation, codexSlot.generation)
    }
}
