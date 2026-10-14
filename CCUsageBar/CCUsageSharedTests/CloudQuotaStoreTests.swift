import CloudKit
import XCTest

final class CloudQuotaStoreTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_792_000_000)

    private func record(snapshot: QuotaSnapshot = Fixtures.snapshot(), revision: Int64? = nil,
                        payload: Data? = nil, incarnation: String? = "inc-A") throws -> CKRecord {
        let record = CKRecord(recordType: CloudQuotaRecord.recordType,
                              recordID: CKRecord.ID(recordName: CloudQuotaRecord.recordName))
        record[CloudQuotaRecord.payloadKey] = try payload ?? snapshot.encoded()
        record[CloudQuotaRecord.revisionKey] = revision ?? snapshot.revision
        record[CloudQuotaRecord.incarnationKey] = incarnation
        return record
    }

    func testMapsRecordToSnapshotAndOrderingMetadata() throws {
        let result = CloudQuotaStore.map(record: try record(), creationDate: created)
        XCTAssertEqual(result, .snapshot(Fixtures.snapshot(),
                                         CloudSnapshotMetadata(incarnation: "inc-A", incarnationCreatedAt: created, revision: 42)))
    }

    func testMalformedPayloadIsReported() throws {
        let result = CloudQuotaStore.map(record: try record(payload: Data("not json".utf8)), creationDate: created)
        XCTAssertEqual(result, .malformed)
    }

    func testUnsupportedVersionIsReported() throws {
        var snapshot = Fixtures.snapshot()
        snapshot.version = 2
        let result = CloudQuotaStore.map(record: try record(payload: JSONEncoder.quota.encode(snapshot)), creationDate: created)
        XCTAssertEqual(result, .unsupported(version: 2))
    }

    func testRevisionMismatchAndMissingMetadataAreMalformed() throws {
        XCTAssertEqual(CloudQuotaStore.map(record: try record(revision: 41), creationDate: created), .malformed)
        XCTAssertEqual(CloudQuotaStore.map(record: try record(incarnation: nil), creationDate: created), .malformed)
        XCTAssertEqual(CloudQuotaStore.map(record: try record(), creationDate: nil), .malformed)
    }

    func testMissingRecordIsDistinctFromFailure() async {
        let store = CloudQuotaStore(fetcher: FakeFetcher(outcome: .none), timeout: .seconds(1))
        let result = await store.fetchLatest()
        XCTAssertEqual(result, .missing)
    }

    func testFetchErrorIsUnavailable() async {
        let store = CloudQuotaStore(fetcher: FakeFetcher(outcome: .error(CKError(.networkUnavailable))), timeout: .seconds(1))
        let result = await store.fetchLatest()
        guard case .unavailable = result else { return XCTFail("expected unavailable, got \(result)") }
    }

    func testSlowFetchTimesOutWithinTheBound() async {
        let store = CloudQuotaStore(fetcher: FakeFetcher(outcome: .hang), timeout: .milliseconds(100))
        let start = Date()
        let result = await store.fetchLatest()
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testFetchedRecordUsesItsServerCreationDate() async throws {
        let store = CloudQuotaStore(fetcher: FakeFetcher(outcome: .record(try record())), timeout: .seconds(1))
        // A locally built record has no server creation date, so it cannot be ordered.
        let result = await store.fetchLatest()
        XCTAssertEqual(result, .malformed)
    }

    // KTD2: compare incarnation creation date before revision.
    func testNewerIncarnationWinsEvenWithLowerRevision() {
        let old = CloudSnapshotMetadata(incarnation: "A", incarnationCreatedAt: created, revision: 90)
        let recreated = CloudSnapshotMetadata(incarnation: "B", incarnationCreatedAt: created.addingTimeInterval(60), revision: 1)
        XCTAssertTrue(recreated.isNewer(than: old))
        XCTAssertFalse(old.isNewer(than: recreated))
        let next = CloudSnapshotMetadata(incarnation: "A", incarnationCreatedAt: created, revision: 91)
        XCTAssertTrue(next.isNewer(than: old))
        XCTAssertFalse(old.isNewer(than: old))
    }
}

private struct FakeFetcher: CloudRecordFetching {
    enum Outcome {
        case none, hang
        case record(CKRecord)
        case error(Error)
    }

    let outcome: Outcome

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        switch outcome {
        case .none: return nil
        case .record(let record): return record
        case .error(let error): throw error
        case .hang:
            // Ignores cancellation on purpose: the store must still return on time.
            Thread.sleep(forTimeInterval: 2)
            return nil
        }
    }
}
