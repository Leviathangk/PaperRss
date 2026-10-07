import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ResumeReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private actor ResumeMetadataStub: ICloudResidueMetadataReading {
    var values: [ICloudResidueMetadata]
    var fingerprint: String
    private(set) var count = 0
    var gate: ResumeReadGate?
    var hook: (@Sendable (Int) async throws -> Void)?
    init(_ values: [ICloudResidueMetadata], fingerprint: String = "original-user") {
        self.values = values; self.fingerprint = fingerprint
    }
    func metadata(for context: ICloudResidueContext) async throws -> ICloudResidueMetadata {
        count += 1
        guard fingerprint == context.systemFingerprint else { throw ICloudRecordError.accountChanged }
        if let gate { self.gate = nil; await gate.wait() }
        try await hook?(count)
        return values[min(count - 1, values.count - 1)]
    }
    func setGate(_ value: ResumeReadGate) { gate = value }
    func setHook(_ value: @escaping @Sendable (Int) async throws -> Void) { hook = value }
}

private func resumeMetadata(_ generation: String, tag: String = "tag", phase: ICloudCloudRoot.Phase = .ready,
                            zones: [CKRecordZone.ID]? = nil) throws -> ICloudResidueMetadata {
    .init(root: .found(.init(generation: generation, phase: phase), changeTag: tag),
          zones: try zones ?? ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: generation) },
          hasLegacySnapshot: false)
}

final class ICloudSameAccountResumeTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var repository: ICloudRecordRepository!
    private let account = "resume-cloud", epoch = "00000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalAccountResume-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { db in
            try AccountRecord(id: account, type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).insert(db)
            try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).insert(db)
        }
        repository = ICloudRecordRepository(database: database, accountID: account)
        try repository.activate(); try repository.bindSystemUserFingerprint("original-user")
        try database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ?, initialized_zones = 3, engine_state = ?, pause_reason = 'accountChanged' WHERE account_id = ?",
                           arguments: [epoch, Data([1, 2, 3]), account])
            try FeedRecord(id: "source-feed", accountID: account, title: "Source", feedURL: "https://private.example/rss?edition=sample", updatedAt: 1).insert(db)
            try FolderRecord(id: "source-folder", accountID: account, name: "Retained", updatedAt: 1).insert(db)
            try FeedFolderRecord(feedID: "source-feed", folderID: "source-folder").insert(db)
            try ItemRecord(id: "source-item", accountID: account, externalID: "source-item", feedID: "source-feed", createdAt: 1, updatedAt: 1, sourceItemID: "opaque-guid").insert(db)
            try ArticleRecord(itemID: "source-item", title: "Article", summary: "RSS", contentHTML: "<p>Retained RSS</p>").insert(db)
            try ArticleStateRecord(itemID: "source-item", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).insert(db)
        }
    }
    override func tearDownWithError() throws {
        repository = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func rows(includePause: Bool = true) throws -> [Row] {
        try database.read { db in
            var rows: [Row] = []
            for table in ["accounts", "feeds", "folders", "feed_folders", "items", "articles", "article_states", "icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings"] {
                rows += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            if includePause { rows += try Row.fetchAll(db, sql: "SELECT * FROM icloud_sync_scope ORDER BY rowid") }
            return rows
        }
    }
    private func coordinator(_ source: ResumeMetadataStub) -> ICloudSameAccountResumeCoordinator {
        .init(repository: repository, transport: source)
    }
    private func rejected(_ source: ResumeMetadataStub) async throws {
        let before = try rows()
        do { try await coordinator(source).resume(); XCTFail("Unsafe resume must fail") }
        catch is ICloudSameAccountResumeError {}
        catch is ICloudRootError {}
        catch is ICloudRecordError {}
        XCTAssertEqual(try rows(), before)
    }

    func testSameOriginalAccountResumesWithoutRewritingDataVersionsOrCheckpoint() async throws {
        let source = ResumeMetadataStub([try resumeMetadata(epoch)])
        let before = try rows(includePause: false)
        let scope = try database.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [account])! }
        let available = try await repository.recoveryReview()
        XCTAssertTrue(available.canResumeOriginalAccount)
        try await coordinator(source).resume()
        XCTAssertEqual(try rows(includePause: false), before)
        let after = try database.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [account])! }
        for (column, value) in scope where column != "pause_reason" { XCTAssertEqual(after[column] as DatabaseValue, value) }
        XCTAssertNil(after["pause_reason"] as String?)
        let count = await source.count; XCTAssertEqual(count, 2)
        let resumed = try await repository.recoveryReview()
        XCTAssertFalse(resumed.canResumeOriginalAccount)
    }

    func testOtherSystemAccountNeverAuthorizesUnpause() async throws {
        let source = ResumeMetadataStub([try resumeMetadata(epoch)], fingerprint: "another-user")
        try await rejected(source)
    }

    func testMissingIncompatibleResettingAndDifferentRootLeavePauseAndDataIntact() async throws {
        let ready = try resumeMetadata(epoch)
        for root in [ICloudResidueRootObservation.missing, .incompatible,
                     .found(.init(generation: epoch, phase: .resetting), changeTag: "tag"),
                     .found(.init(generation: UUID().uuidString, phase: .ready), changeTag: "tag"),
                     .found(.init(generation: epoch, phase: .ready), changeTag: "")] {
            try await rejected(ResumeMetadataStub([.init(root: root, zones: ready.zones, hasLegacySnapshot: false)]))
        }
    }

    func testMissingOtherGenerationAndForeignOwnerZonesCannotAuthorizeResume() async throws {
        let zones = try resumeMetadata(epoch).zones
        let another = try ICloudRecordZone.allCases.map { try ICloudGenerationZone.id($0, generation: UUID().uuidString) }
        let foreign = zones.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: "foreign-owner") }
        for ids in [Array(zones.prefix(1)), another, foreign] { try await rejected(ResumeMetadataStub([try resumeMetadata(epoch, zones: ids)])) }
    }

    func testRootTagOrZonesChangingBetweenObservationsRejectsResume() async throws {
        let first = try resumeMetadata(epoch)
        let extra = CKRecordZone.ID(zoneName: "unrelated-zone")
        for second in [try resumeMetadata(epoch, tag: "changed"), try resumeMetadata(epoch, zones: first.zones + [extra])] {
            try await rejected(ResumeMetadataStub([first, second]))
        }
    }

    func testOtherPauseReasonsNoScopeBindingAndResetApprovalRejectBeforeMetadata() async throws {
        for sql in ["pause_reason = 'zoneDeleted'", "pause_reason = NULL", "cloud_generation = NULL",
                    "cloud_reset_operation = X'01'", "cloud_reset_operation = 'invalid-text'", "capture_enabled = 0", "suppress_capture = 1"] {
            let original = try database.read { try Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope WHERE account_id = ?", arguments: [account])! }
            try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET \(sql) WHERE account_id = ?", arguments: [account]) }
            let source = ResumeMetadataStub([try resumeMetadata(epoch)])
            try await rejected(source)
            let count = await source.count; XCTAssertEqual(count, 0)
            try database.write { db in
                try db.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = ?, cloud_generation = ?, cloud_reset_operation = ?, capture_enabled = ?, suppress_capture = ? WHERE account_id = ?",
                    arguments: [original["pause_reason"] as DatabaseValue, original["cloud_generation"] as DatabaseValue,
                                original["cloud_reset_operation"] as DatabaseValue, original["capture_enabled"] as DatabaseValue,
                                original["suppress_capture"] as DatabaseValue, account])
            }
        }
    }

    func testDisabledAccountRejectsBeforeMetadataAndReviewIsUnavailable() async throws {
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: [account]) }
        let source = ResumeMetadataStub([try resumeMetadata(epoch)])
        try await rejected(source)
        let count = await source.count; XCTAssertEqual(count, 0)
        let review = try await repository.recoveryReview()
        XCTAssertFalse(review.canResumeOriginalAccount)
    }

    func testScopeChangingDuringMetadataCannotReleasePause() async throws {
        let source = ResumeMetadataStub([try resumeMetadata(epoch)])
        let database = self.database!, account = self.account
        await source.setHook { count in
            if count == 1 { try await database.writeAsync { try $0.execute(sql: "UPDATE icloud_sync_scope SET user_fingerprint = 'another-user' WHERE account_id = ?", arguments: [account]) } }
        }
        do { try await coordinator(source).resume(); XCTFail("Changed scope") }
        catch ICloudSameAccountResumeError.unavailableScope {}
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope WHERE account_id = ?", arguments: [account]) }, "accountChanged")
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 1)
    }

    func testCancellationDuringMetadataLeavesPauseAndDataIntact() async throws {
        let source = ResumeMetadataStub([try resumeMetadata(epoch)]), cancellation = ICloudResumeCancellation()
        await source.setHook { _ in cancellation.cancel() }
        let before = try rows()
        do { try await coordinator(source).resume(cancellation: cancellation); XCTFail("Cancelled recovery") }
        catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
    }

    func testMetadataTimeAndZoneLimitsCannotReleasePause() async throws {
        let first = try resumeMetadata(epoch)
        let slow = ResumeMetadataStub([first]); await slow.setHook { _ in try await Task.sleep(for: .milliseconds(30)) }
        var timed = coordinator(slow); timed.timeLimit = .milliseconds(10)
        let before = try rows()
        do { try await timed.resume(); XCTFail("Over-budget metadata") }
        catch ICloudSameAccountResumeError.safetyLimit {}
        XCTAssertEqual(try rows(), before)
        // The configured zone bound applies to all observed zones.
        let extra = ResumeMetadataStub([try resumeMetadata(epoch, zones: first.zones + [CKRecordZone.ID(zoneName: "extra")])])
        var limited = coordinator(extra); limited.zoneLimit = 2
        do { try await limited.resume(); XCTFail("Too many zones") }
        catch ICloudSameAccountResumeError.safetyLimit {}
        XCTAssertEqual(try rows(), before)
    }

    func testUnentitledDriverCannotResumeOrStartSDK() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled runner") }
        let before = try rows()
        do { try await ICloudSyncEngineDriver(repository: repository).resumeOriginalAccount(); XCTFail("Needs entitlement") }
        catch ICloudEngineError.notEntitled {}
        XCTAssertEqual(try rows(), before)
    }

    func testCancellationWhileWriterIsQueuedKeepsPauseAndDurableData() async throws {
        let before = try rows(), source = ResumeMetadataStub([try resumeMetadata(epoch)])
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let coordinator = coordinator(source)
        let operation = Task { try await coordinator.resume() }
        defer { operation.cancel() }
        try await Task.sleep(for: .milliseconds(40))
        operation.cancel(); release.signal(); _ = try await blocker.value
        do { try await operation.value; XCTFail("Queued cancelled recovery") }
        catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
    }

    func testRecoveryDeadlineIncludesWaitingForWriterQueue() async throws {
        let before = try rows(), source = ResumeMetadataStub([try resumeMetadata(epoch)])
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), db = database!
        let blocker = Task { try await db.writeAsync { _ in started.signal(); release.wait(); return true } }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        var limited = coordinator(source); limited.timeLimit = .milliseconds(500)
        let operation = Task { try await limited.resume() }
        defer { operation.cancel() }
        try await Task.sleep(for: .milliseconds(600))
        release.signal(); _ = try await blocker.value
        do { try await operation.value; XCTFail("Queued expired recovery") }
        catch ICloudSameAccountResumeError.safetyLimit {}
        let reads = await source.count; XCTAssertEqual(reads, 2)
        XCTAssertEqual(try rows(), before)
    }
}

private actor OriginalAccountSyncStub: ICloudAccountSyncing {
    let database: LibraryDatabase
    let source: ResumeMetadataStub
    private var events: [String] = []
    private var failFetch = false, failAnnouncement = false
    init(database: LibraryDatabase, source: ResumeMetadataStub) { self.database = database; self.source = source }
    func resumeOriginalAccount() async throws {
        events.append("resume")
        let account = try database.read { try String.fetchOne($0, sql: "SELECT id FROM accounts WHERE type = 'iCloud'")! }
        let repository = ICloudRecordRepository(database: database, accountID: account)
        try await ICloudSameAccountResumeCoordinator(repository: repository, transport: source).resume()
    }
    func fetchChanges() async throws { events.append("fetch"); if failFetch { throw URLError(.notConnectedToInternet) } }
    func sendChanges() async throws { events.append("send") }
    func localChangesAvailable() async throws {
        events.append("announce")
        if failAnnouncement { throw NSError(domain: "private-user", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-url"]) }
    }
    func stop() async { events.append("stop") }
    func snapshot() -> [String] { events }
    func clearEvents() { events = [] }
    func fail(fetch: Bool = false, announcement: Bool = false) { failFetch = fetch; failAnnouncement = announcement }
}

@MainActor
final class ICloudOriginalAccountResumeFlowTests: XCTestCase {
    private var store: AppStore!
    private var sync: OriginalAccountSyncStub!
    private var source: ResumeMetadataStub!
    private var cloud: AccountRecord!
    private let epoch = "00000000-0000-0000-0000-000000000001"
    override func setUp() async throws {
        store = AppStore(testDatabase: .empty)
        source = ResumeMetadataStub([try resumeMetadata(epoch)])
        sync = OriginalAccountSyncStub(database: store.libraryDatabase, source: source)
        cloud = try await store.createICloudAccount(fingerprint: "original-user", sync: sync)
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ?, initialized_zones = 3, pause_reason = 'accountChanged' WHERE account_id = ?",
                           arguments: [epoch, cloud.id])
            try FeedRecord(id: UUID().uuidString, accountID: cloud.id, title: "Retained", feedURL: "https://example.invalid/rss", updatedAt: 1).insert(db)
        }
        store.reloadState()
        await sync.clearEvents()
    }
    override func tearDown() async throws {
        try await store.removeAccount(accountID: cloud.id)
        let directory = URL(fileURLWithPath: store.libraryDatabase.databasePath).deletingLastPathComponent()
        cloud = nil; sync = nil; source = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func paused() throws -> Bool {
        try store.libraryDatabase.read { try String.fetchOne($0, sql: "SELECT pause_reason FROM icloud_sync_scope WHERE account_id = ?", arguments: [cloud.id]) != nil }
    }
    private func wait(_ gate: ResumeReadGate) async throws {
        for _ in 0..<100 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ResumeGateTimeout", code: 1)
    }

    func testExplicitConfirmationRestoresTargetThenAnnouncesAndKeepsProjection() async throws {
        do { _ = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: cloud.id, confirmed: false); XCTFail("Requires confirmation") }
        catch ICloudSameAccountResumeError.confirmationRequired {}
        let before = await source.count; XCTAssertEqual(before, 0); XCTAssertTrue(try paused())
        let result = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: cloud.id, confirmed: true)
        XCTAssertFalse(result.isPaused); XCTAssertNil(result.syncWarning); XCTAssertFalse(try paused())
        let events = await sync.snapshot(); XCTAssertEqual(events.suffix(3), ["resume", "fetch", "announce"])
        XCTAssertEqual(store.feeds(for: cloud.id).map(\.title), ["Retained"])
    }

    func testPostCommitFetchFailureReportsWarningAndDoesNotAnnounceOrPretendPaused() async throws {
        await sync.fail(fetch: true)
        let result = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: cloud.id, confirmed: true)
        XCTAssertFalse(result.isPaused); XCTAssertNotNil(result.syncWarning); XCTAssertFalse(try paused())
        let events = await sync.snapshot(); XCTAssertEqual(events.suffix(2), ["resume", "fetch"])
        XCTAssertFalse(events.contains("announce"))
    }

    func testAnnouncementFailureRetainsResumeAndReturnsSafeWarning() async throws {
        await sync.fail(announcement: true)
        let result = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: cloud.id, confirmed: true)
        XCTAssertFalse(result.isPaused); XCTAssertNotNil(result.syncWarning)
        XCTAssertFalse(result.syncWarning!.contains("private-user")); XCTAssertFalse(result.syncWarning!.contains("private-url"))
        XCTAssertEqual(store.feeds(for: cloud.id).count, 1)
    }

    func testPublicUnentitledResumeNeverReachesSyncOrWrites() async throws {
        guard !store.supportsICloudSync else { throw XCTSkip("Entitled runner") }
        let events = await sync.snapshot()
        do { _ = try await store.resumeOriginalICloudAccount(accountID: cloud.id, confirmed: true); XCTFail("Requires entitlement") }
        catch ICloudEngineError.notEntitled {}
        XCTAssertTrue(try paused())
        let after = await sync.snapshot(); XCTAssertEqual(after, events)
        let count = await source.count; XCTAssertEqual(count, 0)
    }

    func testBusyResumeAndCancellationPreservePause() async throws {
        let gate = ResumeReadGate(); await source.setGate(gate)
        let operation = Task { try await self.store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: self.cloud.id, confirmed: true) }
        defer { operation.cancel(); Task { await gate.open() } }
        try await wait(gate)
        do { _ = try await store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: cloud.id, confirmed: true); XCTFail("Busy recovery") }
        catch ICloudSameAccountResumeError.operationInProgress {}
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled recovery") }
        catch is CancellationError {}
        XCTAssertTrue(try paused())
        let events = await sync.snapshot(); XCTAssertFalse(events.contains("announce")); XCTAssertFalse(events.contains("fetch"))
    }

    func testAccountDisabledWhileResumingDoesNotReleasePause() async throws {
        let gate = ResumeReadGate(); await source.setGate(gate)
        let operation = Task { try await self.store.resumeOriginalICloudAccountAfterEntitlementCheck(accountID: self.cloud.id, confirmed: true) }
        defer { operation.cancel(); Task { await gate.open() } }
        try await wait(gate)
        try await store.setAccountEnabled(accountID: cloud.id, isEnabled: false)
        await gate.open()
        do { _ = try await operation.value; XCTFail("Disabled recovery") }
        catch is CancellationError {}
        catch ICloudRecordError.unavailableScope {}
        XCTAssertTrue(try paused())
        let events = await sync.snapshot(); XCTAssertFalse(events.contains("announce"))
    }
}
