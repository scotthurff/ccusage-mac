import CloudKit
import Foundation
import os

// Sends the newest quota readings to the private iCloud record the phone
// reads. AppState hands over a copy of its provider slots and moves on, so
// iCloud trouble never slows collection or changes a reading.
//
// One publish runs at a time. Readings that arrive meanwhile replace the
// waiting ones; only the newest is kept, and it is saved to disk. Each publish
// reads the server record first, keeps whichever side is later for each
// provider, and only then picks the next revision. Saves are conditional, so a
// write that raced another one is reread and compared, never replayed.
@MainActor
final class QuotaPublisher {
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "publish")
    static let stateKey = "quotaPublisherState"
    private static let attemptsPerPublish = 3

    // What survives a restart. Never holds the iCloud identifier itself.
    struct State: Codable, Equatable {
        enum Binding: Codable, Equatable {
            case account(String)   // a hash of the iCloud user record name
            case signedOut
        }

        var binding: Binding?
        // Set when this Mac moves to a different iCloud account. Readings
        // observed before then are never sent into the new account.
        var observationsSince: Date?
        var baseline: Baseline?
        var pending: [ProviderSlot]?
    }

    // The server record this Mac last saw or wrote.
    struct Baseline: Codable, Equatable {
        var incarnation: String
        var incarnationCreatedAt: Date?
        var revision: Int64
    }

    private let database: CloudQuotaDatabase
    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var state: State
    // Advances on every confirmed account change. A CloudKit call that
    // started under an earlier value finished for the old account.
    private var accountEpoch = 0
    private var retryNotBefore: Date?
    private var publishTask: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?

    init(database: CloudQuotaDatabase, defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.database = database
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.stateKey),
           let stored = try? JSONDecoder.quota.decode(State.self, from: data) {
            state = stored
        } else {
            state = State()
        }
        // The next refresh replaces it; collection always comes first.
        if state.pending != nil {
            Self.logger.info("An unsent snapshot is waiting from the last run")
        }
    }

    // The running app: the real private database, and a recheck whenever
    // CloudKit reports an account change. Nil for a build without iCloud
    // signing, which then runs without publishing.
    static func live(defaults: UserDefaults) -> QuotaPublisher? {
        guard CloudKitQuotaDatabase.isEntitled else {
            logger.error("This build has no iCloud entitlement; publishing is off")
            return nil
        }
        let publisher = QuotaPublisher(database: CloudKitQuotaDatabase(), defaults: defaults)
        publisher.accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak publisher] _ in
            Task { @MainActor in await publisher?.accountMayHaveChanged() }
        }
        return publisher
    }

    var pending: [ProviderSlot]? { state.pending }
    var baseline: Baseline? { state.baseline }

    // Queues the newest readings and starts publishing if nothing is running.
    func submit(_ providers: [ProviderSlot]) {
        state.pending = providers
        persist()
        guard publishTask == nil else { return }
        publishTask = Task {
            await publishPending()
            publishTask = nil
        }
    }

    func waitUntilIdle() async {
        while let task = publishTask {
            await task.value
        }
    }

    func accountMayHaveChanged() async {
        apply(await database.account())
    }

    // Per provider, keeps the later state. In the same account context the
    // higher accepted attempt wins. A different context on this Mac (an
    // account switch or an explicit reset) always replaces the server's.
    // For the same attempt the server's copy stays: it is the same reading,
    // and the JSON payload rounds a date by up to a ten-millionth of a
    // second, so the local copy would look different and force a write.
    static func reconcile(local: [ProviderSlot], server: [ProviderSlot]?) -> [ProviderSlot] {
        guard let server else { return local }
        return local.map { mine in
            guard let theirs = server.first(where: { $0.provider == mine.provider }),
                  theirs.generation == mine.generation,
                  theirs.acceptedAttempt >= mine.acceptedAttempt else { return mine }
            return theirs
        }
    }

    // MARK: - Publishing

    private func publishPending() async {
        while let pending = state.pending {
            if let notBefore = retryNotBefore {
                guard now() >= notBefore else {
                    Self.logger.info("Publish waiting: CloudKit asked this Mac to retry later")
                    return
                }
                retryNotBefore = nil
            }
            guard await publish(pending) else { return }
            // Newer readings that arrived meanwhile go out on the next pass.
            if state.pending == pending {
                state.pending = nil
                persist()
            }
        }
    }

    // True once the server holds these readings or newer ones.
    private func publish(_ pending: [ProviderSlot]) async -> Bool {
        let epoch = accountEpoch
        guard apply(await database.account()), epoch == accountEpoch else { return false }
        let local = withoutReadingsFromBeforeTheAccount(pending)

        for _ in 0..<Self.attemptsPerPublish {
            let server: FetchedQuotaRecord?
            do {
                server = try await database.fetch()
            } catch {
                return deferred(error)
            }
            guard epoch == accountEpoch else { return droppedLateResult() }

            let record: CKRecord
            var providers = local
            let revision: Int64
            if let server {
                switch CloudQuotaStore.map(record: server.record, creationDate: server.creationDate) {
                case .snapshot(let current, let metadata):
                    providers = Self.reconcile(local: local, server: current.providers)
                    if providers == current.providers {
                        remember(Baseline(incarnation: metadata.incarnation,
                                          incarnationCreatedAt: metadata.incarnationCreatedAt,
                                          revision: metadata.revision))
                        Self.logger.info("Server already has these readings or newer (revision \(metadata.revision))")
                        return true
                    }
                    revision = max(metadata.revision, baselineRevision(for: metadata.incarnation)) + 1
                case .unsupported(let version):
                    Self.logger.error("Server record uses schema version \(version); not overwriting it")
                    return false
                default:
                    // Unreadable: replace its contents, keeping its incarnation.
                    let stored = server.record[CloudQuotaRecord.revisionKey] as? Int64 ?? 0
                    revision = max(stored, state.baseline?.revision ?? 0) + 1
                    if server.record[CloudQuotaRecord.incarnationKey] as? String == nil {
                        server.record[CloudQuotaRecord.incarnationKey] = UUID().uuidString
                    }
                    Self.logger.error("Server record was unreadable; replacing its contents")
                }
                record = server.record
            } else {
                // Missing: a new incarnation, which readers order by its new
                // server creation date before any revision.
                record = CloudQuotaWriter.newRecord()
                revision = (state.baseline?.revision ?? 0) + 1
            }

            let snapshot = QuotaSnapshot(version: QuotaSnapshot.currentVersion, revision: revision,
                                         publishedAt: now(), providers: providers)
            do {
                try CloudQuotaWriter.fill(record, with: snapshot)
            } catch {
                Self.logger.error("Snapshot failed validation; not published")
                return false
            }

            do {
                let saved = try await database.saveIfUnchanged(record)
                guard epoch == accountEpoch else { return droppedLateResult() }
                let incarnation = saved.record[CloudQuotaRecord.incarnationKey] as? String
                    ?? record[CloudQuotaRecord.incarnationKey] as? String ?? ""
                remember(Baseline(incarnation: incarnation, incarnationCreatedAt: saved.creationDate, revision: revision))
                if server == nil {
                    Self.logger.info("Published revision \(revision) in a new record")
                } else {
                    Self.logger.info("Published revision \(revision)")
                }
                return true
            } catch let error as CKError where error.code == .serverRecordChanged || error.code == .unknownItem {
                guard epoch == accountEpoch else { return droppedLateResult() }
                Self.logger.info("Server record changed during publish; rereading it")
            } catch {
                return deferred(error)
            }
        }
        Self.logger.error("Publish gave up after repeated conflicts; the next refresh tries again")
        return false
    }

    // Binds to the signed-in iCloud account. Returns true when publishing may
    // go ahead. A confirmed sign-out or a different account cancels the
    // waiting snapshot and forgets the old record; a failed check changes
    // nothing.
    @discardableResult
    private func apply(_ check: CloudAccountCheck) -> Bool {
        switch check {
        case .unavailable:
            Self.logger.info("iCloud account unavailable; keeping the waiting snapshot")
            return false
        case .noAccount:
            if state.binding != .signedOut {
                startOver(as: .signedOut)
                Self.logger.info("Signed out of iCloud; cleared the waiting snapshot and revision baseline")
            }
            return false
        case .available(let hash):
            switch state.binding {
            case .account(let bound) where bound == hash:
                return true
            case nil:
                state.binding = .account(hash)
                persist()
                return true
            case .account, .signedOut:
                startOver(as: .account(hash))
                state.observationsSince = now()
                persist()
                Self.logger.info("iCloud account changed; cleared the waiting snapshot and revision baseline")
                return false
            }
        }
    }

    private func startOver(as binding: State.Binding) {
        accountEpoch += 1
        state.binding = binding
        state.baseline = nil
        state.pending = nil
        persist()
    }

    // After an account change, a provider whose newest reading predates the
    // change is sent as unknown until it is read again.
    private func withoutReadingsFromBeforeTheAccount(_ slots: [ProviderSlot]) -> [ProviderSlot] {
        guard let since = state.observationsSince else { return slots }
        return slots.map { slot in
            var slot = slot
            if let observation = slot.observation, observation.observedAt < since {
                slot.observation = nil
            }
            return slot
        }
    }

    private func baselineRevision(for incarnation: String) -> Int64 {
        guard let baseline = state.baseline, baseline.incarnation == incarnation else { return 0 }
        return baseline.revision
    }

    private func remember(_ baseline: Baseline) {
        guard state.baseline != baseline else { return }
        state.baseline = baseline
        persist()
    }

    private func droppedLateResult() -> Bool {
        Self.logger.info("Dropped a CloudKit result from the previous iCloud account")
        return false
    }

    // Keeps the snapshot waiting for a later refresh.
    private func deferred(_ error: Error) -> Bool {
        if let error = error as? CKError {
            if let seconds = error.retryAfterSeconds {
                retryNotBefore = now().addingTimeInterval(seconds)
                Self.logger.info("Publish deferred: CloudKit error \(error.code.rawValue), retry after \(seconds, format: .fixed(precision: 0))s")
            } else {
                Self.logger.error("Publish deferred: CloudKit error \(error.code.rawValue)")
            }
        } else {
            let nsError = error as NSError
            Self.logger.error("Publish deferred: \(nsError.domain, privacy: .public) error \(nsError.code)")
        }
        return false
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder.quota.encode(state), forKey: Self.stateKey)
        } catch {
            Self.logger.error("Publisher state save failed")
        }
    }
}
