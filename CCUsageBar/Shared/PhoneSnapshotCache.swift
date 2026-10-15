import CloudKit
import Foundation
import os

// What the phone app and widget share in the App Group: the iCloud account
// this data belongs to, a generation number that changes whenever the data is
// thrown away, the newest snapshot with its iCloud ordering data, and the
// widget's page.
struct PhoneCacheState: Equatable {
    var generation: Int64 = 0
    // A one-way hash of the iCloud user record name. Never the identifier itself.
    var accountHash: String?
    var stored: StoredSnapshot?
    var page = 0

    static let empty = PhoneCacheState()
}

struct StoredSnapshot: Equatable {
    var snapshot: QuotaSnapshot
    var metadata: CloudSnapshotMetadata
}

// Taken before a cloud fetch starts. A response is only saved if the
// generation is still the same when it comes back.
struct CacheFetchTicket: Equatable {
    let generation: Int64
}

enum CacheCommitOutcome: Equatable {
    case stored           // a newer snapshot was saved
    case kept             // nothing newer arrived; the file is unchanged
    case staleGeneration  // the account changed while fetching; the response was dropped
}

enum CloudAccountStatus: Equatable {
    case available(accountHash: String)
    case noAccount               // confirmed: no iCloud account on this phone
    case restricted
    case temporarilyUnavailable  // includes network failures while checking
}

// One JSON file that the app and the widget extension both read and write.
// Every change rereads the file and atomically replaces it while holding a
// coordinated write, so the two processes can't interleave a
// read-compare-replace or see a half-written file.
struct PhoneSnapshotCache {
    static let appGroupIdentifier = "group.com.ccusagebar"
    static let fileName = "phone-cache.json"
    private static let logger = Logger(subsystem: "com.ccusagebar.phone", category: "cache")

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    // The App Group container both processes can reach. Falls back to this
    // process's own storage (logged) so the app still works if it's missing.
    static func appGroup() -> PhoneSnapshotCache {
        let manager = FileManager.default
        let base: URL
        if let container = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            base = container.appendingPathComponent("Library/Application Support", isDirectory: true)
        } else {
            logger.error("App Group container unavailable; the widget can't share this cache")
            base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create cache directory: \(error.localizedDescription, privacy: .public)")
        }
        return PhoneSnapshotCache(directory: base)
    }

    func read() -> PhoneCacheState {
        var state = PhoneCacheState.empty
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            state = Self.load(from: url)
        }
        if let coordinationError {
            Self.logger.error("Coordinated read failed: \(coordinationError.localizedDescription, privacy: .public)")
        }
        return state
    }

    func beginFetch() -> CacheFetchTicket {
        CacheFetchTicket(generation: read().generation)
    }

    // Saves a fetched snapshot only if the account generation hasn't changed
    // since `ticket` and the snapshot is newer than the one already saved.
    // Any other result leaves the file untouched.
    func commit(_ result: CloudFetchResult, ticket: CacheFetchTicket) -> CacheCommitOutcome {
        guard case .snapshot(let snapshot, let metadata) = result else { return .kept }
        var outcome = CacheCommitOutcome.kept
        let saved = transact { state in
            guard state.generation == ticket.generation else {
                outcome = .staleGeneration
                return false
            }
            if let current = state.stored, !metadata.isNewer(than: current.metadata) {
                return false
            }
            state.stored = StoredSnapshot(snapshot: snapshot, metadata: metadata)
            outcome = .stored
            return true
        }
        return saved ? outcome : (outcome == .stored ? .kept : outcome)
    }

    // Ties the cache to the phone's iCloud account. A confirmed sign-out or a
    // different account clears the data and page and advances the generation,
    // so fetches already in flight can't write old data back. Transient
    // problems change nothing. Returns true when data was cleared.
    @discardableResult
    func bind(account: CloudAccountStatus) -> Bool {
        switch account {
        case .restricted, .temporarilyUnavailable:
            return false
        case .available, .noAccount:
            break
        }
        var cleared = false
        transact { state in
            switch account {
            case .available(let hash):
                guard state.accountHash != hash else { return false }
                if state.accountHash != nil {
                    state.invalidate()
                    cleared = true
                }
                state.accountHash = hash
                return true
            case .noAccount:
                guard state.accountHash != nil || state.stored != nil || state.page != 0 else { return false }
                state.invalidate()
                state.accountHash = nil
                cleared = true
                return true
            case .restricted, .temporarilyUnavailable:
                return false
            }
        }
        return cleared
    }

    // Changes only the page, based on the page in the file right now.
    @discardableResult
    func updatePage(_ transform: (Int) -> Int) -> Int {
        var page = 0
        transact { state in
            page = max(0, transform(state.page))
            guard page != state.page else { return false }
            state.page = page
            return true
        }
        return page
    }

    // Holds a coordinated write for the whole reread-change-replace. `change`
    // returns false to leave the file as it is. Returns false only if a write
    // was needed and failed.
    @discardableResult
    private func transact(_ change: (inout PhoneCacheState) -> Bool) -> Bool {
        var succeeded = true
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinationError) { url in
            var state = Self.load(from: url)
            guard change(&state) else { return }
            do {
                try Self.encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                succeeded = false
                Self.logger.error("Cache write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let coordinationError {
            Self.logger.error("Coordinated write failed: \(coordinationError.localizedDescription, privacy: .public)")
            return false
        }
        return succeeded
    }

    // The file's layout. The snapshot is kept in its own encoded form so it
    // goes through the same checks as a cloud payload when read back.
    private struct FileContents: Codable {
        static let currentFormat = 1

        var format: Int
        var generation: Int64
        var accountHash: String?
        var page: Int
        var payload: Data?
        var incarnation: String?
        var incarnationCreatedAt: Date?
        var revision: Int64?
    }

    private static func load(from url: URL) -> PhoneCacheState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let contents = try? JSONDecoder.quota.decode(FileContents.self, from: data),
              contents.format == FileContents.currentFormat else {
            logger.error("Cache file unreadable; treating it as empty")
            return .empty
        }
        var state = PhoneCacheState(generation: contents.generation, accountHash: contents.accountHash,
                                    stored: nil, page: max(0, contents.page))
        if let payload = contents.payload, let incarnation = contents.incarnation,
           let createdAt = contents.incarnationCreatedAt, let revision = contents.revision {
            switch QuotaSnapshot.decode(from: payload) {
            case .success(let snapshot) where snapshot.revision == revision:
                state.stored = StoredSnapshot(snapshot: snapshot,
                                              metadata: CloudSnapshotMetadata(incarnation: incarnation,
                                                                              incarnationCreatedAt: createdAt,
                                                                              revision: revision))
            default:
                logger.error("Cached snapshot unreadable; keeping account binding only")
            }
        }
        return state
    }

    private static func encode(_ state: PhoneCacheState) throws -> Data {
        let contents = FileContents(format: FileContents.currentFormat, generation: state.generation,
                                    accountHash: state.accountHash, page: state.page,
                                    payload: try state.stored?.snapshot.encoded(),
                                    incarnation: state.stored?.metadata.incarnation,
                                    incarnationCreatedAt: state.stored?.metadata.incarnationCreatedAt,
                                    revision: state.stored?.metadata.revision)
        return try JSONEncoder.quota.encode(contents)
    }
}

private extension PhoneCacheState {
    mutating func invalidate() {
        generation += 1
        stored = nil
        page = 0
    }
}

// Which iCloud account the phone is using, from the same explicit container
// the Mac writes to. Only a hash of the user record name leaves this type.
enum CloudAccountIdentity {
    static func current(timeout: Duration = .seconds(10)) async -> CloudAccountStatus {
        await Deadline.race(after: timeout, fallback: .temporarilyUnavailable) { await check() }
    }

    static func hash(recordName: String) -> String {
        AccountHash.sha256Hex(recordName)
    }

    private static func check() async -> CloudAccountStatus {
        let container = CKContainer(identifier: CloudQuotaRecord.containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available:
                let recordID = try await container.userRecordID()
                return .available(accountHash: hash(recordName: recordID.recordName))
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                return .temporarilyUnavailable
            @unknown default:
                return .temporarilyUnavailable
            }
        } catch {
            return .temporarilyUnavailable
        }
    }
}
