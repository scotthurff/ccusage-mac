import CloudKit
import Foundation

// TEMPORARY feasibility check (plan U1). Writes and reads one clearly synthetic
// record so signing and private iCloud delivery can be proven on real devices.
// It carries no usage data. Remove before live use.
enum CloudKitSmoke {
    static let containerIdentifier = "iCloud.com.ccusagebar"
    static let recordType = "SyntheticSmokeTest"
    static let recordName = "synthetic-smoke-test"

    struct Reading {
        let nonce: String
        let writtenAt: Date
        let writer: String
    }

    private static var container: CKContainer { CKContainer(identifier: containerIdentifier) }
    private static var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName) }

    static func accountStatusDescription() async -> String {
        do {
            switch try await container.accountStatus() {
            case .available: return "available"
            case .noAccount: return "no iCloud account"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "could not determine"
            case .temporarilyUnavailable: return "temporarily unavailable"
            @unknown default: return "unknown"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    static func write(writer: String) async throws -> Reading {
        let reading = Reading(nonce: String(UUID().uuidString.prefix(8)), writtenAt: Date(), writer: writer)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["note"] = "SYNTHETIC SMOKE TEST - not usage data"
        record["nonce"] = reading.nonce
        record["writtenAt"] = reading.writtenAt
        record["writer"] = writer
        let (results, _) = try await container.privateCloudDatabase
            .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        if case .failure(let error) = results[recordID] { throw error }
        return reading
    }

    /// Returns nil when the record does not exist yet.
    static func read() async throws -> Reading? {
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return Reading(
                nonce: record["nonce"] as? String ?? "?",
                writtenAt: record["writtenAt"] as? Date ?? .distantPast,
                writer: record["writer"] as? String ?? "?"
            )
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    static func delete() async throws {
        _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID)
    }
}
