import CloudKit
import CryptoKit
import Foundation

// The write half of the CloudQuotaRecord contract. Only the Mac compiles
// this file; the phone and widget only read. CloudQuotaStore.map must accept
// every record written here.
enum CloudQuotaWriter {
    static var recordID: CKRecord.ID { CKRecord.ID(recordName: CloudQuotaRecord.recordName) }

    // The first record of a new incarnation. CloudKit dates it on first save.
    static func newRecord(incarnation: String = UUID().uuidString) -> CKRecord {
        let record = CKRecord(recordType: CloudQuotaRecord.recordType, recordID: recordID)
        record[CloudQuotaRecord.incarnationKey] = incarnation
        return record
    }

    // Puts the snapshot in the record. The revision field always equals the
    // snapshot's own revision; readers reject a record where they differ.
    // An invalid snapshot throws before the record is touched.
    static func fill(_ record: CKRecord, with snapshot: QuotaSnapshot) throws {
        let payload = try snapshot.encoded()
        record[CloudQuotaRecord.payloadKey] = payload
        record[CloudQuotaRecord.revisionKey] = snapshot.revision
    }
}

// A record as the server has it, with the date CloudKit created it. That
// date orders incarnations, so it travels with the record.
struct FetchedQuotaRecord {
    let record: CKRecord
    let creationDate: Date?
}

enum CloudAccountCheck: Equatable {
    // A one-way hash of the iCloud user record name, never the name itself.
    case available(accountHash: String)
    // Confirmed: no iCloud account on this Mac.
    case noAccount
    // Restricted, temporarily unavailable, undetermined, or the check failed.
    case unavailable
}

// The private-database calls the publisher makes. Tests supply a fake, so
// they never touch a real container.
protocol CloudQuotaDatabase {
    func account() async -> CloudAccountCheck
    // Nil when the record does not exist.
    func fetch() async throws -> FetchedQuotaRecord?
    // Saves only if the server's copy is still the one `record` was fetched
    // from; a new record saves only if none exists. Otherwise throws
    // CKError.serverRecordChanged (or .unknownItem if it was deleted).
    func saveIfUnchanged(_ record: CKRecord) async throws -> FetchedQuotaRecord
}

struct CloudKitQuotaDatabase: CloudQuotaDatabase {
    private let container = CKContainer(identifier: CloudQuotaRecord.containerIdentifier)

    // False when this build was signed without the container, as an unsigned
    // local build is. CloudKit stops such an app on first use, so check first.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(CloudQuotaRecord.containerIdentifier)
    }

    // Bounds every call, so a stuck request can't hold up later publishes.
    private static var configuration: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    func account() async -> CloudAccountCheck {
        let container = self.container
        return await Deadline.race(seconds: 15, fallback: .unavailable) {
            do {
                switch try await container.accountStatus() {
                case .available:
                    let recordID = try await container.userRecordID()
                    return .available(accountHash: Self.hash(recordID.recordName))
                case .noAccount:
                    return .noAccount
                case .restricted, .couldNotDetermine, .temporarilyUnavailable:
                    return .unavailable
                @unknown default:
                    return .unavailable
                }
            } catch {
                return .unavailable
            }
        }
    }

    func fetch() async throws -> FetchedQuotaRecord? {
        try await container.privateCloudDatabase.configuredWith(configuration: Self.configuration) { database in
            do {
                let record = try await database.record(for: CloudQuotaWriter.recordID)
                return FetchedQuotaRecord(record: record, creationDate: record.creationDate)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    func saveIfUnchanged(_ record: CKRecord) async throws -> FetchedQuotaRecord {
        try await container.privateCloudDatabase.configuredWith(configuration: Self.configuration) { database in
            do {
                let (results, _) = try await database.modifyRecords(saving: [record], deleting: [],
                                                                    savePolicy: .ifServerRecordUnchanged,
                                                                    atomically: false)
                guard let result = results[record.recordID] else { throw CKError(.internalError) }
                let saved = try result.get()
                return FetchedQuotaRecord(record: saved, creationDate: saved.creationDate)
            } catch let error as CKError where error.code == .partialFailure {
                // Report the record's own error, such as a conflict.
                throw error.partialErrorsByItemID?[record.recordID] ?? error
            }
        }
    }

    private static func hash(_ recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Returns the work's result, or the fallback once the time runs out, even if
// the work ignores cancellation.
private enum Deadline {
    static func race<T>(seconds: Double, fallback: T, _ work: @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            let gate = FirstResult(continuation)
            let task = Task { gate.resume(with: await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.resume(with: fallback) { task.cancel() }
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
