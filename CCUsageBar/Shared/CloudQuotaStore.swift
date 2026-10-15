import CloudKit
import CryptoKit
import Foundation

// The single private CloudKit record that carries the latest snapshot.
// Only the Mac writes it; the phone app and widget read it.
enum CloudQuotaRecord {
    static let containerIdentifier = "iCloud.com.ccusagebar"
    static let recordType = "QuotaSnapshot"
    static let recordName = "latest-quota-snapshot"
    static let payloadKey = "payload"
    static let revisionKey = "revision"
    // Opaque id chosen when the record is created. A recreated record gets a
    // new one and a new server creation date.
    static let incarnationKey = "incarnation"
}

struct CloudSnapshotMetadata: Equatable {
    let incarnation: String
    let incarnationCreatedAt: Date
    let revision: Int64

    // A newer incarnation wins even with a lower revision, so recreating the
    // record recovers, while a delayed copy of an older record never does.
    // Within one incarnation only the revision decides: a cached creation
    // date has been through JSON and can drift a fraction of a microsecond.
    func isNewer(than other: CloudSnapshotMetadata) -> Bool {
        if incarnation == other.incarnation {
            return revision > other.revision
        }
        return incarnationCreatedAt > other.incarnationCreatedAt
    }
}

enum CloudFetchResult: Equatable {
    case snapshot(QuotaSnapshot, CloudSnapshotMetadata)
    case missing
    case malformed
    case unsupported(version: Int)
    case timedOut
    case unavailable(String)
}

protocol CloudRecordFetching {
    // Returns nil when the record does not exist.
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord?
}

struct CloudKitRecordFetcher: CloudRecordFetching {
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        let database = CKContainer(identifier: CloudQuotaRecord.containerIdentifier).privateCloudDatabase
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}

struct CloudQuotaStore {
    let fetcher: CloudRecordFetching
    let timeout: Duration

    init(fetcher: CloudRecordFetching = CloudKitRecordFetcher(), timeout: Duration = .seconds(10)) {
        self.fetcher = fetcher
        self.timeout = timeout
    }

    // Returns within the timeout even if the fetch ignores cancellation.
    func fetchLatest() async -> CloudFetchResult {
        let fetcher = self.fetcher
        return await Deadline.race(after: timeout, fallback: .timedOut) { await Self.fetchAndMap(fetcher) }
    }

    private static func fetchAndMap(_ fetcher: CloudRecordFetching) async -> CloudFetchResult {
        do {
            guard let record = try await fetcher.fetchRecord(id: CKRecord.ID(recordName: CloudQuotaRecord.recordName)) else {
                return .missing
            }
            return map(record: record, creationDate: record.creationDate)
        } catch let error as CKError {
            return .unavailable("CKError \(error.code.rawValue)")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func map(record: CKRecord, creationDate: Date?) -> CloudFetchResult {
        guard let payload = record[CloudQuotaRecord.payloadKey] as? Data,
              let revision = record[CloudQuotaRecord.revisionKey] as? Int64,
              let incarnation = record[CloudQuotaRecord.incarnationKey] as? String,
              let creationDate else {
            return .malformed
        }
        switch QuotaSnapshot.decode(from: payload) {
        case .success(let snapshot):
            guard snapshot.revision == revision else { return .malformed }
            return .snapshot(snapshot, CloudSnapshotMetadata(incarnation: incarnation,
                                                            incarnationCreatedAt: creationDate,
                                                            revision: revision))
        case .failure(.unsupportedVersion(let version)):
            return .unsupported(version: version)
        case .failure:
            return .malformed
        }
    }
}

// MARK: - Helpers shared by every target

enum Deadline {
    // Returns the work's result, or the fallback once the time runs out, even
    // if the work ignores cancellation. Whichever side loses is cancelled.
    static func race<T>(after timeout: Duration, fallback: T, _ work: @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            let gate = FirstResult(continuation)
            let task = Task { await work() }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if gate.resume(with: fallback) { task.cancel() }
            }
            Task {
                let value = await task.value
                if gate.resume(with: value) { timer.cancel() }
            }
        }
    }

    private final class FirstResult<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        @discardableResult
        func resume(with value: T) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }
}

enum AccountHash {
    // One-way, so raw account identifiers are never stored or published.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
