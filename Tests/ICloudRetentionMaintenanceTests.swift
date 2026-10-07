@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private struct MaintenanceFixture: Sendable {
    let directory: URL
    let database: LibraryDatabase
    let repository: ICloudRecordRepository
    let approval: ICloudRetentionApproval
    let snapshot: ICloudRetentionPointSnapshot
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    static let feedURL = "https://fixture.example/rss"
    static let source = "urn:fixture:maintenance"

    init(version: Int = 3) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Maintenance-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { db in
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: "local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
        }
        repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate(); try repository.bindSystemUserFingerprint("fixture-user")
        try await repository.acceptCloudRoot(.init(generation: Self.generation, phase: .ready, protocolVersion: version))
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET initialized_zones=3,settings_pending=0,logical_clock=50 WHERE account_id='cloud'") }
        let article = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: Self.feedURL)!, sourceItemID: Self.source))
        approval = .init(approvalID: UUID().uuidString, generation: Self.generation, systemFingerprint: "fixture-user",
                         articleRecordNames: [article], retentionDays: 183, weeklyRecordLimit: 400, allowsClockMaintenance: true)
        let hash = article.dropFirst("article-v1:".count)
        let value = ICloudFieldVersion(counter: 10, deviceID: Self.device)
        let read = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + hash, feedURL: Self.feedURL, sourceItemID: Self.source,
                                           fields: ["value": .init(value: .flag(true), version: value)])
        let star = try ICloudRecordEnvelope(kind: .starred, recordName: "starred-v1:" + hash, feedURL: Self.feedURL, sourceItemID: Self.source,
                                           fields: ["value": .init(value: .flag(false), version: value)])
        let fence = try ICloudRetentionFence(generation: Self.generation, article: read).envelope().stampedRetentionSave()
        let policy = try ICloudRetentionUnreadPolicy(generation: Self.generation, releasedVersion: .bootstrap).envelope().stampedRetentionSave()
        let quota = try ICloudRetentionQuota().envelope(version: .init(counter: 30, deviceID: Self.device))
        let records = Dictionary(uniqueKeysWithValues: [read, star, fence, policy, quota].map { envelope in
            let date = [.read, .starred].contains(envelope.kind) ? Self.now.addingTimeInterval(-184 * 86_400) : Self.now
            return (envelope.recordName, ICloudCloudRecordMetadata(envelope: envelope, creationDate: date, modificationDate: date,
                                                                 systemFields: Data([1]), changeTag: "fixture-tag"))
        })
        let names = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: article)
        snapshot = .init(generation: Self.generation, requestedNames: names, records: records, missingNames: names.subtracting(records.keys))
    }
    func close() throws { try FileManager.default.removeItem(at: directory) }
    func approveMaintenance() async throws -> ICloudRetentionMaintenanceState {
        let reviewer = ICloudRetentionMaintenanceReviewer(repository: repository)
        let review = try await reviewer.prepare()
        return try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true)
    }
    func child(_ state: ICloudRetentionMaintenanceState) async throws -> ICloudRetentionJob {
        try await repository.beginRetentionJob(state.approval.childApproval(names: approval.articleRecordNames))
    }
    func submission(job: ICloudRetentionJob, needsReview: Bool = false) async throws -> (ICloudRetentionJob, ICloudRetentionAtomicBatch) {
        let attempt = job.nextAttempt!
        guard case .prepared(let batch) = try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: snapshot,
            articleRecordName: attempt.articleRecordName, protection: .init(recordNames: [], hasUnresolvedChanges: false),
            operationID: attempt.operationID, observedClock: 50, deviceID: Self.device) else { throw ICloudRetentionError.malformedSnapshot }
        var next = job
        next.attempts[0].stage = .submitted; next.attempts[0].proposalDigest = batch.proposalDigest
        next.attempts[0].processedRecords = batch.processedRecordCount
        next = try await repository.storeRetentionJob(next, replacing: job)
        if needsReview {
            var changed = next; changed.attempts[0].stage = .needsReview
            next = try await repository.storeRetentionJob(changed, replacing: next)
        }
        return (next, batch)
    }
    func committed(_ batch: ICloudRetentionAtomicBatch) -> ICloudRetentionPointSnapshot {
        var records = snapshot.records
        for name in batch.recordNamesToDelete { records.removeValue(forKey: name) }
        for save in batch.recordsToSave {
            records[save.envelope.recordName] = .init(envelope: save.envelope, creationDate: Self.now, modificationDate: Self.now,
                                                     systemFields: Data([1]), changeTag: "commit-tag")
        }
        return .init(generation: Self.generation, requestedNames: snapshot.requestedNames, records: records,
                     missingNames: snapshot.requestedNames.subtracting(records.keys))
    }
}

private actor MaintenanceCloud: ICloudInventoryPageFetching, ICloudRetentionExecutionTransport, ICloudRetentionOutcomeReading {
    var snapshot: ICloudRetentionPointSnapshot
    private var queries = 0, clocks = 0, reads = 0, submits = 0
    private var onQuery: (@Sendable () async throws -> Void)?
    private var onRead: (@Sendable () async throws -> Void)?
    private var onSubmit: (@Sendable () async throws -> Void)?
    private var queryError: CKError?
    init(_ snapshot: ICloudRetentionPointSnapshot) { self.snapshot = snapshot }
    func queried(_ action: @escaping @Sendable () async throws -> Void) { onQuery = action }
    func fetched(_ action: @escaping @Sendable () async throws -> Void) { onRead = action }
    func submitted(_ action: @escaping @Sendable () async throws -> Void) { onSubmit = action }
    func failQuery(_ error: CKError) { queryError = error }
    func counts() -> (queries: Int, clocks: Int, reads: Int, submits: Int) { (queries, clocks, reads, submits) }
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        queries += 1; try await onQuery?()
        if let queryError { throw queryError }
        return .init(records: Array(snapshot.records.values), cursor: nil, envelopeBytes: 1_000)
    }
    func prepareServerClock() async throws { clocks += 1 }
    func fetch(articleRecordName: String) async throws -> ICloudRetentionPointSnapshot {
        reads += 1; try await onRead?(); return snapshot
    }
    func fetch(attempt: ICloudRetentionJob.Attempt) async throws -> ICloudRetentionPointSnapshot {
        reads += 1; try await onRead?(); return snapshot
    }
    func submit(_ batch: ICloudRetentionAtomicBatch) async throws -> [ICloudReceivedRecord] {
        submits += 1
        var records = snapshot.records
        for name in batch.recordNamesToDelete { records.removeValue(forKey: name) }
        for save in batch.recordsToSave {
            records[save.envelope.recordName] = .init(envelope: save.envelope, creationDate: MaintenanceFixture.now,
                modificationDate: MaintenanceFixture.now, systemFields: Data([1]), changeTag: "commit-tag")
        }
        snapshot = .init(generation: snapshot.generation, requestedNames: snapshot.requestedNames, records: records,
                         missingNames: snapshot.requestedNames.subtracting(records.keys))
        try await onSubmit?()
        return batch.recordsToSave.map { .init(envelope: $0.envelope, systemFields: Data([1])) }
    }
}

private actor MaintenanceGate {
    var waiting = false
    var durations: [Duration] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(_ duration: Duration = .zero) async {
        waiting = true; durations.append(duration)
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func isWaiting() -> Bool { waiting }
    func captured() -> [Duration] { durations }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class MaintenanceTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Duration.zero
    func read() -> Duration { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value += .seconds(600) }
}

private actor MaintenanceProviderSource: ICloudAccountSyncing {
    nonisolated var supportsAutomaticSync: Bool { true }
    let cloud: MaintenanceCloud
    init(_ cloud: MaintenanceCloud) { self.cloud = cloud }
    func fetchChanges() async throws {}
    func sendChanges() async throws {}
    func stop() async {}
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        try await cloud.inventoryPage(zone: zone, cursor: cursor, limit: limit)
    }
}

private actor MaintenanceMissingOutcomeReader: ICloudRetentionOutcomeReading {
    let quota: ICloudCloudRecordMetadata
    private var operations: [String] = []
    init(_ quota: ICloudCloudRecordMetadata) { self.quota = quota }
    func fetch(attempt: ICloudRetentionJob.Attempt) async throws -> ICloudRetentionPointSnapshot {
        operations.append(attempt.operationID)
        let requested = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: attempt.articleRecordName)
        return .init(generation: MaintenanceFixture.generation, requestedNames: requested,
                     records: [quota.envelope.recordName: quota], missingNames: requested.subtracting([quota.envelope.recordName]))
    }
    func captured() -> [String] { operations }
}

final class ICloudRetentionMaintenanceTests: XCTestCase {
    private func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<3_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Fixture did not reach its expected boundary")
    }

    func testV22MigrationPreservesFiniteJobWaitAndFrozenArchiveWithoutFutureConsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaintenanceMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v22-icloud-approved-retention-job")
        let approval = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: MaintenanceFixture.generation,
            systemFingerprint: "fixture-user", articleRecordNames: ["article-v1:" + String(repeating: "a", count: 64)],
            retentionDays: 183, weeklyRecordLimit: 400, allowsClockMaintenance: true)
        let jobData = try ICloudRetentionJob(approval: approval).serialized()
        try pool.write { db in
            try AccountRecord(id: "old", type: "iCloud", displayName: "Archive", createdAt: 1, updatedAt: 1).save(db)
            try db.execute(sql: "INSERT INTO icloud_sync_scope(account_id,capture_enabled,suppress_capture,pause_reason,engine_state) VALUES('old',0,1,'accountChanged',?)", arguments: [Data([1, 2, 3])])
            try FeedRecord(id: "feed", accountID: "old", title: "Old", feedURL: MaintenanceFixture.feedURL, updatedAt: 1).save(db)
            try ItemRecord(id: "item", accountID: "old", externalID: "item", feedID: "feed", createdAt: 1, updatedAt: 1, sourceItemID: MaintenanceFixture.source).save(db)
            try ArticleRecord(itemID: "item", title: "Original", contentHTML: "<p>Archived body</p>", contentUpdatedAt: 1).save(db)
            try ArticleStateRecord(itemID: "item", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: "UPDATE accounts SET is_enabled=0,is_archived=1 WHERE id='old'")
            try AccountRecord(id: "cloud", type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save(db)
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope(account_id,capture_enabled,initialized_zones,cloud_generation,cloud_protocol_version,
                    user_fingerprint,retention_job,retention_schedule_enabled,retention_wake_at,retention_wake_delay,
                    retention_wake_attempt,retention_wake_revision)
                VALUES('cloud',0,3,?,3,'fixture-user',?,1,?,1800,2,7)
                """, arguments: [MaintenanceFixture.generation, jobData, MaintenanceFixture.now.timeIntervalSince1970 + 1_800])
        }
        let scopes = try pool.read { try Row.fetchAll($0, sql: "SELECT * FROM icloud_sync_scope ORDER BY account_id") }
        let body = try pool.read { try ArticleRecord.fetchOne($0, key: "item") }
        let state = try pool.read { try ArticleStateRecord.fetchOne($0, key: "item") }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            let columns = scopes[0].columnNames.map { "\"" + $0 + "\"" }.joined(separator: ",")
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT \(columns) FROM icloud_sync_scope ORDER BY account_id"), scopes)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE retention_maintenance IS NOT NULL"), 0)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT retention_job FROM icloud_sync_scope WHERE account_id='cloud'"), jobData)
            XCTAssertEqual(try ArticleRecord.fetchOne(db, key: "item"), body)
            XCTAssertEqual(try ArticleStateRecord.fetchOne(db, key: "item"), state)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET retention_maintenance=? WHERE account_id='old'", arguments: [Data([1])]) })
    }

    func testExistingScopeAndFiniteApprovalDoNotEnableFutureMaintenance() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        _ = try await f.repository.beginRetentionJob(f.approval)
        let context = try await f.repository.retentionMaintenanceContext()
        XCTAssertNil(context.state)
        XCTAssertNil(try f.database.read { try Data.fetchOne($0, sql: "SELECT retention_maintenance FROM icloud_sync_scope") })
        let oldData = try ICloudRetentionJob(approval: f.approval).serialized()
        XCTAssertEqual(try ICloudRetentionJob.decode(oldData).approval, f.approval)
        let json = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        XCTAssertNil((json["approval"] as! [String: Any])["maintenanceApprovalID"])
    }

    func testThreeIndependentConfirmationsAndProtocolThreeAreRequired() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let reviewer = ICloudRetentionMaintenanceReviewer(repository: f.repository)
        let review = try await reviewer.prepare()
        for mask in 0..<7 {
            do {
                _ = try await reviewer.approve(id: review.id, cleanupConfirmed: mask & 1 != 0,
                    futureArticlesConfirmed: mask & 2 != 0, clockMaintenanceConfirmed: mask & 4 != 0)
                XCTFail("Missing consent must not persist")
            } catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .confirmationRequired) }
            let context = try await f.repository.retentionMaintenanceContext(); XCTAssertNil(context.state)
        }
        let state = try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true)
        XCTAssertTrue(state.schedule.enabled); XCTAssertTrue(state.approval.allowsFutureArticles)
        let legacy = try await MaintenanceFixture(version: 2); defer { try? legacy.close() }
        do { _ = try await ICloudRetentionMaintenanceReviewer(repository: legacy.repository).prepare(); XCTFail("No implicit upgrade") }
        catch { XCTAssertEqual(error as? ICloudRetentionJobError, .approvalMismatch) }
    }

    func testStrictWhitelistRejectsPrivateFieldsFalsePermissionsAndNullParent() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance()
        XCTAssertEqual(try ICloudRetentionMaintenanceState.decode(state.serialized()), state)
        for change in ["feedURL", "allowsFutureArticles"] {
            var json = try JSONSerialization.jsonObject(with: state.serialized()) as! [String: Any]
            var approval = json["approval"] as! [String: Any]
            if change == "feedURL" { approval[change] = "private://credential" }
            else { approval[change] = false }
            json["approval"] = approval
            XCTAssertThrowsError(try ICloudRetentionMaintenanceState.decode(JSONSerialization.data(withJSONObject: json)))
        }
        var json = try JSONSerialization.jsonObject(with: ICloudRetentionJob(approval: f.approval).serialized()) as! [String: Any]
        var approval = json["approval"] as! [String: Any]; approval["maintenanceApprovalID"] = NSNull(); json["approval"] = approval
        XCTAssertThrowsError(try ICloudRetentionJob.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testDisabledParentKeepsOriginalChildAndRejectsExecution() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), job = try await f.child(state)
        _ = try await f.repository.setRetentionScheduleEnabled(true, approvalID: job.approval.approvalID)
        try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        do { _ = try await f.repository.retentionJob(approvalID: job.approval.approvalID); XCTFail("Revoked child cannot execute") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .disabled) }
        let preserved = try await f.repository.retentionJob(approvalID: job.approval.approvalID, requiresExecutionAuthorization: false)
        XCTAssertEqual(preserved, job)
        let schedule = try await f.repository.retentionScheduleState(approvalID: job.approval.approvalID)
        XCTAssertFalse(schedule.enabled)
        XCTAssertEqual(try f.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE account_id='local'") }, 0)
    }

    func testReapprovalKeepsParentChildAndRetryWait() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), job = try await f.child(state)
        let waiting = try await f.repository.scheduleMaintenanceWake(approvalID: state.approval.approvalID,
            for: CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 7_200.0]), now: MaintenanceFixture.now)
        XCTAssertEqual(waiting.schedule.minimumWait, 7_200)
        try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        let reviewer = ICloudRetentionMaintenanceReviewer(repository: f.repository), review = try await reviewer.prepare()
        XCTAssertTrue(review.resumesExistingApproval)
        let resumed = try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true)
        XCTAssertEqual(resumed.approval, state.approval)
        XCTAssertEqual(resumed.schedule.deadline, waiting.schedule.deadline)
        XCTAssertEqual(resumed.schedule.minimumWait, waiting.schedule.minimumWait)
        let original = try await f.repository.retentionJob(approvalID: job.approval.approvalID)
        XCTAssertEqual(original, job)
        let schedule = try await f.repository.retentionScheduleState(approvalID: job.approval.approvalID); XCTAssertTrue(schedule.enabled)
    }

    func testFiniteApprovalCannotBeConvertedOrCompeteWithMaintenance() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        _ = try await f.repository.beginRetentionJob(f.approval)
        do { _ = try await f.approveMaintenance(); XCTFail("Finite job does not grant future consent") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .existingJob) }
        let clean = try await MaintenanceFixture(); defer { try? clean.close() }
        _ = try await clean.approveMaintenance()
        do { _ = try await clean.repository.beginRetentionJob(clean.approval); XCTFail("Separate approval must not overwrite a parent") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .existingJob) }
    }

    func testExpiredDiscardedAndChangedReviewsCannotEnableMaintenance() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let time = MaintenanceTime()
        let reviewer = ICloudRetentionMaintenanceReviewer(repository: f.repository, uptime: { time.read() })
        var review = try await reviewer.prepare(); time.advance()
        do { _ = try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .staleReview) }
        review = try await reviewer.prepare(); await reviewer.discard(id: review.id)
        do { _ = try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Discarded") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .staleReview) }
        review = try await reviewer.prepare(); _ = try await f.repository.beginRetentionJob(f.approval)
        do { _ = try await reviewer.approve(id: review.id, cleanupConfirmed: true, futureArticlesConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Changed") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .staleReview) }
    }

    func testRevocationDuringPointReadPreventsCloudSubmission() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), job = try await f.child(state), cloud = MaintenanceCloud(f.snapshot)
        await cloud.fetched { try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID) }
        do { _ = try await ICloudRetentionCoordinator(repository: f.repository).executeNext(approvalID: job.approval.approvalID, using: cloud); XCTFail("Revoked during fetch") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .disabled) }
        let counts = await cloud.counts(); XCTAssertEqual(counts.submits, 0)
        let retained = try await f.repository.retentionJob(approvalID: job.approval.approvalID, requiresExecutionAuthorization: false)
        XCTAssertEqual(retained, job)
    }

    func testRevocationAfterCommitPreservesOriginalAttemptForReadOnlyRecovery() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), job = try await f.child(state), cloud = MaintenanceCloud(f.snapshot)
        await cloud.submitted { try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID) }
        do { _ = try await ICloudRetentionCoordinator(repository: f.repository).executeNext(approvalID: job.approval.approvalID, using: cloud); XCTFail("Stopped during commit") }
        catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .disabled) }
        let unknown = try await f.repository.retentionJob(approvalID: job.approval.approvalID, requiresExecutionAuthorization: false)
        XCTAssertEqual(unknown.attempts[0].stage, .submitted)
        let result = try await ICloudRetentionOutcomeReviewer(repository: f.repository).review(approvalID: job.approval.approvalID, using: cloud)
        XCTAssertEqual(result.confirmedOperations, 1)
        let counts = await cloud.counts(); XCTAssertEqual(counts.submits, 1); XCTAssertEqual(counts.clocks, 1)
        let recovered = try await f.repository.retentionJob(approvalID: job.approval.approvalID, requiresExecutionAuthorization: false)
        XCTAssertEqual(recovered.attempts[0].operationID, unknown.attempts[0].operationID)
        XCTAssertEqual(recovered.attempts[0].proposalDigest, unknown.attempts[0].proposalDigest)
        XCTAssertEqual(recovered.attempts[0].stage, .accepted)
        let context = try await f.repository.retentionMaintenanceContext(); XCTAssertFalse(context.state!.schedule.enabled)
    }

    func testNoAuthorizationMakesNoDiscoveryRequestOrJob() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let cloud = MaintenanceCloud(f.snapshot)
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud)
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("No approval") })
        let counts = await cloud.counts(); XCTAssertEqual(counts.queries, 0)
        let context = try await f.repository.retentionMaintenanceContext(); XCTAssertNil(context.scope.job)
    }

    func testAuthorizedDiscoveryCreatesBoundFiniteChildWithoutResettingQuota() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), cloud = MaintenanceCloud(f.snapshot)
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud, now: { MaintenanceFixture.now })
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { job in
            XCTAssertEqual(job.approval.maintenanceApprovalID, state.approval.approvalID)
            XCTAssertEqual(job.approval.articleRecordNames, f.approval.articleRecordNames)
            try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        })
        try await waitUntil { (try? await f.repository.retentionMaintenanceContext().scope.job) != nil }
        await scheduler.suspend(waitForRequests: true)
        let context = try await f.repository.retentionMaintenanceContext()
        XCTAssertEqual(context.scope.job?.attempts.first?.stage, .pending)
        let counts = await cloud.counts(); XCTAssertEqual(counts.submits, 0); XCTAssertEqual(counts.clocks, 0)
        let quotaRecord = await cloud.snapshot.records[ICloudRetentionQuota.recordName]!.envelope
        XCTAssertEqual(try ICloudRetentionQuota(envelope: quotaRecord).reservations.count, 0)
    }

    func testStopDuringQueryCannotCreateLateChildOrDuplicateRunningQuery() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        await cloud.queried { await gate.wait() }
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud)
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Late approval") })
        try await waitUntil { await gate.isWaiting() }
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Duplicate") })
        try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        await scheduler.suspend(); await gate.release(); await scheduler.suspend(waitForRequests: true)
        let counts = await cloud.counts(); XCTAssertEqual(counts.queries, 1)
        let context = try await f.repository.retentionMaintenanceContext(); XCTAssertNil(context.scope.job)
    }

    func testServerRetryWaitPersistsAndForegroundCannotReplaceIt() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        _ = try await f.approveMaintenance()
        let cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        await cloud.failQuery(CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 1_800.0]))
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud,
            now: { MaintenanceFixture.now }, sleep: { await gate.wait($0) })
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Failed discovery") })
        try await waitUntil { await gate.isWaiting() }
        let context = try await f.repository.retentionMaintenanceContext(), wait = try context.state!.schedule.coldWait(now: .distantFuture)
        XCTAssertEqual(wait, 1_800)
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Bypassed retry") })
        let durations = await gate.captured(); XCTAssertEqual(durations, [.seconds(1_800)])
        await scheduler.suspend(); await gate.release(); await scheduler.suspend(waitForRequests: true)
        let counts = await cloud.counts(); XCTAssertEqual(counts.queries, 1)
    }

    func testReenabledMaintenanceResumesOnlyAfterCancelledQueryDrains() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        await cloud.queried { await gate.wait() }
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud)
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Stopped query cannot launch") })
        try await waitUntil { await gate.isWaiting() }
        try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        await scheduler.suspend()
        _ = try await f.approveMaintenance()
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in
            try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        })
        var counts = await cloud.counts(); XCTAssertEqual(counts.queries, 1)
        var context = try await f.repository.retentionMaintenanceContext(); XCTAssertNil(context.scope.job)
        await gate.release()
        try await waitUntil { (try? await f.repository.retentionMaintenanceContext().scope.job) != nil }
        await scheduler.suspend(waitForRequests: true)
        counts = await cloud.counts(); XCTAssertEqual(counts.queries, 2)
        context = try await f.repository.retentionMaintenanceContext()
        XCTAssertEqual(context.state?.approval.approvalID, state.approval.approvalID)
        XCTAssertEqual(context.scope.job?.approval.maintenanceApprovalID, state.approval.approvalID)
    }

    func testStoppingQueuedResumeCannotRestartAfterLateQuery() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let state = try await f.approveMaintenance(), cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        await cloud.queried { await gate.wait() }
        let scheduler = ICloudRetentionMaintenanceScheduler(repository: f.repository, source: cloud)
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Stopped") })
        try await waitUntil { await gate.isWaiting() }
        await scheduler.suspend()
        try await scheduler.resumeIfEnabled(isCurrent: { true }, launchJob: { _ in XCTFail("Queued resume was revoked") })
        try await f.repository.disableRetentionMaintenance(approvalID: state.approval.approvalID)
        await scheduler.suspend(); await gate.release(); await scheduler.suspend(waitForRequests: true)
        let counts = await cloud.counts(); XCTAssertEqual(counts.queries, 1)
        let context = try await f.repository.retentionMaintenanceContext(); XCTAssertNil(context.scope.job)
    }

    func testProviderColdResumeNeedsExistingConsentAndStopRetainsThatConsent() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let noConsent = MaintenanceCloud(f.snapshot)
        let inert = ICloudAccountProvider(accountID: "cloud", database: f.database, sync: MaintenanceProviderSource(noConsent))
        await inert.resumeAutomaticSync()
        var counts = await noConsent.counts(); XCTAssertEqual(counts.queries, 0)
        await inert.stop()
        let state = try await f.approveMaintenance(), cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        await cloud.queried { await gate.wait() }
        let provider = ICloudAccountProvider(accountID: "cloud", database: f.database, sync: MaintenanceProviderSource(cloud))
        await provider.resumeAutomaticSync()
        try await waitUntil { await gate.isWaiting() }
        await provider.stop(); await gate.release()
        let preserved = try await f.repository.retentionMaintenanceContext()
        XCTAssertEqual(preserved.state?.approval, state.approval); XCTAssertTrue(preserved.state!.schedule.enabled)
        XCTAssertNil(preserved.scope.job)
        counts = await cloud.counts(); XCTAssertEqual(counts.queries, 1); XCTAssertEqual(counts.submits, 0)
    }

    func testProviderFutureMaintenanceReachesExistingAtomicExecutorAndCanBeDisabled() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let cloud = MaintenanceCloud(f.snapshot), gate = MaintenanceGate()
        let provider = ICloudAccountProvider(accountID: "cloud", database: f.database,
            sync: MaintenanceProviderSource(cloud), retentionTransportFactory: { _ in cloud },
            maintenanceSleep: { await gate.wait($0) })
        let review = try await provider.prepareRetentionMaintenanceReview()
        try await provider.enableReviewedRetentionMaintenance(id: review.id, cleanupConfirmed: true,
            futureArticlesConfirmed: true, clockMaintenanceConfirmed: true)
        try await waitUntil { (try? await f.repository.retentionMaintenanceContext().scope.job?.attempts.first?.stage) == .accepted }
        let status = try await provider.retentionMaintenanceStatus()
        XCTAssertTrue(status!.isEnabled)
        try await provider.stopRetentionMaintenance(approvalID: status!.approvalID)
        await gate.release(); await provider.stop()
        let context = try await f.repository.retentionMaintenanceContext()
        XCTAssertFalse(context.state!.schedule.enabled); XCTAssertEqual(context.scope.job?.attempts.first?.stage, .accepted)
        let counts = await cloud.counts(); XCTAssertEqual(counts.submits, 1); XCTAssertEqual(counts.clocks, 1)
    }
}

final class ICloudRetentionOutcomeReviewTests: XCTestCase {
    func testNeedsReviewUsesOriginalReceiptWithoutAnyCloudMutation() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let original = try await f.repository.beginRetentionJob(f.approval)
        let (unknown, batch) = try await f.submission(job: original, needsReview: true)
        let cloud = MaintenanceCloud(f.committed(batch))
        let result = try await ICloudRetentionOutcomeReviewer(repository: f.repository).review(approvalID: original.approval.approvalID, using: cloud)
        XCTAssertEqual(result.confirmedOperations, 1); XCTAssertEqual(result.unresolvedOperations, 0)
        let job = try await f.repository.retentionJob(approvalID: original.approval.approvalID)
        XCTAssertEqual(job.attempts[0].operationID, unknown.attempts[0].operationID)
        XCTAssertEqual(job.attempts[0].stage, .accepted)
        let counts = await cloud.counts(); XCTAssertEqual(counts.clocks, 0); XCTAssertEqual(counts.submits, 0)
        XCTAssertEqual(try f.repository.outgoingRecords().filter { $0.envelope.kind == .retentionQuota }.count, 0)
    }

    func testAllMissingArticlesWithoutOriginalQuotaReservationStayUnresolved() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let original = try await f.repository.beginRetentionJob(f.approval)
        let (unknown, batch) = try await f.submission(job: original, needsReview: true)
        let accepted = f.committed(batch)
        var records = accepted.records; records[ICloudRetentionQuota.recordName] = f.snapshot.records[ICloudRetentionQuota.recordName]
        let cloud = MaintenanceCloud(.init(generation: accepted.generation, requestedNames: accepted.requestedNames,
            records: records, missingNames: accepted.missingNames))
        let result = try await ICloudRetentionOutcomeReviewer(repository: f.repository).review(approvalID: original.approval.approvalID, using: cloud)
        XCTAssertEqual(result.confirmedOperations, 0); XCTAssertEqual(result.unresolvedOperations, 1)
        let preserved = try await f.repository.retentionJob(approvalID: original.approval.approvalID); XCTAssertEqual(preserved, unknown)
        let counts = await cloud.counts(); XCTAssertEqual(counts.clocks, 0); XCTAssertEqual(counts.submits, 0)
    }

    func testPartialWrongGenerationAndMissingFenceProofNeverAdvanceJob() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let original = try await f.repository.beginRetentionJob(f.approval)
        let (unknown, batch) = try await f.submission(job: original, needsReview: true), accepted = f.committed(batch)
        var missingFence = accepted.records
        let name = missingFence.keys.first { $0.hasPrefix("retention-v1:") }!
        missingFence.removeValue(forKey: name)
        let invalid = [
            ICloudRetentionPointSnapshot(generation: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", requestedNames: accepted.requestedNames, records: accepted.records, missingNames: accepted.missingNames),
            .init(generation: accepted.generation, requestedNames: accepted.requestedNames, records: accepted.records, missingNames: []),
            .init(generation: accepted.generation, requestedNames: accepted.requestedNames, records: missingFence, missingNames: accepted.missingNames.union([name]))
        ]
        for snapshot in invalid {
            let cloud = MaintenanceCloud(snapshot)
            do { _ = try await ICloudRetentionOutcomeReviewer(repository: f.repository).review(approvalID: original.approval.approvalID, using: cloud); XCTFail("Invalid proof") }
            catch { XCTAssertTrue(error is ICloudRetentionError) }
            let preserved = try await f.repository.retentionJob(approvalID: original.approval.approvalID); XCTAssertEqual(preserved, unknown)
        }
    }

    func testUnresolvedFirstPageDoesNotStarveLaterOutcomeReviews() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let names = try (0..<12).map {
            try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: MaintenanceFixture.feedURL)!, sourceItemID: "urn:fixture:outcome-\($0)"))
        }.sorted()
        let approval = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: MaintenanceFixture.generation,
            systemFingerprint: "fixture-user", articleRecordNames: names, retentionDays: 183, weeklyRecordLimit: 400)
        var job = try await f.repository.beginRetentionJob(approval)
        while let attempt = job.nextAttempt {
            let index = job.attempts.firstIndex(of: attempt)!
            var next = job; next.attempts[index].stage = .submitted
            next.attempts[index].proposalDigest = String(repeating: "a", count: 64); next.attempts[index].processedRecords = 3
            job = try await f.repository.storeRetentionJob(next, replacing: job)
            next = job; next.attempts[index].stage = .needsReview
            job = try await f.repository.storeRetentionJob(next, replacing: job)
        }
        let reader = MaintenanceMissingOutcomeReader(f.snapshot.records[ICloudRetentionQuota.recordName]!)
        let reviewer = ICloudRetentionOutcomeReviewer(repository: f.repository)
        let first = try await reviewer.review(approvalID: approval.approvalID, using: reader)
        let second = try await reviewer.review(approvalID: approval.approvalID, using: reader)
        XCTAssertEqual(first.checkedOperations, 10); XCTAssertEqual(second.checkedOperations, 2)
        let operations = await reader.captured(); XCTAssertEqual(Set(operations).count, 12)
        let unchanged = try await f.repository.retentionJob(approvalID: approval.approvalID); XCTAssertEqual(unchanged, job)
    }

    func testLocalStarsAndBodySurviveConfirmedOutcomeReview() async throws {
        let f = try await MaintenanceFixture(); defer { try? f.close() }
        let job = try await f.repository.beginRetentionJob(f.approval), (unknown, batch) = try await f.submission(job: job, needsReview: true)
        try f.database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture=1 WHERE account_id='cloud'")
            try FeedRecord(id: "feed", accountID: "cloud", title: "Local", feedURL: MaintenanceFixture.feedURL, updatedAt: 1).save(db)
            try ItemRecord(id: "item", accountID: "cloud", externalID: "item", feedID: "feed", createdAt: 1, updatedAt: 1, sourceItemID: MaintenanceFixture.source).save(db)
            try ArticleRecord(itemID: "item", title: "Original", contentHTML: "<p>Keep local body</p>", contentUpdatedAt: 1).save(db)
            try ArticleStateRecord(itemID: "item", isRead: true, isStarred: false, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture=0 WHERE account_id='cloud'")
        }
        let cloud = MaintenanceCloud(f.committed(batch))
        await cloud.fetched {
            try f.database.write { db in
                try ArticleStateRepository(database: f.database).markStarred(itemID: "item", isStarred: true, in: db)
            }
        }
        _ = try await ICloudRetentionOutcomeReviewer(repository: f.repository).review(approvalID: unknown.approval.approvalID, using: cloud)
        let values = try f.database.read { db in (try ArticleRecord.fetchOne(db, key: "item"), try ArticleStateRecord.fetchOne(db, key: "item")) }
        XCTAssertEqual(values.0?.contentHTML, "<p>Keep local body</p>"); XCTAssertEqual(values.1?.isStarred, true)
        let pending = try f.repository.outgoingRecords().filter { $0.envelope.kind == .starred }
        XCTAssertEqual(pending.first?.envelope.fields["value"]?.value, .flag(true))
        let counts = await cloud.counts(); XCTAssertEqual(counts.submits, 0); XCTAssertEqual(counts.clocks, 0)
    }
}
