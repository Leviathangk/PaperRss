@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ResetGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func hasEntered() -> Bool { entered }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor ResetCloud: ICloudCloudResetTransport, ICloudNewLibraryObserving {
    enum Action: CaseIterable, Sendable { case publish, libraryCreate, articlesCreate, libraryDelete, articlesDelete, ready }
    private var root: ICloudCloudRoot?
    private var fingerprint = "system-A"
    private var revision = 1
    private var zones: Set<CKRecordZone.ID>
    private var before: Action?
    private var after: Action?
    private var overrideAfter: (Action, ICloudCloudRoot)?
    private var actions: [Action] = []
    private var reads = 0
    private let gate: ResetGate?
    init(generation: String, protocolVersion: Int = 2, gate: ResetGate? = nil) throws {
        root = .init(generation: generation, phase: .ready, protocolVersion: protocolVersion)
        zones = Set(try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: generation) })
        self.gate = gate
    }
    func fail(_ action: Action, afterCommit: Bool) { if afterCommit { after = action } else { before = action } }
    func setRoot(_ value: ICloudCloudRoot?) { root = value; revision += 1 }
    func setFingerprint(_ value: String) { fingerprint = value }
    func changeRoot(after action: Action, to value: ICloudCloudRoot) { overrideAfter = (action, value) }
    func counts() -> (reads: Int, actions: [Action], root: ICloudCloudRoot?, zones: Set<CKRecordZone.ID>) { (reads, actions, root, zones) }
    func readRoot() async throws -> ICloudCloudResetRootSnapshot {
        reads += 1
        await gate?.wait()
        guard let root else { throw ICloudRootError.rootMissing }
        return .init(root: root, systemFields: Data(String(revision).utf8), systemFingerprint: fingerprint)
    }
    func readRoot(context: ICloudNewLibraryContext) async throws -> ICloudCloudResetRootSnapshot { try await readRoot() }
    private func starting(_ action: Action) throws {
        actions.append(action)
        if before == action { before = nil; throw CKError(.networkFailure) }
    }
    private func finished(_ action: Action) throws {
        if let change = overrideAfter, change.0 == action { root = change.1; revision += 1; overrideAfter = nil }
        if after == action { after = nil; throw CKError(.networkFailure) }
    }
    func writeRoot(_ value: ICloudCloudRoot, replacing snapshot: ICloudCloudResetRootSnapshot) async throws {
        guard root == snapshot.root, snapshot.systemFields == Data(String(revision).utf8) else {
            throw CKError(.serverRecordChanged)
        }
        let action: Action = value.phase == .resetting ? .publish : .ready
        try starting(action)
        root = value; revision += 1
        try finished(action)
    }
    func createZone(_ zone: ICloudRecordZone, generation: String) async throws {
        let action: Action = zone == .library ? .libraryCreate : .articlesCreate
        try starting(action)
        zones.insert(try ICloudGenerationZone.id(zone, generation: generation))
        try finished(action)
    }
    func deleteZone(_ zone: ICloudRecordZone, generation: String) async throws {
        let action: Action = zone == .library ? .libraryDelete : .articlesDelete
        try starting(action)
        zones.remove(try ICloudGenerationZone.id(zone, generation: generation))
        try finished(action)
    }
}

final class ICloudCloudResetTests: XCTestCase {
    private var directory: URL!
    private let previous = "00000000-0000-0000-0000-000000000001"
    private let replacement = "00000000-0000-0000-0000-000000000002"
    private let third = "00000000-0000-0000-0000-000000000003"
    private struct Fixture {
        let database: LibraryDatabase
        let records: ICloudRecordRepository
        let approval: ICloudCloudResetApproval
        let url: URL
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResetTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(previousVersion: Int = 2, replacementVersion: Int = 2,
                         disposition: ICloudCloudResetApproval.PreviousDataDisposition = .delete) async throws -> Fixture {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase(databaseURL: url)
        try db.write { sql in
            for (id, type) in [("cloud", "iCloud"), ("local", "local")] {
                let feedID = UUID().uuidString
                try AccountRecord(id: id, type: type, displayName: id, createdAt: 1, updatedAt: 1).save(sql)
                try FeedRecord(id: feedID, accountID: id, title: "Keep", feedURL: "https://example.com/\(id)",
                               updatedAt: 1).save(sql)
                try ItemRecord(id: id + "-item", accountID: id, externalID: id + "-item", feedID: feedID,
                    createdAt: 1, updatedAt: 1, sourceItemID: "opaque:GUID").save(sql)
                try ArticleRecord(itemID: id + "-item", title: "Keep", contentHTML: "<p>Retain original</p>").save(sql)
                try ArticleStateRecord(itemID: id + "-item", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(sql)
            }
        }
        let records = ICloudRecordRepository(database: db, accountID: "cloud")
        try records.activate()
        try records.bindSystemUserFingerprint("system-A")
        try await records.acceptCloudRoot(.init(generation: previous, phase: .ready, protocolVersion: previousVersion))
        _ = try records.outgoingRecords()
        try records.persistEngineState(Data([4, 5]))
        let approval = ICloudCloudResetApproval(operationID: UUID().uuidString, previousGeneration: previous,
            replacementGeneration: replacement, systemFingerprint: "system-A",
            previousProtocolVersion: previousVersion, replacementProtocolVersion: replacementVersion, previousDataDisposition: disposition)
        return .init(database: db, records: records, approval: approval, url: url)
    }
    private func graph(_ fixture: Fixture) throws -> [String] {
        try fixture.database.read { db in
            var values = try String.fetchAll(db, sql: """
                SELECT json_object('kind', kind, 'entity', entity_id, 'revision', revision, 'pending', is_pending,
                    'payload', payload_json, 'versions', field_versions_json)
                FROM icloud_sync_changes ORDER BY account_id, kind, entity_id;
                """)
            values += try String.fetchAll(db, sql: """
                SELECT json_object('name', record_name, 'pending', is_pending, 'json', envelope_json, 'tag', hex(system_fields))
                FROM icloud_records ORDER BY record_name;
                """)
            values += try String.fetchAll(db, sql: """
                SELECT json_object('item', item_id, 'read', is_read, 'star', is_starred)
                FROM article_states ORDER BY item_id;
                """)
            values += try String.fetchAll(db, sql: "SELECT content_html FROM articles ORDER BY item_id")
            return values
        }
    }

    func testNewLibraryReviewIsReadOnlyAndNeedsTwoNewOperationConfirmations() async throws {
        let fixture = try await fixture(), before = try graph(fixture), cloud = try ResetCloud(generation: previous)
        let reviewer = ICloudNewLibraryReviewer(repository: fixture.records)
        let review = try await reviewer.prepare(using: cloud)
        XCTAssertEqual(review.localFeeds, 1); XCTAssertEqual(review.localArticles, 1); XCTAssertEqual(review.localStarredArticles, 1)
        XCTAssertFalse(review.resumesApprovedOperation); XCTAssertEqual(try graph(fixture), before)
        XCTAssertFalse(String(describing: review).contains("system-A")); XCTAssertFalse(String(describing: review).contains("opaque:GUID"))
        for confirmations in [(false, true), (true, false)] {
            do { _ = try await reviewer.approve(id: review.id, newLibraryConfirmed: confirmations.0,
                oldCloudRetentionConfirmed: confirmations.1); XCTFail("Independent confirmations") }
            catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, confirmations.0 ? .oldCloudRetentionRequired : .newLibraryConfirmationRequired) }
            XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope") })
        }
        let approved = try await reviewer.approve(id: review.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true)
        XCTAssertEqual(approved.approval.previousProtocolVersion, 2); XCTAssertEqual(approved.approval.replacementProtocolVersion, 3)
        XCTAssertEqual(approved.approval.previousDataDisposition, .preserve)
        XCTAssertNotEqual(approved.approval.replacementGeneration, previous)
        let state = await cloud.counts(); XCTAssertTrue(state.actions.isEmpty); XCTAssertEqual(state.root?.generation, previous)
        XCTAssertEqual(try graph(fixture), before)
    }

    func testExpiredDiscardedOrChangedNewLibraryReviewCannotApprove() async throws {
        let fixture = try await fixture(), cloud = try ResetCloud(generation: previous)
        let expired = ICloudNewLibraryReviewer(repository: fixture.records, lifetime: .zero)
        let first = try await expired.prepare(using: cloud)
        do { _ = try await expired.approve(id: first.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .staleReview) }
        let reviewer = ICloudNewLibraryReviewer(repository: fixture.records)
        let second = try await reviewer.prepare(using: cloud)
        await reviewer.discard(id: second.id)
        do { _ = try await reviewer.approve(id: second.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true); XCTFail("Discarded") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .staleReview) }
        let third = try await reviewer.prepare(using: cloud)
        try fixture.records.pause(reason: "accountChanged")
        do { _ = try await reviewer.approve(id: third.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true); XCTFail("Changed context") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .staleReview) }
        XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope") })
    }

    func testNewLibraryReviewRejectsUnexpectedRootAndSystemIdentity() async throws {
        let fixture = try await fixture(), cloud = try ResetCloud(generation: previous)
        let reviewer = ICloudNewLibraryReviewer(repository: fixture.records)
        await cloud.setRoot(.init(generation: third, phase: .ready, protocolVersion: 3))
        do { _ = try await reviewer.prepare(using: cloud); XCTFail("Changed cloud root") }
        catch { XCTAssertEqual(error as? ICloudCloudResetError, .unexpectedRoot) }
        await cloud.setRoot(.init(generation: previous, phase: .ready)); await cloud.setFingerprint("system-B")
        do { _ = try await reviewer.prepare(using: cloud); XCTFail("Other system identity") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .staleReview) }
        let state = await cloud.counts(); XCTAssertTrue(state.actions.isEmpty)
    }

    func testOldClearApprovalCannotBecomeNewLibraryPreserveConsent() async throws {
        let fixture = try await fixture(), cloud = try ResetCloud(generation: previous)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        do { _ = try await ICloudNewLibraryReviewer(repository: fixture.records).prepare(using: cloud); XCTFail("Legacy clear approval") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .unavailableScope) }
        let state = await cloud.counts(); XCTAssertEqual(state.reads, 0); XCTAssertTrue(state.actions.isEmpty)
        let original = try await fixture.records.cloudResetOperation(id: fixture.approval.operationID)
        XCTAssertEqual(original.approval, fixture.approval)
    }

    func testReopenedPreserveApprovalResumesOriginalOperationWithoutReinterpretingConsent() async throws {
        let fixture = try await fixture(replacementVersion: 3, disposition: .preserve), cloud = try ResetCloud(generation: previous)
        let original = try await fixture.records.beginCloudReset(fixture.approval)
        let reopened = try LibraryDatabase(databaseURL: fixture.url)
        let reviewer = ICloudNewLibraryReviewer(repository: .init(database: reopened, accountID: "cloud"))
        let review = try await reviewer.prepare(using: cloud)
        XCTAssertTrue(review.resumesApprovedOperation)
        let resumed = try await reviewer.approve(id: review.id, newLibraryConfirmed: false, oldCloudRetentionConfirmed: false)
        XCTAssertEqual(resumed, original)
        let state = await cloud.counts(); XCTAssertTrue(state.actions.isEmpty)
    }

    func testProviderPreparesNewLibraryWhileKeepingCloudZonesAndLocalGraphForSeparateArchiveReview() async throws {
        let fixture = try await fixture(), before = try graph(fixture), cloud = try ResetCloud(generation: previous)
        let provider = ICloudAccountProvider(accountID: "cloud", database: fixture.database,
            newLibraryObserver: cloud, newLibraryTransportFactory: { _ in cloud })
        let review = try await provider.prepareNewLibraryReview()
        try await provider.executeNewLibraryReview(id: review.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true)
        let state = await cloud.counts()
        XCTAssertEqual(state.root?.protocolVersion, 3); XCTAssertNotEqual(state.root?.generation, previous)
        XCTAssertEqual(state.zones.count, 4); XCTAssertFalse(state.actions.contains(.libraryDelete)); XCTAssertFalse(state.actions.contains(.articlesDelete))
        XCTAssertEqual(try graph(fixture), before)
        XCTAssertEqual(try fixture.database.read { try Int.fetchOne($0, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope") }, 2)
        XCTAssertEqual(try fixture.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "cloudResetReview")
        await provider.stop()
    }

    func testStoppedProviderRejectsLateReadOnlyNewLibraryReview() async throws {
        let fixture = try await fixture(), gate = ResetGate(), cloud = try ResetCloud(generation: previous, gate: gate)
        let provider = ICloudAccountProvider(accountID: "cloud", database: fixture.database, newLibraryObserver: cloud)
        let task = Task { try await provider.prepareNewLibraryReview() }
        for _ in 0..<200 { if await gate.hasEntered() { break }; try await Task.sleep(for: .milliseconds(5)) }
        let entered = await gate.hasEntered(); XCTAssertTrue(entered)
        await provider.stop(); await gate.release()
        do { _ = try await task.value; XCTFail("Late review") }
        catch { XCTAssertEqual(error as? ICloudNewLibraryReviewError, .staleReview) }
        XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope") })
    }

    func testCancelledProviderNewLibraryExecutionKeepsOriginalApprovalAndCanResume() async throws {
        let fixture = try await fixture(), before = try graph(fixture), gate = ResetGate()
        let observer = try ResetCloud(generation: previous), cloud = try ResetCloud(generation: previous, gate: gate)
        let provider = ICloudAccountProvider(accountID: "cloud", database: fixture.database,
            newLibraryObserver: observer, newLibraryTransportFactory: { _ in cloud })
        let review = try await provider.prepareNewLibraryReview()
        let task = Task { try await provider.executeNewLibraryReview(id: review.id, newLibraryConfirmed: true, oldCloudRetentionConfirmed: true) }
        for _ in 0..<200 { if await gate.hasEntered() { break }; try await Task.sleep(for: .milliseconds(5)) }
        let entered = await gate.hasEntered(); XCTAssertTrue(entered)
        let context = try await fixture.records.newLibraryContext(), approved = try XCTUnwrap(context.operation)
        await provider.stop(); await gate.release()
        do { try await task.value; XCTFail("Stopped operation") } catch is CancellationError { }
        let stopped = try await fixture.records.cloudResetOperation(id: approved.approval.operationID)
        XCTAssertEqual(stopped.stage, .prepared); XCTAssertEqual(try graph(fixture), before)
        let state = await cloud.counts(); XCTAssertTrue(state.actions.isEmpty)
        let retry = try await provider.prepareNewLibraryReview()
        XCTAssertTrue(retry.resumesApprovedOperation)
        try await provider.executeNewLibraryReview(id: retry.id, newLibraryConfirmed: false, oldCloudRetentionConfirmed: false)
        let final = try await fixture.records.cloudResetOperation(id: approved.approval.operationID)
        XCTAssertEqual(final.stage, .cloudReady); XCTAssertEqual(final.approval, approved.approval)
        let complete = await cloud.counts(); XCTAssertEqual(complete.zones.count, 4)
        await provider.stop()
    }

    func testSeparatelyApprovedResetCreatesFreshV3EpochFromV2() async throws {
        let fixture = try await fixture(replacementVersion: 3)
        let before = try graph(fixture)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        let cloud = try ResetCloud(generation: previous)
        let result = try await ICloudCloudResetCoordinator(repository: fixture.records).resume(operationID: fixture.approval.operationID, using: cloud)
        XCTAssertEqual(result.stage, .cloudReady)
        let state = await cloud.counts()
        XCTAssertEqual(state.root, fixture.approval.replacementRoot); XCTAssertEqual(state.root?.protocolVersion, 3)
        XCTAssertEqual(try graph(fixture), before)
        XCTAssertEqual(try fixture.database.read { try Int.fetchOne($0, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope") }, 2)
        XCTAssertEqual(try fixture.database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope") }, "cloudResetReview")
    }

    func testV3ResetPreservesV3WriterContractInNewPhysicalEpoch() async throws {
        let fixture = try await fixture(previousVersion: 3, replacementVersion: 3)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        let cloud = try ResetCloud(generation: previous, protocolVersion: 3)
        let result = try await ICloudCloudResetCoordinator(repository: fixture.records).resume(operationID: fixture.approval.operationID, using: cloud)
        XCTAssertEqual(result.stage, .cloudReady)
        let state = await cloud.counts(); XCTAssertEqual(state.root, fixture.approval.replacementRoot)
        XCTAssertFalse(state.zones.contains(try ICloudGenerationZone.id(.articles, generation: previous)))
        XCTAssertTrue(state.zones.contains(try ICloudGenerationZone.id(.articles, generation: replacement)))
    }

    func testLegacyApprovalDecodesAsV2AndNeverAuthorizesV3() async throws {
        let fixture = try await fixture()
        let operation = ICloudCloudResetOperation(approval: fixture.approval)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: operation.serialized()) as? [String: Any])
        var approval = try XCTUnwrap(json["approval"] as? [String: Any])
        approval.removeValue(forKey: "previousProtocolVersion"); approval.removeValue(forKey: "replacementProtocolVersion")
        approval.removeValue(forKey: "previousDataDisposition")
        json["approval"] = approval
        let decoded = try ICloudCloudResetOperation.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.approval.previousProtocolVersion, 2); XCTAssertEqual(decoded.approval.replacementProtocolVersion, 2)
        approval["replacementProtocolVersion"] = NSNull(); json["approval"] = approval
        XCTAssertThrowsError(try ICloudCloudResetOperation.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testReadyReplacementWithWrongProtocolCannotReplayOldZoneDeletion() async throws {
        let fixture = try await fixture(replacementVersion: 3)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        let cloud = try ResetCloud(generation: previous)
        await cloud.setRoot(.init(generation: replacement, phase: .ready, protocolVersion: 2))
        do { _ = try await ICloudCloudResetCoordinator(repository: fixture.records).resume(operationID: fixture.approval.operationID, using: cloud); XCTFail("Wrong replacement writer protocol") }
        catch { XCTAssertEqual(error as? ICloudCloudResetError, .unexpectedRoot) }
        let state = await cloud.counts(); XCTAssertTrue(state.actions.isEmpty)
        XCTAssertTrue(state.zones.contains(try ICloudGenerationZone.id(.articles, generation: previous)))
    }

    func testResetApprovalMustMatchBoundWriterVersionAndRejectDowngrade() async throws {
        let fixture = try await fixture(previousVersion: 3, replacementVersion: 3)
        let wrong = ICloudCloudResetApproval(operationID: UUID().uuidString, previousGeneration: previous,
            replacementGeneration: replacement, systemFingerprint: "system-A", previousProtocolVersion: 2, replacementProtocolVersion: 3)
        do { _ = try await fixture.records.beginCloudReset(wrong); XCTFail("Wrong bound writer") }
        catch { XCTAssertEqual(error as? ICloudCloudResetError, .approvalMismatch) }
        let downgrade = ICloudCloudResetApproval(operationID: UUID().uuidString, previousGeneration: previous,
            replacementGeneration: replacement, systemFingerprint: "system-A", previousProtocolVersion: 3, replacementProtocolVersion: 2)
        XCTAssertThrowsError(try downgrade.validate())
    }

    func testResetConditionalRootWritesAndFinalReceiptRequireApprovedVersion() async throws {
        let fixture = try await fixture(replacementVersion: 3)
        let operation = try await fixture.records.beginCloudReset(fixture.approval)
        XCTAssertNoThrow(try ICloudCloudResetCloudKitTransport.validateRootWrite(fixture.approval.resettingRoot,
            replacing: fixture.approval.previousRoot, operation: operation))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateRootWrite(.init(generation: replacement, phase: .resetting),
            replacing: fixture.approval.previousRoot, operation: operation))
        do { _ = try await fixture.records.markCloudResetReady(operation, observed: .init(generation: replacement, phase: .ready)); XCTFail("Wrong final protocol") }
        catch { XCTAssertEqual(error as? ICloudCloudResetError, .unexpectedRoot) }
    }

    func testFreshV3ReplacementCanPreserveEveryPreviousCloudZone() async throws {
        let fixture = try await fixture(replacementVersion: 3, disposition: .preserve)
        let before = try graph(fixture)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        let cloud = try ResetCloud(generation: previous)
        let result = try await ICloudCloudResetCoordinator(repository: fixture.records).resume(operationID: fixture.approval.operationID, using: cloud)
        XCTAssertEqual(result.stage, .cloudReady)
        let state = await cloud.counts()
        XCTAssertEqual(state.root, fixture.approval.replacementRoot)
        XCTAssertEqual(state.zones.count, 4); XCTAssertFalse(state.actions.contains(.libraryDelete)); XCTAssertFalse(state.actions.contains(.articlesDelete))
        XCTAssertEqual(try graph(fixture), before)
    }

    func testPreservingReplacementResumesAmbiguousFinalSaveWithoutDeletingOldZones() async throws {
        let fixture = try await fixture(replacementVersion: 3, disposition: .preserve)
        _ = try await fixture.records.beginCloudReset(fixture.approval)
        let cloud = try ResetCloud(generation: previous); await cloud.fail(.ready, afterCommit: true)
        do { _ = try await ICloudCloudResetCoordinator(repository: fixture.records).resume(operationID: fixture.approval.operationID, using: cloud); XCTFail("Ambiguous final save") } catch {}
        let pending = try await fixture.records.cloudResetOperation(id: fixture.approval.operationID)
        XCTAssertEqual(pending.stage, .previousRetained)
        let review = try await fixture.records.recoveryReview(); XCTAssertEqual(review.resetProgress, .previousRetained)
        let reopened = try LibraryDatabase(databaseURL: fixture.url)
        let result = try await ICloudCloudResetCoordinator(repository: .init(database: reopened, accountID: "cloud"))
            .resume(operationID: fixture.approval.operationID, using: cloud)
        XCTAssertEqual(result.stage, .cloudReady)
        let state = await cloud.counts(); XCTAssertEqual(state.zones.count, 4)
        XCTAssertFalse(state.actions.contains(.libraryDelete)); XCTAssertFalse(state.actions.contains(.articlesDelete))
        XCTAssertEqual(state.actions.filter { $0 == .ready }.count, 1)
    }

    func testPreserveApprovalCannotReachAnyDeletionStageOrSDKDelete() async throws {
        let fixture = try await fixture(replacementVersion: 3, disposition: .preserve)
        var operation = ICloudCloudResetOperation(approval: fixture.approval)
        operation.stage = .articlesCreated
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateZoneMutation(.library, generation: previous, creating: false, operation: operation))
        operation.stage = .libraryDeleted; XCTAssertThrowsError(try operation.validate())
        operation.stage = .articlesDeleted; XCTAssertThrowsError(try operation.validate())
        operation.stage = .previousRetained
        XCTAssertNoThrow(try ICloudCloudResetCloudKitTransport.validateRootWrite(fixture.approval.replacementRoot,
            replacing: fixture.approval.resettingRoot, operation: operation))
        let clear = try await self.fixture()
        var invalid = ICloudCloudResetOperation(approval: clear.approval); invalid.stage = .previousRetained
        XCTAssertThrowsError(try invalid.validate())
    }
    private func expectFailure(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected reset failure", file: file, line: line) } catch {}
    }
    private func eventually(_ work: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await work() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected reset condition")
    }

    func testNoApprovalMeansNoCloudRequestOrResetOperation() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        let coordinator = ICloudCloudResetCoordinator(repository: f.records)
        await expectFailure { _ = try await coordinator.resume(operationID: UUID().uuidString, using: cloud) }
        let counts = await cloud.counts()
        XCTAssertEqual(counts.reads, 0)
        XCTAssertTrue(counts.actions.isEmpty)
        XCTAssertNil(try f.database.read { try Data.fetchOne($0, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope") })
    }

    func testApprovedResetOrdersAllStagesAndRetainsLocalGraphIntentsAndCheckpoint() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        let before = try graph(f)
        let clock = try f.database.read { try Int64.fetchOne($0, sql: "SELECT logical_clock FROM icloud_sync_scope") }
        _ = try await f.records.beginCloudReset(f.approval)
        let result = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        XCTAssertEqual(result.stage, .cloudReady)
        let counts = await cloud.counts()
        XCTAssertEqual(counts.actions, ResetCloud.Action.allCases)
        XCTAssertEqual(counts.root, .init(generation: replacement, phase: .ready))
        XCTAssertEqual(counts.zones, Set(try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: replacement) }))
        XCTAssertEqual(try graph(f), before)
        try f.database.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope"), previous)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT pause_reason FROM icloud_sync_scope"), "cloudResetReview")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT capture_enabled FROM icloud_sync_scope"), 1)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope"), Data([4, 5]))
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT logical_clock FROM icloud_sync_scope"), clock)
            XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
        }
    }

    func testRepeatedConfirmationIsIdempotentAndDifferentOperationCannotReplaceIt() async throws {
        let f = try await fixture()
        let initial = try await f.records.beginCloudReset(f.approval)
        let repeated = try await f.records.beginCloudReset(f.approval)
        XCTAssertEqual(initial, repeated)
        let another = ICloudCloudResetApproval(operationID: UUID().uuidString, previousGeneration: previous,
            replacementGeneration: third, systemFingerprint: "system-A")
        await expectFailure { _ = try await f.records.beginCloudReset(another) }
        let stored = try await f.records.cloudResetOperation(id: f.approval.operationID)
        XCTAssertEqual(stored, initial)
    }

    func testEveryFailedStageCanResumeFromReopenedDatabase() async throws {
        for action in ResetCloud.Action.allCases {
            let f = try await fixture(), cloud = try ResetCloud(generation: previous)
            _ = try await f.records.beginCloudReset(f.approval)
            await cloud.fail(action, afterCommit: false)
            await expectFailure {
                _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            }
            let reopened = try LibraryDatabase(databaseURL: f.url)
            let records = ICloudRecordRepository(database: reopened, accountID: "cloud")
            let result = try await ICloudCloudResetCoordinator(repository: records).resume(operationID: f.approval.operationID, using: cloud)
            XCTAssertEqual(result.stage, .cloudReady, "\(action)")
            let counts = await cloud.counts()
            XCTAssertEqual(counts.root, .init(generation: replacement, phase: .ready))
            XCTAssertEqual(counts.zones.count, 2)
        }
    }

    func testAmbiguousCommitAtEveryRemoteStageResumesSameApprovedEpoch() async throws {
        for action in ResetCloud.Action.allCases {
            let f = try await fixture(), cloud = try ResetCloud(generation: previous)
            _ = try await f.records.beginCloudReset(f.approval)
            await cloud.fail(action, afterCommit: true)
            await expectFailure {
                _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            }
            let result = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            XCTAssertEqual(result.approval, f.approval)
            XCTAssertEqual(result.stage, .cloudReady)
            let counts = await cloud.counts()
            if action == .publish { XCTAssertEqual(counts.actions.filter { $0 == .publish }.count, 1) }
            if action == .ready { XCTAssertEqual(counts.actions.filter { $0 == .ready }.count, 1) }
        }
    }

    func testAlreadyReadyReplacementNeverReplaysDeletionEvenWithOldLocalStage() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        _ = try await f.records.beginCloudReset(f.approval)
        await cloud.setRoot(.init(generation: replacement, phase: .ready))
        let result = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        let counts = await cloud.counts()
        XCTAssertEqual(result.stage, .cloudReady)
        XCTAssertTrue(counts.actions.isEmpty)
        // Root-ready alone is not a claim that residual old zones are erased.
        XCTAssertEqual(counts.zones.count, 2)
    }

    func testMissingOrSupersededRootCannotBeCreatedOrOverwritten() async throws {
        for root in [nil, ICloudCloudRoot(generation: third, phase: .ready)] {
            let f = try await fixture(), cloud = try ResetCloud(generation: previous)
            _ = try await f.records.beginCloudReset(f.approval)
            await cloud.setRoot(root)
            await expectFailure {
                _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            }
            let counts = await cloud.counts()
            XCTAssertTrue(counts.actions.isEmpty)
            XCTAssertEqual(counts.root, root)
        }
    }

    func testRootChangeBetweenStagesStopsWithoutAdditionalZoneMutation() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        _ = try await f.records.beginCloudReset(f.approval)
        await cloud.changeRoot(after: .libraryCreate, to: .init(generation: third, phase: .ready))
        await expectFailure {
            _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        }
        let counts = await cloud.counts()
        XCTAssertEqual(counts.actions, [.publish, .libraryCreate])
        XCTAssertEqual(counts.root, .init(generation: third, phase: .ready))
    }

    func testDisabledAccountOrChangedFingerprintRejectsStoredApprovalBeforeNetwork() async throws {
        for sql in ["UPDATE accounts SET is_enabled = 0 WHERE id = 'cloud'",
                    "UPDATE icloud_sync_scope SET user_fingerprint = 'system-B'"] {
            let f = try await fixture(), cloud = try ResetCloud(generation: previous)
            _ = try await f.records.beginCloudReset(f.approval)
            try f.database.write { try $0.execute(sql: sql) }
            await expectFailure {
                _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            }
            let counts = await cloud.counts()
            XCTAssertEqual(counts.reads, 0)
        }
    }

    func testServerFingerprintMismatchCannotApplyAnyResetMutation() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        _ = try await f.records.beginCloudReset(f.approval)
        await cloud.setFingerprint("system-B")
        await expectFailure {
            _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        }
        let counts = await cloud.counts()
        XCTAssertTrue(counts.actions.isEmpty)
        XCTAssertEqual(counts.root, .init(generation: previous, phase: .ready))
    }

    func testStoppedExecutorRetainsLeaseUntilLateResponseReturns() async throws {
        let f = try await fixture(), gate = ResetGate(), cloud = try ResetCloud(generation: previous, gate: gate)
        _ = try await f.records.beginCloudReset(f.approval)
        let coordinator = ICloudCloudResetCoordinator(repository: f.records)
        let old = Task { try await coordinator.resume(operationID: f.approval.operationID, using: cloud) }
        try await eventually { await gate.hasEntered() }
        await coordinator.stop()
        await expectFailure { _ = try await coordinator.resume(operationID: f.approval.operationID, using: cloud) }
        await gate.release()
        await expectFailure { _ = try await old.value }
        let counts = await cloud.counts()
        XCTAssertTrue(counts.actions.isEmpty)
        let retried = try await coordinator.resume(operationID: f.approval.operationID, using: cloud)
        XCTAssertEqual(retried.stage, .cloudReady)
    }

    func testSecondCoordinatorCannotStealLiveFileLease() async throws {
        let f = try await fixture(), gate = ResetGate(), cloud = try ResetCloud(generation: previous, gate: gate)
        _ = try await f.records.beginCloudReset(f.approval)
        let first = ICloudCloudResetCoordinator(repository: f.records)
        let running = Task { try await first.resume(operationID: f.approval.operationID, using: cloud) }
        try await eventually { await gate.hasEntered() }
        await expectFailure {
            _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        }
        let counts = await cloud.counts()
        XCTAssertEqual(counts.reads, 1)
        await gate.release()
        let result = try await running.value
        XCTAssertEqual(result.stage, .cloudReady)
    }

    func testDisabledDuringRootReadCannotApplyLateResponse() async throws {
        let f = try await fixture(), gate = ResetGate(), cloud = try ResetCloud(generation: previous, gate: gate)
        _ = try await f.records.beginCloudReset(f.approval)
        let work = Task {
            try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        }
        try await eventually { await gate.hasEntered() }
        try f.database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = 'cloud'") }
        await gate.release()
        await expectFailure { _ = try await work.value }
        let counts = await cloud.counts()
        XCTAssertTrue(counts.actions.isEmpty)
    }

    func testOldStageCommitCannotRegressCurrentDurableStage() async throws {
        let f = try await fixture()
        let old = try await f.records.beginCloudReset(f.approval)
        let current = try await f.records.advanceCloudReset(old, to: .rootPublished)
        await expectFailure { _ = try await f.records.advanceCloudReset(old, to: .rootPublished) }
        let stored = try await f.records.cloudResetOperation(id: f.approval.operationID)
        XCTAssertEqual(stored, current)
        await expectFailure { _ = try await f.records.advanceCloudReset(current, to: .articlesDeleted) }
    }

    func testCorruptOversizeAndUnknownVersionOperationsStopBeforeNetwork() async throws {
        for bytes in [Data("bad-json".utf8), Data(repeating: 65, count: 8193),
                      Data(#"{"schemaVersion":2}"#.utf8)] {
            let f = try await fixture(), cloud = try ResetCloud(generation: previous)
            _ = try await f.records.beginCloudReset(f.approval)
            try f.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_reset_operation = ?", arguments: [bytes]) }
            await expectFailure {
                _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
            }
            let counts = await cloud.counts()
            XCTAssertEqual(counts.reads, 0)
        }
    }

    func testTransportMutationValidationForbidsDeletingReplacementOrSkippingStages() async throws {
        let f = try await fixture()
        var operation = ICloudCloudResetOperation(approval: f.approval)
        operation.stage = .articlesCreated
        XCTAssertNoThrow(try ICloudCloudResetCloudKitTransport.validateZoneMutation(.library, generation: previous,
            creating: false, operation: operation))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateZoneMutation(.library, generation: replacement,
            creating: false, operation: operation))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateZoneMutation(.articles, generation: previous,
            creating: false, operation: operation))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateZoneMutation(.library, generation: previous,
            creating: true, operation: operation))
        operation.stage = .prepared
        XCTAssertNoThrow(try ICloudCloudResetCloudKitTransport.validateRootWrite(.init(generation: replacement, phase: .resetting),
            replacing: .init(generation: previous, phase: .ready), operation: operation))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.validateRootWrite(.init(generation: replacement, phase: .ready),
            replacing: .init(generation: previous, phase: .ready), operation: operation))
        operation.stage = .articlesDeleted
        XCTAssertNoThrow(try ICloudCloudResetCloudKitTransport.validateRootWrite(.init(generation: replacement, phase: .ready),
            replacing: .init(generation: replacement, phase: .resetting), operation: operation))
    }

    func testResetRootCASRejectsFreshOrWrongRecordSystemFields() throws {
        let desired = ICloudCloudRoot(generation: replacement, phase: .resetting)
        let fresh = try ICloudCloudRootCodec.encode(.init(generation: previous, phase: .ready))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.rootRecord(desired,
            systemFields: ICloudRecordCodec.systemFields(fresh)))
        let foreign = CKRecord(recordType: "Other", recordID: .init(recordName: "unrelated"))
        XCTAssertThrowsError(try ICloudCloudResetCloudKitTransport.rootRecord(desired,
            systemFields: ICloudRecordCodec.systemFields(foreign)))
    }

    func testRealTransportRemainsInertWithoutCloudEntitlement() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled test host requires explicit live-cloud acceptance") }
        let f = try await fixture()
        _ = try await f.records.beginCloudReset(f.approval)
        let transport = ICloudCloudResetCloudKitTransport(repository: f.records, operationID: f.approval.operationID)
        do { _ = try await transport.readRoot(); XCTFail("Expected entitlement guard") }
        catch { XCTAssertEqual(error as? ICloudEngineError, .notEntitled) }
        let operation = try await f.records.cloudResetOperation(id: f.approval.operationID)
        XCTAssertEqual(operation.stage, .prepared)
    }

    func testV18UpgradeRetainsHistoryAndLeavesResetApprovalEmpty() throws {
        let url = directory.appendingPathComponent("v18.sqlite")
        let pool = try DatabasePool(path: url.path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v18-icloud-bootstrap-retry")
        let feed = UUID().uuidString
        try pool.write { db in
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feed, accountID: "cloud", title: "Keep", feedURL: "https://example.com/history", updatedAt: 1).save(db)
            try ItemRecord(id: "old", accountID: "cloud", externalID: "old", feedID: feed, createdAt: 1,
                updatedAt: 1, sourceItemID: "opaque-original").save(db)
            try ArticleRecord(itemID: "old", title: "Keep", contentHTML: "<p>Keep history</p>").save(db)
            try ArticleStateRecord(itemID: "old", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope (account_id, capture_enabled, cloud_generation, engine_state,
                    root_retry_at, root_retry_attempt, root_retry_revision)
                VALUES ('cloud', 0, ?, ?, 1800000050, 2, 3);
                """, arguments: [previous, Data([4, 5])])
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope"))
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT pause_reason FROM icloud_sync_scope"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT capture_enabled FROM icloud_sync_scope"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope"), previous)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope"), Data([4, 5]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT root_retry_revision FROM icloud_sync_scope"), 3)
            XCTAssertEqual(try ItemRecord.fetchOne(db, key: "old")?.sourceItemID, "opaque-original")
            XCTAssertEqual(try ArticleRecord.fetchOne(db, key: "old")?.contentHTML, "<p>Keep history</p>")
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isRead == true)
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isStarred == true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes"), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
        }
    }

    func testAccountRemovalCannotDiscardApprovedOrReadyResetEvidence() async throws {
        let f = try await fixture(), cloud = try ResetCloud(generation: previous)
        _ = try await f.records.beginCloudReset(f.approval)
        let accounts = AccountRepository(database: f.database)
        await expectFailure { try await accounts.validateAccountRemoval(id: "cloud") }
        await expectFailure { try await accounts.deleteAccount(id: "cloud") }
        XCTAssertNotNil(try f.database.read { try AccountRecord.fetchOne($0, key: "cloud") })
        let pending = try await f.records.cloudResetOperation(id: f.approval.operationID)
        XCTAssertEqual(pending.stage, .prepared)
        _ = try await ICloudCloudResetCoordinator(repository: f.records).resume(operationID: f.approval.operationID, using: cloud)
        await expectFailure { try await accounts.deleteAccount(id: "cloud") }
        let ready = try await f.records.cloudResetOperation(id: f.approval.operationID)
        XCTAssertEqual(ready.stage, .cloudReady)
        // Independent local accounts remain outside the reset operation.
        try await accounts.deleteAccount(id: "local")
        XCTAssertNil(try f.database.read { try AccountRecord.fetchOne($0, key: "local") })
    }
}
