import CloudKit
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
    func isNewer(than other: CloudSnapshotMetadata) -> Bool {
        if incarnationCreatedAt != other.incarnationCreatedAt {
            return incarnationCreatedAt > other.incarnationCreatedAt
        }
        return incarnation == other.incarnation && revision > other.revision
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
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let work = Task {
                gate.resume(with: await Self.fetchAndMap(fetcher))
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.resume(with: .timedOut) { work.cancel() }
            }
        }
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

// Lets the fetch and the timer race; whichever finishes first wins.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CloudFetchResult, Never>?

    init(_ continuation: CheckedContinuation<CloudFetchResult, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: CloudFetchResult) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
        return pending != nil
    }
}
