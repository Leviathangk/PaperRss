import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ArchiveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private actor ArchiveCloudStub: ICloudArchiveCloudReading {
    var values: [ICloudArchiveCloudObservation]
    var gate: ArchiveGate?
    var hook: (@Sendable (Int) async throws -> Void)?
    private(set) var count = 0
    init(_ values: [ICloudArchiveCloudObservation]) { self.values = values }
    func setGate(_ gate: ArchiveGate) { self.gate = gate }
    func setHook(_ hook: @escaping @Sendable (Int) async throws -> Void) { self.hook = hook }
    func observe() async throws -> ICloudArchiveCloudObservation {
        count += 1
        if let gate { await gate.wait() }
        try await hook?(count)
        return values[min(count - 1, values.count - 1)]
    }
}

private actor ArchiveBootstrapCloud: ICloudRootTransport {
    var root: ICloudCloudRoot?
    var hasExistingData = false
    var failAfterSaving = false
    private(set) var proposals: [String] = []
    init(root: ICloudCloudRoot? = nil, hasExistingData: Bool = false, failAfterSaving: Bool = false) {
        self.root = root; self.hasExistingData = hasExistingData; self.failAfterSaving = failAfterSaving
    }
    func lookupRoot() async throws -> ICloudRootLookup {
        root.map(ICloudRootLookup.found) ?? .missing(hasExistingData: hasExistingData)
    }
    func createRoot(proposal: String) async throws -> ICloudCloudRoot {
        proposals.append(proposal)
        if root == nil { root = .init(generation: proposal, phase: .ready) }
        if failAfterSaving { failAfterSaving = false; throw ICloudEngineError.temporarilyUnavailable }
        return root!
    }
}

final class ICloudArchiveRecoveryTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private let accountID = "cloud-archive-source"
    private let oldGeneration = "00000000-0000-0000-0000-000000000001"
    private let newGeneration = "00000000-0000-0000-0000-000000000002"
    private let tables = ["feeds", "folders", "feed_folders", "items", "articles", "article_states",
                          "article_caches", "ai_artifacts", "article_state_outbox", "account_sync_state",
                          "source_language_hints", "translation_feed_lists", "translation_article_exemptions",
                          "icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperRssArchive-\(UUID().uuidString)")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { db in
            try AccountRecord(id: accountID, type: "iCloud", displayName: "Old Cloud", createdAt: 1, updatedAt: 1).insert(db)
            try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).insert(db)
        }
        let records = ICloudRecordRepository(database: database, accountID: accountID)
        try records.activate(); try records.bindSystemUserFingerprint("old-user")
        try database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'accountChanged', cloud_generation = ?, initialized_zones = 3, engine_state = ? WHERE account_id = ?",
                           arguments: [oldGeneration, Data([7, 8, 9]), accountID])
            for (id, account) in [("cloud-feed", accountID), ("local-feed", "local-default")] {
                try FeedRecord(id: id, accountID: account, title: "Feed", feedURL: "https://example.com/\(id)", updatedAt: 1).insert(db)
                for suffix in ["article", "missing", "tombstone"] {
                    let item = "\(id)-\(suffix)"
                    try ItemRecord(id: item, accountID: account, externalID: item, feedID: id, createdAt: 1, updatedAt: 1,
                                   sourceItemID: suffix == "missing" ? nil : "guid-\(item)").insert(db)
                    try ArticleStateRecord(itemID: item, isRead: true, isStarred: suffix == "article", dateArrived: 1, updatedAt: 1).insert(db)
                    if suffix != "tombstone" {
                        try ArticleRecord(itemID: item, title: "Retained", contentHTML: "<p>RSS content</p>").insert(db)
                        try ArticleCacheRecord(itemID: item, text: "Local cache", html: "<p>Cache</p>", fetchedAt: 1).insert(db)
                    }
                }
            }
            try FolderRecord(id: "cloud-folder", accountID: accountID, name: "Folder", updatedAt: 1).insert(db)
            try FeedFolderRecord(feedID: "cloud-feed", folderID: "cloud-folder").insert(db)
            for (id, account, item, subject) in [
                ("bound-ai", accountID as String?, nil as String?, "opaque"),
                ("item-ai", nil, "cloud-feed-article", "opaque"),
                ("subject-ai", nil, nil, "cloud-feed-missing"),
                ("global-ai", nil, nil, "global-memory")
            ] {
                try AIArtifactRecord(id: id, accountID: account, itemID: item, subjectKey: subject, kind: "summary",
                                     contentHash: "hash", model: "model", targetLanguage: "zh", content: "Private local AI", createdAt: 1, updatedAt: 1).insert(db)
            }
            try db.execute(sql: """
                INSERT INTO translation_feed_lists VALUES (?, 'cloud-feed', 'blacklist');
                INSERT INTO translation_article_exemptions VALUES (?, 'cloud-feed-article');
                INSERT INTO source_language_hints VALUES ('article', 'cloud-feed-article', '[]');
                INSERT INTO source_language_hints VALUES ('feed', 'cloud-feed', '[]');
                INSERT INTO source_language_hints VALUES ('folder', 'cloud-folder', '[]');
                INSERT INTO article_state_outbox(account_id,item_id,state_key,desired_value,updated_at)
                    VALUES (?, 'cloud-feed-article', 'read', 1, 1);
                INSERT INTO account_sync_state(account_id) VALUES (?);
                INSERT INTO icloud_records(account_id,zone,record_name,envelope_json) VALUES (?, 'PaperRssLibrary-v1', 'fixture', '{}');
                INSERT INTO icloud_record_mappings(account_id,kind,entity_id,record_name) VALUES (?, 'feed', 'cloud-feed', 'fixture');
                """, arguments: [accountID, accountID, accountID, accountID, accountID, accountID])
        }
    }
    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func cloud(user: String = "new-user", generation: String? = nil, tag: String = "tag", protocolVersion: Int = 2) throws -> ICloudArchiveCloudObservation {
        let generation = generation ?? newGeneration
        return .init(fingerprint: user, root: .found(.init(generation: generation, phase: .ready, protocolVersion: protocolVersion), changeTag: tag),
                     zones: try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: generation) })
    }
    private func coordinator(_ transport: ArchiveCloudStub) -> ICloudArchiveRecoveryCoordinator {
        .init(database: database, accountID: accountID, transport: transport)
    }
    private func retainedRows() throws -> [String: [Row]] {
        try database.read { db in
            try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")) })
        }
    }
    private func allRows() throws -> [String: [Row]] {
        var result = try retainedRows()
        try database.read { db in
            result["accounts"] = try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY rowid")
            result["scope"] = try Row.fetchAll(db, sql: "SELECT * FROM icloud_sync_scope ORDER BY rowid")
        }
        return result
    }
    @discardableResult private func archive() async throws -> AccountRecord {
        let coordinator = coordinator(ArchiveCloudStub([try cloud()]))
        return try await coordinator.execute(coordinator.prepare())
    }
    private func mustReject(_ source: ArchiveCloudStub) async throws {
        let before = try allRows()
        do { _ = try await coordinator(source).prepare(); XCTFail("Unsafe review must fail") }
        catch is ICloudArchiveRecoveryError {}
        catch is ICloudCloudResetError {}
        catch is ICloudRootError {}
        XCTAssertEqual(try allRows(), before)
    }

    func testMigrationAndReviewDoNotArchiveOrWriteAnything() async throws {
        let before = try allRows()
        let plan = try await coordinator(ArchiveCloudStub([try cloud()])).prepare()
        XCTAssertEqual(plan.review, .init(feeds: 1, folders: 1, articles: 2, starredArticles: 1, missingIdentities: 1, aiArtifacts: 3))
        XCTAssertEqual(try allRows(), before)
        XCTAssertTrue(try database.read { try AccountRecord.fetchAll($0).allSatisfy { !$0.isArchived } })
    }
    func testNewUserRecoveryRetainsEveryRowAndCreatesAnEmptyFreshScope() async throws {
        let rows = try retainedRows()
        let oldScope = try database.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])! }
        let fresh = try await archive()
        XCTAssertEqual(try retainedRows(), rows)
        try database.read { db in
            let old = try AccountRecord.fetchOne(db, key: accountID)!
            XCTAssertTrue(old.isArchived); XCTAssertFalse(old.isEnabled)
            XCTAssertEqual(old.displayName, "Old Cloud"); XCTAssertEqual(old.createdAt, 1)
            let after = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID])!
            for (key, value) in oldScope where !["capture_enabled", "suppress_capture"].contains(key) {
                XCTAssertEqual(after[key] as DatabaseValue, value)
            }
            XCTAssertFalse(after["capture_enabled"] as Bool); XCTAssertTrue(after["suppress_capture"] as Bool)
            let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [fresh.id])!
            XCTAssertEqual(scope["user_fingerprint"] as String, "new-user")
            XCTAssertEqual(scope["cloud_generation"] as String, newGeneration)
            XCTAssertEqual(scope["initialized_zones"] as Int, 3)
            XCTAssertEqual(scope["logical_clock"] as Int, 0)
            XCTAssertEqual(scope["root_retry_attempt"] as Int, 0)
            for key in ["engine_state", "pause_reason", "cloud_reset_operation", "cloud_generation_proposal"] {
                XCTAssertEqual(scope[key] as DatabaseValue, .null)
            }
            XCTAssertNotEqual(scope["device_id"] as String, oldScope["device_id"] as String)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds WHERE account_id = ?", arguments: [fresh.id]), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id = ?", arguments: [fresh.id]), 0)
        }
    }
    private func emptyCloud(user: String = "new-user", legacy: Bool? = false,
                            zones: [CKRecordZone.ID] = []) -> ICloudArchiveCloudObservation {
        .init(fingerprint: user, root: .missing, zones: zones, legacySnapshotExists: legacy)
    }
    func testEmptyTargetReviewRequiresItsOwnConfirmationBeforeAnyMoreReadsOrWrites() async throws {
        let source = ArchiveCloudStub([emptyCloud()]), c = coordinator(source)
        let before = try allRows(), retained = try retainedRows()
        let plan = try await c.prepare()
        XCTAssertTrue(plan.needsCloudInitialization)
        XCTAssertEqual(try allRows(), before)
        do { _ = try await c.execute(plan); XCTFail("Empty-cloud confirmation is separate") }
        catch ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired {}
        let observations = await source.count; XCTAssertEqual(observations, 2)
        XCTAssertEqual(try allRows(), before)
        let fresh = try await c.execute(plan, initializeEmptyCloudConfirmed: true)
        XCTAssertEqual(try retainedRows(), retained)
        try database.read { db in
            let scope = try Row.fetchOne(db, sql: "SELECT * FROM icloud_sync_scope WHERE account_id=?", arguments: [fresh.id])!
            XCTAssertEqual(scope["user_fingerprint"] as String, "new-user")
            XCTAssertEqual(scope["cloud_generation"] as DatabaseValue, .null)
            XCTAssertEqual(scope["initialized_zones"] as Int, 0)
            XCTAssertEqual(scope["engine_state"] as DatabaseValue, .null)
            XCTAssertEqual(scope["pause_reason"] as DatabaseValue, .null)
            let proposal: String = scope["cloud_generation_proposal"]
            XCTAssertNotNil(UUID(uuidString: proposal)); XCTAssertNotEqual(proposal, oldGeneration)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id=?", arguments: [fresh.id]), 0)
            XCTAssertTrue(try AccountRecord.fetchOne(db, key: accountID)!.isArchived)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope WHERE account_id=?", arguments: [accountID]), Data([7,8,9]))
        }
    }
    func testEmptyTargetProposalSurvivesReopenAndAmbiguousBootstrapWithoutReplayingArchive() async throws {
        let c = coordinator(ArchiveCloudStub([emptyCloud()]))
        let fresh = try await c.execute(c.prepare(), initializeEmptyCloudConfirmed: true)
        let archivedRows = try retainedRows()
        let reopened = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let records = ICloudRecordRepository(database: reopened, accountID: fresh.id)
        let proposal = try await records.proposeCloudGeneration()
        let rootCoordinator = ICloudRootCoordinator(repository: records)
        let cloud = ArchiveBootstrapCloud(failAfterSaving: true)
        do { _ = try await rootCoordinator.ensureGeneration(using: cloud); XCTFail("Ambiguous network result") }
        catch ICloudEngineError.temporarilyUnavailable {}
        let retryProposal = try await records.proposeCloudGeneration(); XCTAssertEqual(retryProposal, proposal)
        let bound = try await rootCoordinator.ensureGeneration(using: cloud); XCTAssertEqual(bound, proposal)
        let proposals = await cloud.proposals; XCTAssertEqual(proposals, [proposal])
        XCTAssertEqual(try records.boundCloudGeneration(), proposal)
        XCTAssertEqual(try retainedRows(), archivedRows)
        XCTAssertNil(try reopened.read { try String.fetchOne($0, sql: "SELECT cloud_generation_proposal FROM icloud_sync_scope WHERE account_id=?", arguments: [fresh.id]) })
    }
    func testCloudCreatedByAnotherMacAfterArchiveIsRestoredWithoutOverwritingIt() async throws {
        let c = coordinator(ArchiveCloudStub([emptyCloud()]))
        let fresh = try await c.execute(c.prepare(), initializeEmptyCloudConfirmed: true)
        let archivedRows = try retainedRows()
        let records = ICloudRecordRepository(database: database, accountID: fresh.id)
        let cloud = ArchiveBootstrapCloud(root: .init(generation: newGeneration, phase: .ready))
        let generation = try await ICloudRootCoordinator(repository: records).ensureGeneration(using: cloud)
        XCTAssertEqual(generation, newGeneration)
        let proposals = await cloud.proposals; XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(try retainedRows(), archivedRows)
    }
    func testLegacyDataAppearingBeforeBootstrapPausesOnlyTheNewScope() async throws {
        let c = coordinator(ArchiveCloudStub([emptyCloud()]))
        let fresh = try await c.execute(c.prepare(), initializeEmptyCloudConfirmed: true)
        let archivedRows = try retainedRows()
        let records = ICloudRecordRepository(database: database, accountID: fresh.id)
        let cloud = ArchiveBootstrapCloud(hasExistingData: true)
        do { _ = try await ICloudRootCoordinator(repository: records).ensureGeneration(using: cloud); XCTFail("Newly discovered legacy data") }
        catch ICloudRootError.legacyCloudRequiresReview {}
        let proposals = await cloud.proposals; XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(try retainedRows(), archivedRows)
        try database.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT pause_reason FROM icloud_sync_scope WHERE account_id=?", arguments: [fresh.id]), "legacyCloudRoot")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope WHERE account_id=?", arguments: [accountID]), oldGeneration)
        }
    }
    func testSameUserWithVerifiedMissingLibraryCanStartFreshWithoutRebindingOldScope() async throws {
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudRootMissing' WHERE account_id=?", arguments: [accountID]) }
        let c = coordinator(ArchiveCloudStub([emptyCloud(user: "old-user")]))
        let fresh = try await c.execute(c.prepare(), initializeEmptyCloudConfirmed: true)
        try database.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT user_fingerprint FROM icloud_sync_scope WHERE account_id=?", arguments: [fresh.id]), "old-user")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope WHERE account_id=?", arguments: [accountID]), oldGeneration)
        }
    }
    func testEmptyTargetRejectsUnverifiedLegacySnapshotsAndEveryOwnedDataZoneName() async throws {
        for legacy in [nil, true] as [Bool?] { try await mustReject(ArchiveCloudStub([emptyCloud(legacy: legacy)])) }
        for name in [ICloudRecordZone.library.rawValue, ICloudRecordZone.articles.rawValue + "-epoch-malformed",
                     try ICloudGenerationZone.id(.articles, generation: oldGeneration).zoneName] {
            try await mustReject(ArchiveCloudStub([emptyCloud(zones: [.init(zoneName: name)])]))
        }
        try await mustReject(ArchiveCloudStub([emptyCloud(user: "old-user")]))
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudGenerationChanged' WHERE account_id=?", arguments: [accountID]) }
        try await mustReject(ArchiveCloudStub([emptyCloud(user: "old-user")]))
    }
    func testCloudReadyResetCannotTreatAMissingReplacementRootAsEmpty() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user"))
        operation.stage = .cloudReady
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudResetReview', cloud_reset_operation=? WHERE account_id=?", arguments: [try operation.serialized(), accountID]) }
        try await mustReject(ArchiveCloudStub([emptyCloud(user: "old-user")]))
    }
    func testEmptyTargetMustStayEmptyAcrossBothObservationsAndUserConfirmation() async throws {
        let empty = emptyCloud()
        for changed in [emptyCloud(legacy: true), try cloud(), emptyCloud(user: "third-user"),
                        emptyCloud(zones: [.init(zoneName: "unrelated-zone")])] {
            try await mustReject(ArchiveCloudStub([empty, changed]))
        }
        let source = ArchiveCloudStub([empty, empty, try cloud()]), c = coordinator(source)
        let plan = try await c.prepare(), before = try allRows()
        do { _ = try await c.execute(plan, initializeEmptyCloudConfirmed: true); XCTFail("Cloud changed after review") }
        catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try allRows(), before)
    }
    func testEmptyScopeTransactionFailureRollsBackArchiveAndProposal() async throws {
        let c = coordinator(ArchiveCloudStub([emptyCloud()])), plan = try await c.prepare()
        try database.write { try $0.execute(sql: """
            CREATE TRIGGER fixture_fail_empty_scope BEFORE INSERT ON icloud_sync_scope
                WHEN NEW.account_id != 'cloud-archive-source'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """) }
        let before = try allRows()
        do { _ = try await c.execute(plan, initializeEmptyCloudConfirmed: true); XCTFail("Rollback required") }
        catch is DatabaseError {}
        XCTAssertEqual(try allRows(), before)
    }
    func testSameUserWithNewGenerationUsesFreshScope() async throws {
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'cloudGenerationChanged' WHERE account_id = ?", arguments: [accountID]) }
        let c = coordinator(ArchiveCloudStub([try cloud(user: "old-user")]))
        let fresh = try await c.execute(c.prepare())
        XCTAssertTrue(fresh.isEnabled); XCTAssertFalse(fresh.isArchived)
    }
    func testCompletedResetKeepsApprovalInArchiveWithoutReplayingIt() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user"))
        operation.stage = .cloudReady
        let data = try operation.serialized()
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'cloudResetReview', cloud_reset_operation = ? WHERE account_id = ?", arguments: [data, accountID]) }
        let c = coordinator(ArchiveCloudStub([try cloud(user: "old-user")]))
        let fresh = try await c.execute(c.prepare())
        try database.read { db in
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope WHERE account_id = ?", arguments: [accountID]), data)
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT cloud_reset_operation FROM icloud_sync_scope WHERE account_id = ?", arguments: [fresh.id]))
        }
    }

    func testCompletedPreservingV3ReplacementArchivesOldScopeAndBindsIndependentV3Scope() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user",
            previousProtocolVersion: 2, replacementProtocolVersion: 3, previousDataDisposition: .preserve))
        operation.stage = .cloudReady
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudResetReview',cloud_reset_operation=? WHERE account_id=?", arguments: [try operation.serialized(), accountID]) }
        let before = try retainedRows()
        let c = coordinator(ArchiveCloudStub([try cloud(user: "old-user", protocolVersion: 3)]))
        let fresh = try await c.execute(c.prepare())
        XCTAssertEqual(try retainedRows(), before)
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope WHERE account_id=?", arguments: [fresh.id]), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope WHERE account_id=?", arguments: [accountID]), 2)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_archived FROM accounts WHERE id=?", arguments: [accountID]), true)
        }
    }

    func testCompletedResetRejectsWrongReplacementProtocolOrOriginalBinding() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user",
            previousProtocolVersion: 2, replacementProtocolVersion: 3, previousDataDisposition: .preserve))
        operation.stage = .cloudReady
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudResetReview',cloud_reset_operation=? WHERE account_id=?", arguments: [try operation.serialized(), accountID]) }
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user", protocolVersion: 2)]))
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_protocol_version=3 WHERE account_id=?", arguments: [accountID]) }
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user", protocolVersion: 3)]))
    }

    func testPreservedPreviousStageCannotBeUsedAsCompletedArchiveApproval() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user",
            previousProtocolVersion: 2, replacementProtocolVersion: 3, previousDataDisposition: .preserve))
        operation.stage = .previousRetained
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason='cloudResetRequested',cloud_reset_operation=? WHERE account_id=?", arguments: [try operation.serialized(), accountID]) }
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user", protocolVersion: 3)]))
    }
    func testSameOriginalUserAndGenerationMustUseExistingResumePath() async throws {
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user", generation: oldGeneration)]))
    }
    func testMissingIncompatibleResettingAndUnverifiedRootsNeverArchive() async throws {
        let ready = try cloud()
        for root in [ICloudResidueRootObservation.missing, .incompatible,
                     .found(.init(generation: newGeneration, phase: .resetting), changeTag: "tag"),
                     .found(.init(generation: newGeneration, phase: .ready), changeTag: "")] {
            try await mustReject(ArchiveCloudStub([.init(fingerprint: ready.fingerprint, root: root, zones: ready.zones)]))
        }
        try await mustReject(ArchiveCloudStub([try cloud(user: "")]))
    }
    func testBothCurrentZonesAndTheirOwnerMustMatch() async throws {
        let ready = try cloud()
        let zones = ready.zones.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: "foreign-owner") }
        for invalid in [Array(ready.zones.prefix(1)), zones] {
            try await mustReject(ArchiveCloudStub([.init(fingerprint: ready.fingerprint, root: ready.root, zones: invalid)]))
        }
    }
    func testRootTagUserAndZoneChangesInvalidateReview() async throws {
        for changed in [try cloud(tag: "changed"), try cloud(user: "third-user"), try cloud(generation: UUID().uuidString)] {
            try await mustReject(ArchiveCloudStub([try cloud(), changed]))
        }
        let ready = try cloud()
        try await mustReject(ArchiveCloudStub([ready, .init(fingerprint: ready.fingerprint, root: ready.root,
            zones: ready.zones + [CKRecordZone.ID(zoneName: "other-zone")])]))
    }
    func testExecutionRevalidatesTheReviewedCloudInsteadOfAdoptingAChangedTarget() async throws {
        let source = ArchiveCloudStub([try cloud(), try cloud(), try cloud(tag: "changed")])
        let c = coordinator(source); let plan = try await c.prepare(); let before = try allRows()
        do { _ = try await c.execute(plan); XCTFail("Changed target must fail") }
        catch ICloudArchiveRecoveryError.staleReview {}
        XCTAssertEqual(try allRows(), before)
    }
    func testLocalScopeOrCountsChangedAfterReviewRejectsExecution() async throws {
        for sql in ["UPDATE icloud_sync_scope SET logical_clock = logical_clock + 1 WHERE account_id = ?",
                    "INSERT INTO folders(id,account_id,name,updated_at) VALUES ('extra', ?, 'Extra', 1)"] {
            let c = coordinator(ArchiveCloudStub([try cloud()])); let plan = try await c.prepare()
            try database.write { try $0.execute(sql: sql, arguments: [accountID]) }
            let before = try allRows()
            do { _ = try await c.execute(plan); XCTFail("Stale review must fail") }
            catch ICloudArchiveRecoveryError.staleReview {}
            XCTAssertEqual(try allRows(), before)
        }
    }
    func testDisabledCaptureSuppressionOrUnrelatedPauseFailsBeforeCloudRead() async throws {
        for sql in ["UPDATE accounts SET is_enabled = 0 WHERE id = ?",
                    "UPDATE icloud_sync_scope SET capture_enabled = 0 WHERE account_id = ?",
                    "UPDATE icloud_sync_scope SET suppress_capture = 1 WHERE account_id = ?",
                    "UPDATE icloud_sync_scope SET pause_reason = 'invalidCloudRoot' WHERE account_id = ?"] {
            try database.write { db in
                try db.execute(sql: "UPDATE accounts SET is_enabled = 1 WHERE id = ?", arguments: [accountID])
                try db.execute(sql: "UPDATE icloud_sync_scope SET capture_enabled = 1, suppress_capture = 0, pause_reason = 'accountChanged' WHERE account_id = ?", arguments: [accountID])
                try db.execute(sql: sql, arguments: [accountID])
            }
            let source = ArchiveCloudStub([try cloud()]); try await mustReject(source)
            let count = await source.count; XCTAssertEqual(count, 0)
        }
    }
    func testIncompleteDamagedOrUnrelatedResetApprovalCannotBeArchived() async throws {
        var operation = ICloudCloudResetOperation(approval: .init(operationID: UUID().uuidString,
            previousGeneration: oldGeneration, replacementGeneration: newGeneration, systemFingerprint: "old-user"))
        for stage in ICloudCloudResetOperation.Stage.allCases where stage != .cloudReady && stage != .previousRetained {
            operation.stage = stage
            try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'cloudResetRequested', cloud_reset_operation = ? WHERE account_id = ?", arguments: [try operation.serialized(), accountID]) }
            try await mustReject(ArchiveCloudStub([try cloud(user: "old-user")]))
        }
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = 'cloudResetReview', cloud_reset_operation = 'broken-text' WHERE account_id = ?", arguments: [accountID]) }
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user")]))
        operation.stage = .cloudReady
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_reset_operation = ? WHERE account_id = ?", arguments: [try operation.serialized(), accountID]) }
        try await mustReject(ArchiveCloudStub([try cloud(user: "new-user")]))
        try await mustReject(ArchiveCloudStub([try cloud(user: "old-user", generation: UUID().uuidString)]))
    }
    func testReviewIsBoundToItsDatabaseAndCanOnlyExecuteOnce() async throws {
        let c = coordinator(ArchiveCloudStub([try cloud()])); let plan = try await c.prepare()
        let other = try LibraryDatabase(databaseURL: directory.appendingPathComponent("other.sqlite"))
        let unrelated = ICloudArchiveRecoveryCoordinator(database: other, accountID: accountID, transport: ArchiveCloudStub([try cloud()]))
        do { _ = try await unrelated.execute(plan); XCTFail("Wrong database must fail") }
        catch ICloudArchiveRecoveryError.staleReview {}
        _ = try await c.execute(plan)
        let after = try allRows()
        do { _ = try await c.execute(plan); XCTFail("Consumed source must fail") }
        catch ICloudArchiveRecoveryError.unavailableSource {}
        XCTAssertEqual(try allRows(), after)
    }
    func testExpiredReviewFailsBeforeMetadataAndWrites() async throws {
        let source = ArchiveCloudStub([try cloud()]); var c = coordinator(source)
        c.reviewLifetime = .milliseconds(10)
        let plan = try await c.prepare(); let before = try allRows()
        try await Task.sleep(for: .milliseconds(25))
        do { _ = try await c.execute(plan); XCTFail("Expired review must fail") }
        catch ICloudArchiveRecoveryError.expiredReview {}
        let count = await source.count; XCTAssertEqual(count, 2)
        XCTAssertEqual(try allRows(), before)
    }
    func testCancellationWhileReadingRetainsOriginalData() async throws {
        let source = ArchiveCloudStub([try cloud()]); let gate = ArchiveGate(); await source.setGate(gate)
        let c = coordinator(source); let before = try allRows()
        let task = Task { try await c.prepare() }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(20)) }
        let entered = await gate.entered; XCTAssertTrue(entered)
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled review must fail") } catch is CancellationError {}
        XCTAssertEqual(try allRows(), before)
    }
    func testSafetyBudgetAndZoneLimitLeaveDataUnchanged() async throws {
        let ready = try cloud()
        let source = ArchiveCloudStub([.init(fingerprint: ready.fingerprint, root: ready.root,
            zones: ready.zones + [CKRecordZone.ID(zoneName: "extra")])])
        var c = coordinator(source); c.zoneLimit = 2
        let before = try allRows()
        do { _ = try await c.prepare(); XCTFail("Zone limit must fail") } catch ICloudArchiveRecoveryError.safetyLimit {}
        c.timeLimit = .zero
        do { _ = try await c.prepare(); XCTFail("Time limit must fail") } catch ICloudArchiveRecoveryError.safetyLimit {}
        XCTAssertEqual(try allRows(), before)
    }
    func testNewScopeFailureRollsBackArchiveAndPreservesEvidence() async throws {
        let c = coordinator(ArchiveCloudStub([try cloud()])); let plan = try await c.prepare()
        try database.write { try $0.execute(sql: """
            CREATE TRIGGER fixture_fail_new_scope BEFORE INSERT ON icloud_sync_scope
                WHEN NEW.account_id != 'cloud-archive-source'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """) }
        let before = try allRows()
        do { _ = try await c.execute(plan); XCTFail("Failure must roll back") } catch is DatabaseError {}
        XCTAssertEqual(try allRows(), before)
    }
    func testCancellationWhileArchiveWriterIsQueuedRollsBackEverything() async throws {
        let source = ArchiveCloudStub([try cloud()]); let c = coordinator(source); let plan = try await c.prepare()
        let before = try allRows(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let operation = Task { try await c.execute(plan) }; defer { operation.cancel() }
        for _ in 0..<100 { if await source.count == 4 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let reads = await source.count; XCTAssertEqual(reads, 4)
        operation.cancel(); release.signal(); _ = try await blocker.value
        do { _ = try await operation.value; XCTFail("Queued cancellation must roll back") } catch is CancellationError {}
        XCTAssertEqual(try allRows(), before)
    }
    func testArchiveBudgetIncludesWaitingForTheWriterQueue() async throws {
        let source = ArchiveCloudStub([try cloud()]); var c = coordinator(source); let plan = try await c.prepare()
        c.timeLimit = .milliseconds(500)
        let before = try allRows(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let limited = c
        let operation = Task { try await limited.execute(plan) }; defer { operation.cancel() }
        try await Task.sleep(for: .milliseconds(600))
        release.signal(); _ = try await blocker.value
        do { _ = try await operation.value; XCTFail("Queued deadline must roll back") } catch ICloudArchiveRecoveryError.safetyLimit {}
        let reads = await source.count; XCTAssertEqual(reads, 4)
        XCTAssertEqual(try allRows(), before)
    }
    func testConcurrentExecutionsCreateOnlyOneFreshAccount() async throws {
        let c = coordinator(ArchiveCloudStub([try cloud()])); let plan = try await c.prepare()
        let a = Task { try await c.execute(plan) }, b = Task { try await c.execute(plan) }
        var succeeded = 0
        for task in [a, b] {
            do { _ = try await task.value; succeeded += 1 }
            catch ICloudArchiveRecoveryError.unavailableSource {}
            catch ICloudArchiveRecoveryError.staleReview {}
        }
        XCTAssertEqual(succeeded, 1)
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE type='iCloud' AND is_archived=0"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE is_archived=1"), 1)
        }
    }
    func testArchiveCannotBeEnabledRemovedUnarchivedOrReplaced() async throws {
        _ = try await archive(); let before = try allRows()
        let accounts = AccountRepository(database: database)
        do { try await accounts.updateAccountEnabled(id: accountID, isEnabled: true); XCTFail("Archive cannot be enabled") }
        catch ICloudArchiveRecoveryError.readonlyArchive {}
        do { try await accounts.deleteAccount(id: accountID); XCTFail("Archive cannot be removed") }
        catch ICloudArchiveRecoveryError.readonlyArchive {}
        for sql in ["UPDATE accounts SET is_archived = 0 WHERE id = ?", "UPDATE accounts SET display_name = 'Changed' WHERE id = ?",
                    "DELETE FROM accounts WHERE id = ?",
                    "INSERT OR REPLACE INTO accounts(id,type,display_name,created_at,updated_at) VALUES (?, 'local', 'Overwrite', 1, 1)"] {
            XCTAssertThrowsError(try database.write { try $0.execute(sql: sql, arguments: [accountID]) })
        }
        XCTAssertEqual(try allRows(), before)
    }
    func testEveryArchivedEntityRejectsUpdateAndDeleteIncludingLateCloudCallbacks() async throws {
        _ = try await archive(); let before = try allRows()
        let targets = ["feeds": "title", "folders": "name", "feed_folders": "feed_id", "items": "source_item_id",
            "articles": "content_html", "article_states": "is_read", "article_caches": "text", "ai_artifacts": "content",
            "article_state_outbox": "attempt_count", "account_sync_state": "last_error", "source_language_hints": "hints_json",
            "translation_feed_lists": "list", "translation_article_exemptions": "item_id", "icloud_sync_scope": "engine_state",
            "icloud_sync_changes": "is_pending", "icloud_content_changes": "is_pending", "icloud_records": "needs_apply", "icloud_record_mappings": "record_name"]
        for (table, column) in targets {
            XCTAssertThrowsError(try database.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = \(column)") }, table)
            XCTAssertThrowsError(try database.write { try $0.execute(sql: "DELETE FROM \(table)") }, table)
        }
        XCTAssertEqual(try allRows(), before)
    }
    func testInsertRekeyAndReplaceCannotOverwriteOrMoveArchiveAcrossAccounts() async throws {
        let fresh = try await archive(); let before = try allRows()
        let commands: [(String, StatementArguments)] = [
            ("INSERT OR REPLACE INTO items(id,account_id,external_id,feed_id,created_at,updated_at) VALUES ('cloud-feed-article', ?, 'replacement', 'local-feed', 1, 1)", [fresh.id]),
            ("INSERT OR REPLACE INTO feeds(id,account_id,title,feed_url,updated_at) VALUES ('cloud-feed', 'local-default', 'Changed', 'https://example.com/replaced', 1)", []),
            ("UPDATE items SET account_id = ? WHERE id = 'cloud-feed-article'", [fresh.id]),
            ("UPDATE feeds SET account_id = ? WHERE id = 'cloud-feed'", [fresh.id]),
            ("INSERT INTO article_states(item_id,date_arrived,updated_at) VALUES ('cloud-feed-article', 1, 1) ON CONFLICT(item_id) DO UPDATE SET is_read = 0", []),
            ("INSERT INTO ai_artifacts(id,subject_key,kind,content_hash,model,target_language,created_at,updated_at) VALUES ('new-ai','cloud-feed-article','summary','h','m','zh',1,1)", [])
        ]
        for (sql, arguments) in commands {
            XCTAssertThrowsError(try database.write { db in
                try db.execute(sql: "PRAGMA recursive_triggers = OFF")
                try db.execute(sql: sql, arguments: arguments)
            })
        }
        XCTAssertEqual(try allRows(), before)
    }
    func testOrdinaryCleanupKeepsArchiveAndStillCleansActiveLocalData() async throws {
        _ = try await archive()
        let cache = CacheRepository(database: database)
        let cleared = try database.write { try cache.deleteAllCaches(in: $0) }; XCTAssertEqual(cleared, 2)
        let articles = ArticleRepository(database: database)
        let purged = try database.write { try articles.purgeOldReadArticles(cutoffDate: .now, in: $0) }; XCTAssertEqual(purged, 1)
        let tombstones = try database.write { try articles.purgeExpiredTombstones(cutoffDate: .now, in: $0) }; XCTAssertEqual(tombstones, 2)
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE account_id = ?", arguments: [accountID]), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_caches WHERE item_id LIKE 'cloud-%'"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articles a JOIN items i ON a.item_id=i.id WHERE i.account_id=?", arguments: [accountID]), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_artifacts"), 4)
        }
        let storage = try database.storageStats(cutoffDate: .now)
        XCTAssertEqual(storage.prunableArticlesCount, 0)
    }
    func testArchiveExcludedFromNormalCountsButExplicitLocalReadIsAvailable() async throws {
        _ = try await archive()
        let timeline = TimelineQueryService(database: database)
        let global = try timeline.fetchSidebarCounts(startOfDayTimestamp: 0)
        XCTAssertEqual(global.starred, 1)
        let archive = try timeline.fetchSidebarCounts(accountID: accountID, startOfDayTimestamp: 0)
        XCTAssertEqual(archive.starred, 1)
        XCTAssertNotNil(try database.read { try ArticleRecord.fetchOne($0, key: "cloud-feed-article") })
        XCTAssertNotNil(try database.read { try AIArtifactRecord.fetchOne($0, key: "subject-ai") })
    }
    func testActiveLocalDataAndGlobalAIMemoryRemainEditable() async throws {
        _ = try await archive()
        try database.write { db in
            try db.execute(sql: "UPDATE article_states SET is_read = 0 WHERE item_id = 'local-feed-article'")
            try db.execute(sql: "UPDATE feeds SET title = 'Local changed' WHERE id = 'local-feed'")
            try db.execute(sql: "UPDATE ai_artifacts SET content = 'Global changed' WHERE id = 'global-ai'")
        }
    }
    func testInvalidArchiveFlagsAndUnsuspendedTransitionsAreRejected() throws {
        for sql in ["UPDATE accounts SET is_enabled=0, is_archived=1 WHERE id='local-default'",
                    "UPDATE accounts SET is_archived=1 WHERE id='cloud-archive-source'",
                    "UPDATE accounts SET is_enabled=0, is_archived=1 WHERE id='cloud-archive-source'",
                    "UPDATE accounts SET is_archived=2 WHERE id='cloud-archive-source'"] {
            XCTAssertThrowsError(try database.write { try $0.execute(sql: sql) })
        }
    }
    func testV19UpgradePreservesAllRowsWithoutCreatingArchives() throws {
        let url = directory.appendingPathComponent("v19.sqlite")
        let pool = try DatabasePool(path: url.path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v19-icloud-approved-cloud-reset")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO accounts(id,type,display_name,is_enabled,created_at,updated_at) VALUES ('legacy-cloud','iCloud','Legacy',1,1,1)")
            try db.execute(sql: "INSERT INTO icloud_sync_scope(account_id,capture_enabled,user_fingerprint,cloud_generation,engine_state,pause_reason) VALUES ('legacy-cloud',1,'legacy-user',?,?, 'accountChanged')", arguments: [oldGeneration, Data([2, 4, 6])])
        }
        let scope = try pool.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope")! }
        let legacy = try pool.read { try AccountRecord.fetchOne($0, key: "legacy-cloud")! }
        XCTAssertFalse(legacy.isArchived)
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            let columns = scope.columnNames.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ", ")
            XCTAssertEqual(try Row.fetchOne(db, sql: "SELECT \(columns) FROM icloud_sync_scope"), scope)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT cloud_protocol_version FROM icloud_sync_scope"), 2)
            XCTAssertEqual(try AccountRecord.fetchOne(db, key: "legacy-cloud"), legacy)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
