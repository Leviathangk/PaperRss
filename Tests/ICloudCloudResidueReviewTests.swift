@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ResidueReviewProbe: ICloudResidueMetadataReading {
    let responses: [ICloudResidueMetadata]
    var onRead: (@Sendable (Int) async throws -> Void)?
    private var count = 0
    init(_ responses: [ICloudResidueMetadata], onRead: (@Sendable (Int) async throws -> Void)? = nil) {
        self.responses = responses; self.onRead = onRead
    }
    func metadata(for context: ICloudResidueContext) async throws -> ICloudResidueMetadata {
        count += 1
        try await onRead?(count)
        return responses[min(count - 1, responses.count - 1)]
    }
    func calls() -> Int { count }
}

private final class ResidueReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1)
    func now() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value += 31 } }
}

final class ICloudCloudResidueReviewTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var repository: ICloudRecordRepository!
    private let account = "residue-cloud"
    private let generation = "00000000-0000-0000-0000-000000000001"
    private let replacement = "00000000-0000-0000-0000-000000000002"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudResidue-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate()
        try repository.bindSystemUserFingerprint("test-user")
        try database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ? WHERE account_id = ?",
                           arguments: [generation, account])
        }
    }

    override func tearDownWithError() throws {
        repository = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func metadata(zones: [CKRecordZone.ID] = [], legacy: Bool = false,
                          root: ICloudResidueRootObservation? = nil) -> ICloudResidueMetadata {
        .init(root: root ?? .found(.init(generation: generation, phase: .ready), changeTag: "server-tag-1"),
              zones: zones, hasLegacySnapshot: legacy)
    }
    private func scan(_ values: [ICloudResidueMetadata]) async throws -> ICloudCloudResidueReview {
        try await ICloudCloudResidueScanner(repository: repository, transport: ResidueReviewProbe(values)).scan()
    }
    private func scope() throws -> Row {
        try database.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [account])! }
    }

    func testStableMetadataCountsGenerationsLegacyMalformedAndIgnoresUnrelatedZones() async throws {
        let current = try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: generation) }
        let old = try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: replacement) }
        let legacy = ICloudRecordZone.allCases.map { CKRecordZone.ID(zoneName: $0.rawValue, ownerName: CKCurrentUserDefaultName) }
        let malformed = CKRecordZone.ID(zoneName: ICloudRecordZone.library.rawValue + "-epoch-private-invalid", ownerName: CKCurrentUserDefaultName)
        let unrelated = [
            CKRecordZone.ID(zoneName: "OtherApp", ownerName: CKCurrentUserDefaultName),
            CKRecordZone.ID(zoneName: current[0].zoneName, ownerName: "another-owner"),
            ICloudCloudRootCodec.zoneID, CKRecordZone.default().zoneID
        ]
        try repository.persistEngineState(Data([1, 2, 3]))
        let before = try scope()
        var zones: [CKRecordZone.ID] = current
        zones.append(contentsOf: old)
        zones.append(contentsOf: legacy)
        zones.append(malformed)
        zones.append(contentsOf: unrelated)
        zones.append(contentsOf: current)
        let result = try await scan([metadata(zones: zones, legacy: true)])
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.didChangeDuringReview)
        XCTAssertEqual(result.rootStatus, .ready)
        XCTAssertEqual(result.currentGenerationZones, 2)
        XCTAssertEqual(result.otherGenerationZones, 2)
        XCTAssertEqual(result.legacyZones, 2)
        XCTAssertEqual(result.unrecognizedOwnedZones, 1)
        XCTAssertEqual(result.legacySnapshot, .observed)
        XCTAssertEqual(try scope(), before)
        let publicDescription = String(reflecting: result)
        for secret in [generation, replacement, "test-user", "private-invalid", "server-tag-1", "another-owner"] {
            XCTAssertFalse(publicDescription.contains(secret))
        }
    }

    func testCloudReadyReviewsReplacementWithoutResumingOldScopeOrDroppingApproval() async throws {
        let approval = ICloudCloudResetApproval(operationID: UUID().uuidString,
            previousGeneration: generation, replacementGeneration: replacement, systemFingerprint: "test-user")
        var operation = ICloudCloudResetOperation(approval: approval)
        operation.stage = .cloudReady
        try database.write {
            try $0.execute(sql: """
                UPDATE icloud_sync_scope SET cloud_reset_operation = ?, pause_reason = 'cloudResetReview'
                WHERE account_id = ?;
                """, arguments: [try operation.serialized(), account])
        }
        let current = try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: replacement) }
        let resurrectedOld = try ICloudGenerationZone.id(.articles, generation: generation)
        let before = try scope()
        let result = try await scan([metadata(zones: current + [resurrectedOld], legacy: true,
            root: .found(.init(generation: replacement, phase: .ready), changeTag: "ready-tag"))])
        XCTAssertEqual(result.rootStatus, .ready)
        XCTAssertEqual(result.currentGenerationZones, 2)
        XCTAssertEqual(result.otherGenerationZones, 1)
        XCTAssertEqual(result.legacySnapshot, .observed)
        XCTAssertEqual(try scope(), before)
        let context = try await repository.cloudResidueContext()
        XCTAssertEqual(context.boundGeneration, generation)
    }

    func testUnboundMissingIncompatibleDifferentAndResettingRootRemainReviewStates() async throws {
        let statuses: [(ICloudResidueRootObservation, ICloudCloudResidueReview.RootStatus)] = [
            (.missing, .missing), (.incompatible, .incompatible),
            (.found(.init(generation: replacement, phase: .ready), changeTag: "other"), .differentGeneration),
            (.found(.init(generation: generation, phase: .resetting), changeTag: "reset"), .resetting)
        ]
        for (root, expected) in statuses {
            let result = try await scan([metadata(root: root)])
            XCTAssertEqual(result.rootStatus, expected)
            if expected == .incompatible { XCTAssertFalse(result.isComplete) }
        }
        try database.write {
            try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = NULL WHERE account_id = ?", arguments: [account])
        }
        let id = try ICloudGenerationZone.id(.library, generation: generation)
        let unbound = try await scan([metadata(zones: [id])])
        XCTAssertEqual(unbound.rootStatus, .unbound)
        XCTAssertEqual(unbound.currentGenerationZones, 0)
        XCTAssertEqual(unbound.otherGenerationZones, 1)
        let unboundContext = try await repository.cloudResidueContext()
        XCTAssertNil(unboundContext.boundGeneration)
    }

    func testChangesBetweenObservationsPreventCompleteResultAndRetainAllObservedResidues() async throws {
        let old = try ICloudGenerationZone.id(.articles, generation: replacement)
        let first = metadata(zones: [old], legacy: true)
        let changedRoot = metadata(root: .found(.init(generation: generation, phase: .ready), changeTag: "new-tag"))
        let result = try await scan([first, changedRoot])
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.didChangeDuringReview)
        XCTAssertEqual(result.rootStatus, .changedDuringReview)
        XCTAssertEqual(result.otherGenerationZones, 1)
        XCTAssertEqual(result.legacySnapshot, .observed)
        let zonesOnly = try await scan([first, metadata()])
        XCTAssertFalse(zonesOnly.isComplete)
        XCTAssertTrue(zonesOnly.didChangeDuringReview)
        XCTAssertEqual(zonesOnly.rootStatus, .ready)
    }

    func testTimeAndZoneBudgetsStopSecondObservationWithoutCallingItAbsenceProof() async throws {
        let clock = ResidueReviewClock()
        let probe = ResidueReviewProbe([metadata()], onRead: { _ in clock.advance() })
        let limited = try await ICloudCloudResidueScanner(repository: repository, transport: probe, now: clock.now).scan()
        XCTAssertFalse(limited.isComplete)
        XCTAssertTrue(limited.reachedSafetyLimit)
        let calls = await probe.calls()
        XCTAssertEqual(calls, 1)
        let zones = try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: replacement) }
        let zoneProbe = ResidueReviewProbe([metadata(zones: zones)])
        let zoneLimited = try await ICloudCloudResidueScanner(repository: repository, transport: zoneProbe, zoneLimit: 1).scan()
        XCTAssertFalse(zoneLimited.isComplete)
        XCTAssertTrue(zoneLimited.reachedSafetyLimit)
        XCTAssertEqual(zoneLimited.otherGenerationZones, 1)
        let zoneCalls = await zoneProbe.calls()
        XCTAssertEqual(zoneCalls, 1)
    }

    func testDisabledChangedCaptureOffMissingFingerprintAndInvalidApprovalRejectBeforeTransport() async throws {
        let changes = [
            "UPDATE accounts SET is_enabled = 0",
            "UPDATE icloud_sync_scope SET pause_reason = 'accountChanged'",
            "UPDATE icloud_sync_scope SET capture_enabled = 0",
            "UPDATE icloud_sync_scope SET user_fingerprint = NULL",
            "UPDATE icloud_sync_scope SET cloud_reset_operation = X'01', pause_reason = 'cloudResetReview'",
            "UPDATE icloud_sync_scope SET pause_reason = 'cloudResetRequested'"
        ]
        for sql in changes {
            let saved = try scope()
            try database.write { try $0.execute(sql: sql) }
            let before = try scope()
            let probe = ResidueReviewProbe([metadata()])
            do {
                _ = try await ICloudCloudResidueScanner(repository: repository, transport: probe).scan()
                XCTFail("Invalid local context must fail before cloud reads")
            } catch { }
            let calls = await probe.calls()
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try scope(), before)
            try database.write {
                try $0.execute(sql: "UPDATE accounts SET is_enabled = 1")
                try $0.execute(sql: """
                    UPDATE icloud_sync_scope SET capture_enabled = 1, user_fingerprint = ?,
                        pause_reason = NULL, cloud_reset_operation = NULL;
                    """, arguments: [saved["user_fingerprint"] as String?])
            }
        }
    }

    func testMidReadScopeChangeDiscardsResultAndDoesNotStartSecondObservation() async throws {
        let database = database!, account = account
        let probe = ResidueReviewProbe([metadata()], onRead: { _ in
            try await database.writeAsync {
                try $0.execute(sql: "UPDATE icloud_sync_scope SET user_fingerprint = 'other-user' WHERE account_id = ?", arguments: [account])
            }
        })
        do {
            _ = try await ICloudCloudResidueScanner(repository: repository, transport: probe).scan()
            XCTFail("Changed account context must not publish results")
        } catch ICloudCloudResetError.operationChanged { }
        let calls = await probe.calls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try scope()["user_fingerprint"] as String, "other-user")
    }

    func testCancellationStopsBeforeAnyMetadataRead() async throws {
        let probe = ResidueReviewProbe([metadata()])
        let scanner = ICloudCloudResidueScanner(repository: repository, transport: probe)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan()
        }
        do { _ = try await task.value; XCTFail("Cancelled scans must not read cloud metadata") }
        catch is CancellationError { }
        let calls = await probe.calls()
        XCTAssertEqual(calls, 0)
    }

    func testLateCancelledResponseCannotPublishOrStartAnotherObservation() async throws {
        let probe = ResidueReviewProbe([metadata()], onRead: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let before = try scope()
        do {
            _ = try await ICloudCloudResidueScanner(repository: repository, transport: probe).scan()
            XCTFail("Late responses to cancelled reviews must be discarded")
        } catch is CancellationError { }
        let calls = await probe.calls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try scope(), before)
    }

    func testMidReadDisableAndPauseChangeDiscardResults() async throws {
        let database = database!
        for sql in ["UPDATE accounts SET is_enabled = 0",
                    "UPDATE icloud_sync_scope SET pause_reason = 'legacyCloudRoot'"] {
            let probe = ResidueReviewProbe([metadata()], onRead: { _ in
                try await database.writeAsync { try $0.execute(sql: sql) }
            })
            do {
                _ = try await ICloudCloudResidueScanner(repository: repository, transport: probe).scan()
                XCTFail("A changed scope must not publish cloud observations")
            } catch { }
            let calls = await probe.calls()
            XCTAssertEqual(calls, 1)
            try database.write {
                try $0.execute(sql: "UPDATE accounts SET is_enabled = 1")
                try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = NULL")
            }
        }
    }

    func testSDKFieldWhitelistLegacyIdentityAndUntaggedRootRejection() throws {
        XCTAssertEqual(Set(ICloudCloudResidueCloudKitTransport.rootKeys), ["schemaVersion", "generation", "phase"])
        XCTAssertTrue(ICloudCloudResidueCloudKitTransport.legacyKeys.isEmpty)
        let old = CKRecord(recordType: "OldSnapshot", recordID: ICloudRootCloudKitTransport.legacySnapshotID)
        XCTAssertNoThrow(try ICloudCloudResidueCloudKitTransport.validateLegacyMetadata(old))
        old["privatePayload"] = Data([1, 2, 3]) as NSData
        XCTAssertThrowsError(try ICloudCloudResidueCloudKitTransport.validateLegacyMetadata(old))
        let wrong = CKRecord(recordType: "OldSnapshot", recordID: .init(recordName: "other-private-record"))
        XCTAssertThrowsError(try ICloudCloudResidueCloudKitTransport.validateLegacyMetadata(wrong))
        let root = try ICloudCloudRootCodec.encode(.init(generation: generation, phase: .ready))
        XCTAssertEqual(ICloudCloudResidueCloudKitTransport.projectedRoot(root), .incompatible)
    }

    func testRealTransportIsInertAndUnentitledReadCannotConstructContainer() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled runner") }
        let transport = ICloudCloudResidueCloudKitTransport(repository: repository)
        let before = try scope()
        let context = try await repository.cloudResidueContext()
        do {
            _ = try await transport.metadata(for: context)
            XCTFail("Unentitled host must fail before CloudKit access")
        } catch ICloudEngineError.notEntitled { }
        XCTAssertEqual(try scope(), before)
    }
}
