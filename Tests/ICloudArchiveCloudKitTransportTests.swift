import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ArchiveMetadataSDKStub: ICloudArchiveMetadataSDK {
    let record: CKRecord?
    var tag: String? = "tag"
    var fingerprints = ["new-user"]
    var calls: [String] = []
    var rootHook: (@Sendable () async throws -> Void)?
    var failRoot = false
    var zoneIDs: [CKRecordZone.ID] = []
    var legacyExists = false
    var legacyHook: (@Sendable () async throws -> Void)?
    init(record: CKRecord?) { self.record = record }
    func fingerprint() async throws -> String {
        let index = calls.filter { $0 == "fingerprint" }.count
        calls.append("fingerprint")
        return fingerprints[min(index, fingerprints.count - 1)]
    }
    func root(desiredKeys: [CKRecord.FieldKey]?) async throws -> (record: CKRecord?, changeTag: String?) {
        calls.append(desiredKeys == nil ? "rootAll" : "rootProjection")
        try await rootHook?()
        if failRoot { throw URLError(.notConnectedToInternet) }
        return (record, tag)
    }
    func zones() async throws -> [CKRecordZone.ID] { calls.append("zones"); return zoneIDs }
    func legacySnapshotExists(desiredKeys: [CKRecord.FieldKey]) async throws -> Bool {
        calls.append(desiredKeys.isEmpty ? "legacySystemFields" : "legacyProjection")
        try await legacyHook?()
        return legacyExists
    }
    func setLegacy(exists: Bool = false, hook: (@Sendable () async throws -> Void)? = nil) {
        legacyExists = exists; legacyHook = hook
    }
    func setZones(_ zones: [CKRecordZone.ID]) { zoneIDs = zones }
    func setFingerprints(_ values: [String]) { fingerprints = values }
    func setTag(_ tag: String?) { self.tag = tag }
    func setRootHook(_ hook: @escaping @Sendable () async throws -> Void) { rootHook = hook }
    func setRootFailure() { failRoot = true }
    func snapshot() -> [String] { calls }
}

final class ICloudArchiveCloudKitTransportTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private let accountID = "metadata-source"
    private let epoch = "00000000-0000-0000-0000-000000000001"
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveMetadata-\(UUID().uuidString)")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { try AccountRecord(id: accountID, type: "iCloud", displayName: "Old", createdAt: 1, updatedAt: 1).insert($0) }
        let repository = ICloudRecordRepository(database: database, accountID: accountID)
        try repository.activate(); try repository.bindSystemUserFingerprint("old-user")
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='accountChanged', cloud_generation=? WHERE account_id=?", arguments: [epoch, accountID]) }
    }
    override func tearDownWithError() throws {
        database = nil; try FileManager.default.removeItem(at: directory)
    }
    private func transport() -> ICloudArchiveCloudKitTransport { .init(database: database, accountID: accountID) }
    private func root() throws -> CKRecord { try ICloudCloudRootCodec.encode(.init(generation: epoch, phase: .ready)) }
    private func rows() throws -> [Row] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts") + Row.fetchAll(db, sql: "SELECT * FROM icloud_sync_scope")
        }
    }
    func testDifferentTargetUserIsObservedWithoutRebindingOrDownloadingBodies() async throws {
        let before = try rows(), sdk = ArchiveMetadataSDKStub(record: try root())
        let result = try await transport().observeAfterEntitlementCheck(using: sdk)
        XCTAssertEqual(result.fingerprint, "new-user")
        XCTAssertEqual(result.root, .found(.init(generation: epoch, phase: .ready), changeTag: "tag"))
        let calls = await sdk.snapshot(); XCTAssertEqual(calls, ["fingerprint", "fingerprint", "rootAll", "fingerprint", "zones", "fingerprint"])
        XCTAssertEqual(try rows(), before)
    }
    func testUnexpectedFullRootKeysCannotBeHiddenByProjection() async throws {
        let record = try root(); record["unexpectedPrivateField"] = "local-only-value" as NSString
        let sdk = ArchiveMetadataSDKStub(record: record)
        let result = try await transport().observeAfterEntitlementCheck(using: sdk)
        XCTAssertEqual(result.root, .incompatible)
        let calls = await sdk.snapshot(); XCTAssertTrue(calls.contains("rootAll")); XCTAssertFalse(calls.contains("rootProjection"))
    }
    func testMissingRootNeedsLegacyProbeAndMissingTagsRemainUnverified() async throws {
        let empty = ArchiveMetadataSDKStub(record: nil)
        let missing = try await transport().observeAfterEntitlementCheck(using: empty); XCTAssertEqual(missing.root, .missing)
        XCTAssertTrue(missing.isVerifiedEmpty)
        let calls = await empty.snapshot()
        XCTAssertEqual(calls, ["fingerprint", "fingerprint", "rootAll", "fingerprint", "zones", "fingerprint", "legacySystemFields", "fingerprint"])
        for tag in [nil, ""] as [String?] {
            let sdk = ArchiveMetadataSDKStub(record: try root()); await sdk.setTag(tag)
            let result = try await transport().observeAfterEntitlementCheck(using: sdk); XCTAssertEqual(result.root, .incompatible)
        }
    }
    func testLegacyExistenceIsProbedWithoutFieldsAndCannotBecomeAnEmptyTarget() async throws {
        let sdk = ArchiveMetadataSDKStub(record: nil); await sdk.setLegacy(exists: true)
        let before = try rows(), observation = try await transport().observeAfterEntitlementCheck(using: sdk)
        XCTAssertEqual(observation.legacySnapshotExists, true); XCTAssertFalse(observation.isVerifiedEmpty)
        let calls = await sdk.snapshot(); XCTAssertTrue(calls.contains("legacySystemFields")); XCTAssertFalse(calls.contains("legacyProjection"))
        XCTAssertEqual(try rows(), before)
    }
    func testOwnedDataZonesIncludingMalformedNamesAvoidLegacyLookupAndStayUnverified() async throws {
        for name in [ICloudRecordZone.library.rawValue, ICloudRecordZone.articles.rawValue + "-epoch-malformed"] {
            let sdk = ArchiveMetadataSDKStub(record: nil); await sdk.setZones([.init(zoneName: name)])
            await sdk.setLegacy(hook: { throw URLError(.notConnectedToInternet) })
            let observation = try await transport().observeAfterEntitlementCheck(using: sdk)
            XCTAssertFalse(observation.isVerifiedEmpty); XCTAssertNil(observation.legacySnapshotExists)
            let calls = await sdk.snapshot(); XCTAssertFalse(calls.contains("legacySystemFields"))
        }
    }
    func testLegacyLookupFailureIsNotAbsenceAndLeavesTheSourceUnchanged() async throws {
        let sdk = ArchiveMetadataSDKStub(record: nil); await sdk.setLegacy(hook: { throw URLError(.notConnectedToInternet) })
        let before = try rows()
        do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Legacy metadata could not be checked") }
        catch is URLError {}
        XCTAssertEqual(try rows(), before)
    }
    func testUserSourceChangeOrCancellationDuringLegacyLookupRejectsEmptyObservation() async throws {
        let value = transport(), db = database!, account = accountID
        let userSDK = ArchiveMetadataSDKStub(record: nil)
        await userSDK.setFingerprints(["new-user", "new-user", "new-user", "new-user", "third-user"])
        let before = try rows()
        do { _ = try await value.observeAfterEntitlementCheck(using: userSDK); XCTFail("Changed user during legacy check") }
        catch ICloudRecordError.accountChanged {}
        XCTAssertEqual(try rows(), before)
        let cancelledSDK = ArchiveMetadataSDKStub(record: nil)
        await cancelledSDK.setLegacy(hook: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await value.observeAfterEntitlementCheck(using: cancelledSDK) }
        do { _ = try await task.value; XCTFail("Cancelled legacy check") } catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
        let sourceSDK = ArchiveMetadataSDKStub(record: nil)
        await sourceSDK.setLegacy(hook: {
            try await db.writeAsync { try $0.execute(sql: "UPDATE icloud_sync_scope SET logical_clock=logical_clock+1 WHERE account_id=?", arguments: [account]) }
        })
        do { _ = try await value.observeAfterEntitlementCheck(using: sourceSDK); XCTFail("Changed source during legacy check") }
        catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertFalse(try db.read { try AccountRecord.fetchOne($0, key: account)!.isArchived })
    }
    func testWrongRootIdentityAndOldSchemaAreIncompatible() async throws {
        let wrong = CKRecord(recordType: ICloudCloudRootCodec.recordType, recordID: CKRecord.ID(recordName: "wrong"))
        let legacy = try root(); legacy["schemaVersion"] = 1 as NSNumber
        for record in [wrong, legacy] {
            let result = try await transport().observeAfterEntitlementCheck(using: ArchiveMetadataSDKStub(record: record))
            XCTAssertEqual(result.root, .incompatible)
        }
    }
    func testTargetUserChangeBeforeOrAfterRootReadRejectsObservation() async throws {
        for fingerprints in [["new-user", "third-user"], ["new-user", "new-user", "third-user"],
                             ["new-user", "new-user", "new-user", "third-user"]] {
            let before = try rows(), sdk = ArchiveMetadataSDKStub(record: try root()); await sdk.setFingerprints(fingerprints)
            do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Changed identity must fail") }
            catch ICloudRecordError.accountChanged {}
            XCTAssertEqual(try rows(), before)
        }
    }
    func testDisabledSourceRejectsBeforeAnySDKMethod() async throws {
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled=0 WHERE id=?", arguments: [accountID]) }
        let sdk = ArchiveMetadataSDKStub(record: try root())
        do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Disabled source") }
        catch ICloudArchiveRecoveryError.unavailableSource {}
        let calls = await sdk.snapshot(); XCTAssertTrue(calls.isEmpty)
    }
    func testSourceScopeChangeDuringReadRejectsBeforeZones() async throws {
        let sdk = ArchiveMetadataSDKStub(record: try root()), db = database!, account = accountID
        await sdk.setRootHook {
            try await db.writeAsync { try $0.execute(sql: "UPDATE icloud_sync_scope SET logical_clock=logical_clock+1 WHERE account_id=?", arguments: [account]) }
        }
        do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Changed source") }
        catch ICloudArchiveRecoveryError.staleReview {}
        let calls = await sdk.snapshot(); XCTAssertFalse(calls.contains("zones"))
    }
    func testNetworkFailureIsNotConvertedToMissingRoot() async throws {
        let before = try rows(), sdk = ArchiveMetadataSDKStub(record: try root()); await sdk.setRootFailure()
        do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Network failure") } catch is URLError {}
        XCTAssertEqual(try rows(), before)
    }
    func testEmptyFingerprintDoesNotFetchRoot() async throws {
        let sdk = ArchiveMetadataSDKStub(record: try root()); await sdk.setFingerprints([""])
        do { _ = try await transport().observeAfterEntitlementCheck(using: sdk); XCTFail("Empty fingerprint") } catch ICloudRecordError.accountChanged {}
        let calls = await sdk.snapshot(); XCTAssertFalse(calls.contains("rootAll"))
    }
    func testCancellationAfterRootReadStopsBeforeZonesAndKeepsSource() async throws {
        let before = try rows(), sdk = ArchiveMetadataSDKStub(record: try root()), value = transport()
        await sdk.setRootHook { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await value.observeAfterEntitlementCheck(using: sdk) }
        do { _ = try await task.value; XCTFail("Cancelled observation") } catch is CancellationError {}
        let calls = await sdk.snapshot(); XCTAssertFalse(calls.contains("zones"))
        XCTAssertEqual(try rows(), before)
    }
    func testUnentitledNativeTransportRejectsBeforeReadingOrCreatingSDK() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled test runner") }
        let before = try rows()
        do { _ = try await transport().observe(); XCTFail("Requires entitlement") } catch ICloudEngineError.notEntitled {}
        XCTAssertEqual(try rows(), before)
    }
}
