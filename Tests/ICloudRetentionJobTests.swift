@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor RetentionJobCloud: ICloudRetentionExecutionTransport {
    private var snapshot: ICloudRetentionPointSnapshot
    private var reads = 0, sends = 0
    private var failBefore = false, failAfter = false, omitReceipt = false
    private var onFetch: (@Sendable () async throws -> Void)?
    private var onSubmit: (@Sendable () async throws -> Void)?
    init(snapshot: ICloudRetentionPointSnapshot) { self.snapshot = snapshot }
    func fail(afterCommit: Bool) { if afterCommit { failAfter = true } else { failBefore = true } }
    func omitNextReceipt() { omitReceipt = true }
    func fetched(_ callback: @escaping @Sendable () async throws -> Void) { onFetch = callback }
    func submitted(_ callback: @escaping @Sendable () async throws -> Void) { onSubmit = callback }
    func counts() -> (reads: Int, sends: Int) { (reads, sends) }
    func prepareServerClock() async throws {}
    func changeRead() throws {
        var records = snapshot.records
        let name = records.keys.first { $0.hasPrefix("read-v1:") }!
        let old = records[name]!
        var envelope = old.envelope
        envelope.fields["value"] = .init(value: .flag(true), version: .init(counter: 11, deviceID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        records[name] = .init(envelope: envelope, creationDate: old.creationDate, modificationDate: old.modificationDate,
                              systemFields: old.systemFields, changeTag: "changed-target")
        snapshot = .init(generation: snapshot.generation, requestedNames: snapshot.requestedNames,
                         records: records, missingNames: snapshot.missingNames)
    }
    func fetch(articleRecordName: String) async throws -> ICloudRetentionPointSnapshot {
        reads += 1
        try await onFetch?()
        return snapshot
    }
    func submit(_ batch: ICloudRetentionAtomicBatch) async throws -> [ICloudReceivedRecord] {
        sends += 1
        if failBefore { failBefore = false; throw CKError(.networkFailure) }
        try await onSubmit?()
        var records = snapshot.records
        for name in batch.recordNamesToDelete { records.removeValue(forKey: name) }
        let date = records[ICloudRetentionQuota.recordName]!.modificationDate!
        for prepared in batch.recordsToSave {
            records[prepared.envelope.recordName] = .init(envelope: prepared.envelope,
                creationDate: date, modificationDate: date, systemFields: Data([1]), changeTag: "saved-tag")
        }
        snapshot = .init(generation: snapshot.generation, requestedNames: snapshot.requestedNames,
            records: records, missingNames: snapshot.requestedNames.subtracting(records.keys))
        if failAfter { failAfter = false; throw CKError(.networkFailure) }
        var receipts = batch.recordsToSave.map { ICloudReceivedRecord(envelope: $0.envelope, systemFields: Data([1])) }
        if omitReceipt { omitReceipt = false; receipts.removeLast() }
        return receipts
    }
}

private actor RetentionSchedulerEvents {
    private var finished = false, failed = false
    private var sleeps: [Double] = []
    func event(_ event: ICloudRetentionSchedulingEvent) {
        switch event {
        case .finished: finished = true
        case .failed: failed = true
        default: break
        }
    }
    func slept(_ duration: Duration) {
        let parts = duration.components
        sleeps.append(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
    func snapshot() -> (finished: Bool, failed: Bool, sleeps: [Double]) { (finished, failed, sleeps) }
}

private actor RetentionSchedulerGate {
    private var waiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        waiting = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func isWaiting() -> Bool { waiting }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class RetentionReviewTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    func advance(_ duration: Duration) { lock.lock(); defer { lock.unlock() }; value += duration }
    func read() -> Duration { lock.lock(); defer { lock.unlock() }; return value }
}

private actor RetentionReviewSource: ICloudAccountSyncing {
    let metadata: [ICloudCloudRecordMetadata]
    nonisolated var supportsAutomaticSync: Bool { true }
    private var queries = 0
    init(_ metadata: [ICloudCloudRecordMetadata]) { self.metadata = metadata }
    func fetchChanges() async throws {}
    func sendChanges() async throws {}
    func stop() async {}
    func count() -> Int { queries }
    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        queries += 1
        return .init(records: metadata.filter { $0.envelope.zone == zone }, cursor: nil, envelopeBytes: 1_000)
    }
}

final class ICloudRetentionJobTests: XCTestCase {
    private let generation = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let device = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let feedURL = "https://example.com/rss"
    private let source = "urn:fixture:retention-job"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var directories: [URL] = []
    private struct Fixture: Sendable {
        let database: LibraryDatabase
        let repository: ICloudRecordRepository
        let url: URL
        let approval: ICloudRetentionApproval
        let snapshot: ICloudRetentionPointSnapshot
    }
    override func tearDownWithError() throws {
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }
    private func fixture(version: Int = 3, clockMaintenance: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionJob-\(UUID())")
        directories.append(directory)
        let url = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: url)
        try database.write { try AccountRecord(id: "cloud", type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0) }
        let repository = ICloudRecordRepository(database: database, accountID: "cloud")
        try repository.activate()
        try repository.bindSystemUserFingerprint("fixture-user")
        try await repository.acceptCloudRoot(.init(generation: generation, phase: .ready, protocolVersion: version))
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET initialized_zones=3,settings_pending=0,logical_clock=50") }
        let article = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: URL(string: feedURL)!, sourceItemID: source))
        let hash = article.dropFirst("article-v1:".count)
        let read = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + hash, feedURL: feedURL, sourceItemID: source,
            fields: ["value": .init(value: .flag(true), version: .init(counter: 10, deviceID: device))])
        let star = try ICloudRecordEnvelope(kind: .starred, recordName: "starred-v1:" + hash, feedURL: feedURL, sourceItemID: source,
            fields: ["value": .init(value: .flag(false), version: .init(counter: 10, deviceID: device))])
        let marker = try ICloudRetentionFence(generation: generation, article: read).envelope().stampedRetentionSave()
        let policy = try ICloudRetentionUnreadPolicy(generation: generation, releasedVersion: .bootstrap).envelope().stampedRetentionSave()
        let quota = try ICloudRetentionQuota().envelope(version: .init(counter: 30, deviceID: device))
        var records: [String: ICloudCloudRecordMetadata] = [:]
        for envelope in [read, star, marker, policy, quota] {
            let date = [.read, .starred].contains(envelope.kind) ? now.addingTimeInterval(-184 * 86_400) : now
            records[envelope.recordName] = .init(envelope: envelope, creationDate: date, modificationDate: date,
                                               systemFields: Data([1]), changeTag: "original-tag")
        }
        let names = try ICloudRetentionAtomicBatchPlanner.requestedNames(articleRecordName: article)
        let approval = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: generation,
            systemFingerprint: "fixture-user", articleRecordNames: [article], retentionDays: 183, weeklyRecordLimit: 400,
            allowsClockMaintenance: clockMaintenance)
        return .init(database: database, repository: repository, url: url, approval: approval,
                     snapshot: .init(generation: generation, requestedNames: names, records: records, missingNames: names.subtracting(records.keys)))
    }
    private func seedLocal(_ fixture: Fixture) throws {
        try fixture.database.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture=1")
            try FeedRecord(id: "feed", accountID: "cloud", title: "Feed", feedURL: feedURL, updatedAt: 1).save(db)
            try ItemRecord(id: "item", accountID: "cloud", externalID: "item", feedID: "feed", createdAt: 1, updatedAt: 1, sourceItemID: source).save(db)
            try ArticleRecord(itemID: "item", title: "Local original", contentHTML: "<p>Local body</p>", contentUpdatedAt: 1).save(db)
            try ArticleStateRecord(itemID: "item", isRead: true, isStarred: false, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: "UPDATE icloud_sync_scope SET suppress_capture=0")
        }
    }

    func testReviewIsReadOnlyAndRequiresBothIndependentConfirmations() async throws {
        let fixture = try await fixture(), date = now
        let reviewer = ICloudRetentionReviewCoordinator(repository: fixture.repository, now: { date })
        let context = try await fixture.repository.retentionReviewContext()
        let review = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: context,
                                                isComplete: true, reachedSafetyLimit: false)
        XCTAssertEqual(review.candidateArticles, 1)
        XCTAssertFalse(String(describing: review).contains(feedURL)); XCTAssertFalse(String(describing: review).contains(source))
        for confirmations in [(false, true), (true, false)] {
            do { _ = try await reviewer.approve(id: review.id, cleanupConfirmed: confirmations.0,
                                                clockMaintenanceConfirmed: confirmations.1); XCTFail("Both confirmations are required") }
            catch { XCTAssertEqual(error as? ICloudRetentionReviewError, confirmations.0 ? .clockMaintenanceRequired : .confirmationRequired) }
            XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT retention_job FROM icloud_sync_scope") })
        }
        let approved = try await reviewer.approve(id: review.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true)
        XCTAssertTrue(approved.approval.allowsClockMaintenance)
        XCTAssertEqual(approved.approval.articleRecordNames, fixture.approval.articleRecordNames)
        let schedule = try await fixture.repository.retentionScheduleState(approvalID: approved.approval.approvalID)
        XCTAssertFalse(schedule.enabled) // A durable review is separate from enabling the executor.
    }

    func testExpiredChangedOrDiscardedReviewCannotCreateJob() async throws {
        let fixture = try await fixture(), time = RetentionReviewTime(), date = now
        let reviewer = ICloudRetentionReviewCoordinator(repository: fixture.repository, now: { date }, uptime: { time.read() })
        let context = try await fixture.repository.retentionReviewContext()
        let first = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: context,
                                               isComplete: true, reachedSafetyLimit: false)
        time.advance(.seconds(600))
        do { _ = try await reviewer.approve(id: first.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .staleReview) }
        let second = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: context,
                                                isComplete: true, reachedSafetyLimit: false)
        await reviewer.discard(id: second.id)
        do { _ = try await reviewer.approve(id: second.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Discarded") }
        catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .staleReview) }
        let third = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: context,
                                               isComplete: true, reachedSafetyLimit: false)
        try fixture.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET sync_unread_content=1") }
        do { _ = try await reviewer.approve(id: third.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Changed context") }
        catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .staleReview) }
        XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT retention_job FROM icloud_sync_scope") })
    }

    func testIncompleteOrLimitedScanCannotProduceReview() async throws {
        let fixture = try await fixture(), date = now
        let reviewer = ICloudRetentionReviewCoordinator(repository: fixture.repository, now: { date })
        let context = try await fixture.repository.retentionReviewContext()
        for flags in [(false, false), (true, true)] {
            do { _ = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: context,
                isComplete: flags.0, reachedSafetyLimit: flags.1); XCTFail("Incomplete evidence") }
            catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .scanIncomplete) }
        }
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let changed = try await fixture.repository.retentionReviewContext()
        do { _ = try await reviewer.prepare(records: Array(fixture.snapshot.records.values), context: changed,
            isComplete: true, reachedSafetyLimit: false); XCTFail("Active job must be preserved") }
        catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .existingJob) }
    }

    func testCandidateDiscoveryProtectsPendingAndRecentRecordsAndRejectsDuplicateEvidence() async throws {
        let fixture = try await fixture()
        let metadata = Array(fixture.snapshot.records.values)
        let names = try ICloudRetentionCandidateDiscovery.names(records: metadata, protection: .init(), syncUnreadContent: false, now: now)
        XCTAssertEqual(names, fixture.approval.articleRecordNames)
        let read = metadata.first { $0.envelope.kind == .read }!
        let protected = try ICloudRetentionCandidateDiscovery.names(records: metadata,
            protection: .init(recordNames: [read.envelope.recordName]), syncUnreadContent: false, now: now)
        XCTAssertTrue(protected.isEmpty)
        let recent = metadata.map { record -> ICloudCloudRecordMetadata in
            .init(envelope: record.envelope, creationDate: record.creationDate,
                  modificationDate: record.envelope.kind == .read ? now : record.modificationDate,
                  systemFields: record.systemFields, changeTag: record.changeTag)
        }
        XCTAssertTrue(try ICloudRetentionCandidateDiscovery.names(records: recent, protection: .init(), syncUnreadContent: false, now: now).isEmpty)
        XCTAssertThrowsError(try ICloudRetentionCandidateDiscovery.names(records: metadata + [read], protection: .init(), syncUnreadContent: false, now: now))
        XCTAssertThrowsError(try ICloudRetentionCandidateDiscovery.names(records: metadata, protection: .init(), syncUnreadContent: false, now: now, limit: 401))
    }

    func testCompletedJobNeedsExplicitMatchingReplacementAndKeepsOldQuotaEvidence() async throws {
        let fixture = try await fixture()
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let newApproval = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: generation,
            systemFingerprint: "fixture-user", articleRecordNames: fixture.approval.articleRecordNames,
            retentionDays: 183, weeklyRecordLimit: 400, allowsClockMaintenance: true)
        do { _ = try await fixture.repository.beginRetentionJob(newApproval, replacingCompletedApprovalID: fixture.approval.approvalID); XCTFail("Pending job") } catch {}
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        _ = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        let quotaBefore = try XCTUnwrap(fixture.database.read { try String.fetchOne($0, sql: "SELECT envelope_json FROM icloud_records WHERE record_name=?", arguments: [ICloudRetentionQuota.recordName]) })
        do { _ = try await fixture.repository.beginRetentionJob(newApproval, replacingCompletedApprovalID: UUID().uuidString); XCTFail("Wrong previous approval") } catch {}
        let next = try await fixture.repository.beginRetentionJob(newApproval, replacingCompletedApprovalID: fixture.approval.approvalID)
        XCTAssertEqual(next.attempts[0].stage, .pending)
        XCTAssertEqual(try fixture.database.read { try String.fetchOne($0, sql: "SELECT envelope_json FROM icloud_records WHERE record_name=?", arguments: [ICloudRetentionQuota.recordName]) }, quotaBefore)
        let newSchedule = try await fixture.repository.retentionScheduleState(approvalID: newApproval.approvalID)
        XCTAssertFalse(newSchedule.enabled)
    }

    func testProviderPreviewAndStopDoNotLaunchCleanupAndInvalidateReview() async throws {
        let fixture = try await fixture()
        let source = RetentionReviewSource(Array(fixture.snapshot.records.values))
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        let provider = ICloudAccountProvider(accountID: "cloud", database: fixture.database, sync: source,
                                             retentionTransportFactory: { _ in cloud })
        // Use present-day dates only for the preview; the fixed fixture state is old enough.
        let review = try await provider.prepareRetentionReview()
        XCTAssertEqual(review.candidateArticles, 1)
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.sends, 0)
        await provider.stop()
        do { try await provider.startReviewedRetention(id: review.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true); XCTFail("Stopped provider review") }
        catch { XCTAssertEqual(error as? ICloudRetentionReviewError, .staleReview) }
        let queries = await source.count(); XCTAssertEqual(queries, 1)
    }

    func testProviderLifecycleResumesOnlyDurablyEnabledFiniteJob() async throws {
        let fixture = try await fixture(clockMaintenance: true)
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let source = RetentionReviewSource(Array(fixture.snapshot.records.values)), cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        let provider = ICloudAccountProvider(accountID: "cloud", database: fixture.database, sync: source,
                                             retentionTransportFactory: { _ in cloud })
        await provider.startAutomaticSync()
        var counts = await cloud.counts(); XCTAssertEqual(counts.sends, 0) // Construction/normal startup cannot enable.
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        await provider.resumeAutomaticSync()
        for _ in 0..<200 {
            if try await fixture.repository.retentionJob(approvalID: fixture.approval.approvalID).isFinished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let progress = try await provider.retentionProgress()
        XCTAssertEqual(progress?.completedArticles, 1); XCTAssertEqual(progress?.remainingArticles, 0)
        counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1)
        await provider.stop()
    }

    func testSuspensionRetainsApprovedRetryWaitAndPreventsLateSDKCalls() async throws {
        let fixture = try await fixture(clockMaintenance: true)
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        _ = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: CKError(.networkFailure), now: now)
        let before = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), gate = RetentionSchedulerGate()
        let scheduler = ICloudRetentionScheduler(repository: fixture.repository, sleep: { _ in await gate.wait() })
        try await scheduler.resumeIfEnabled(approvalID: fixture.approval.approvalID, using: cloud)
        try await waitForGate(gate)
        await scheduler.suspend(); await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        let after = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertEqual(after, before)
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.sends, 0)
    }

    func testPositiveQueryHintCannotAuthorizeDeletingAnUnobservedCloudStar() async throws {
        let fixture = try await fixture()
        var records = fixture.snapshot.records
        let key = records.keys.first { $0.hasPrefix("starred-v1:") }!, previous = records[key]!
        var envelope = previous.envelope
        envelope.fields["value"] = .init(value: .flag(true), version: .init(counter: 10, deviceID: device))
        records[key] = .init(envelope: envelope, creationDate: previous.creationDate,
            modificationDate: previous.modificationDate, systemFields: previous.systemFields, changeTag: previous.changeTag)
        let cloud = RetentionJobCloud(snapshot: .init(generation: generation, requestedNames: fixture.snapshot.requestedNames,
            records: records, missingNames: fixture.snapshot.missingNames))
        let context = try await fixture.repository.retentionReviewContext(), date = now
        let reviewer = ICloudRetentionReviewCoordinator(repository: fixture.repository, now: { date })
        let review = try await reviewer.prepare(names: fixture.approval.articleRecordNames, context: context, scannedAt: now)
        let job = try await reviewer.approve(id: review.id, cleanupConfirmed: true, clockMaintenanceConfirmed: true)
        let result = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: job.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts.first?.stage, .skipped)
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.sends, 0)
    }

    func testSchemaInstallationCreatesNoApprovalOrAttempt() async throws {
        let fixture = try await fixture()
        XCTAssertNil(try fixture.database.read { try Data.fetchOne($0, sql: "SELECT retention_job FROM icloud_sync_scope") })
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        do { _ = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("No durable approval") }
        catch { XCTAssertEqual(error as? ICloudRetentionJobError, .approvalMismatch) }
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.sends, 0)
    }

    func testApprovalIsDurableAndReopeningKeepsOperationIdentity() async throws {
        let fixture = try await fixture()
        let first = try await fixture.repository.beginRetentionJob(fixture.approval)
        let reopened = try LibraryDatabase(databaseURL: fixture.url)
        let restored = try await ICloudRecordRepository(database: reopened, accountID: "cloud").beginRetentionJob(fixture.approval)
        XCTAssertEqual(restored, first)
        let data = try first.serialized()
        XCTAssertEqual(try ICloudRetentionJob.decode(data), first)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(feedURL)); XCTAssertFalse(text.contains(source)); XCTAssertFalse(text.contains("changeTag"))
    }

    func testLegacyProtocolCannotApproveCleanup() async throws {
        let fixture = try await fixture(version: 2)
        do { _ = try await fixture.repository.beginRetentionJob(fixture.approval); XCTFail("Legacy writer must reject deletion approval") }
        catch { XCTAssertEqual(error as? ICloudRetentionJobError, .approvalMismatch) }
    }

    func testWrongBindingAndChangedApprovalAreRejected() async throws {
        let fixture = try await fixture()
        let wrong = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: generation, systemFingerprint: "other-user",
            articleRecordNames: fixture.approval.articleRecordNames, retentionDays: 183, weeklyRecordLimit: 400)
        do { _ = try await fixture.repository.beginRetentionJob(wrong); XCTFail("Wrong user") } catch {}
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let changed = ICloudRetentionApproval(approvalID: UUID().uuidString, generation: generation, systemFingerprint: "fixture-user",
            articleRecordNames: fixture.approval.articleRecordNames, retentionDays: 183, weeklyRecordLimit: 400)
        do { _ = try await fixture.repository.beginRetentionJob(changed); XCTFail("Existing approval cannot be replaced implicitly") } catch {}
    }

    func testSuccessfulCleanupKeepsLocalReadingDataAndFinishesOnlyOnce() async throws {
        let fixture = try await fixture(); try seedLocal(fixture)
        _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), coordinator = ICloudRetentionCoordinator(repository: fixture.repository)
        let result = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertTrue(result.isFinished); XCTAssertEqual(result.attempts[0].stage, .accepted); XCTAssertEqual(result.attempts[0].processedRecords, 4)
        XCTAssertEqual(try fixture.database.read { try ArticleRecord.fetchOne($0, key: "item")?.contentHTML }, "<p>Local body</p>")
        XCTAssertEqual(try fixture.database.read { try ArticleStateRecord.fetchOne($0, key: "item")?.isRead }, true)
        _ = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1); XCTAssertEqual(counts.reads, 1)
    }

    func testLostSuccessfulReceiptReopensWithoutRepeatingAlreadyAbsentDeletes() async throws {
        let fixture = try await fixture()
        let original = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot); await cloud.fail(afterCommit: true)
        do { _ = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("Lost receipt") } catch {}
        let pending = try await fixture.repository.retentionJob(approvalID: fixture.approval.approvalID)
        XCTAssertEqual(pending.attempts[0].stage, .submitted); XCTAssertEqual(pending.attempts[0].operationID, original.attempts[0].operationID)
        let reopened = try LibraryDatabase(databaseURL: fixture.url)
        let result = try await ICloudRetentionCoordinator(repository: .init(database: reopened, accountID: "cloud"))
            .executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].stage, .accepted)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1); XCTAssertEqual(counts.reads, 2)
    }

    func testFailureBeforeCommitRetriesSameDurableOperation() async throws {
        let fixture = try await fixture()
        let original = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot); await cloud.fail(afterCommit: false)
        let coordinator = ICloudRetentionCoordinator(repository: fixture.repository)
        do { _ = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("Failed submit") } catch {}
        let result = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].operationID, original.attempts[0].operationID); XCTAssertEqual(result.attempts[0].stage, .accepted)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 2)
    }

    func testChangedDeleteTargetAfterFailureRequiresAnotherReview() async throws {
        let fixture = try await fixture(); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot); await cloud.fail(afterCommit: false)
        let coordinator = ICloudRetentionCoordinator(repository: fixture.repository)
        do { _ = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud) } catch {}
        try await cloud.changeRead()
        let result = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].stage, .needsReview)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1)
    }

    func testIncompleteSuccessReceiptStaysSubmittedUntilLedgerRecovery() async throws {
        let fixture = try await fixture(); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot); await cloud.omitNextReceipt()
        let coordinator = ICloudRetentionCoordinator(repository: fixture.repository)
        do { _ = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("Partial success receipt") }
        catch { XCTAssertEqual(error as? ICloudRetentionError, .incompleteSnapshot) }
        let result = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].stage, .accepted)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1)
    }

    func testPauseDuringPointFetchPreventsSubmission() async throws {
        let fixture = try await fixture(); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        await cloud.fetched { try fixture.repository.pause(reason: "accountChanged") }
        do { _ = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("Paused scope") } catch {}
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 0)
    }

    func testStoppedLifecycleRejectsLateFetchWithoutSubmit() async throws {
        let fixture = try await fixture(); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), coordinator = ICloudRetentionCoordinator(repository: fixture.repository)
        await cloud.fetched { await coordinator.stop() }
        do { _ = try await coordinator.executeNext(approvalID: fixture.approval.approvalID, using: cloud); XCTFail("Stopped lifecycle") }
        catch { XCTAssertTrue(error is CancellationError) }
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 0)
    }

    func testNewLocalIntentBeforePlanningProtectsArticle() async throws {
        let fixture = try await fixture(); try seedLocal(fixture); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        await cloud.fetched { try fixture.database.write { try $0.execute(sql: "UPDATE article_states SET is_starred=1 WHERE item_id='item'") } }
        let result = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].stage, .skipped)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 0)
    }

    func testIntentArrivingDuringSubmitRemainsPendingAboveRetirementFloor() async throws {
        let fixture = try await fixture(); try seedLocal(fixture); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot)
        await cloud.submitted { try fixture.database.write { try $0.execute(sql: "UPDATE article_states SET is_starred=1 WHERE item_id='item'") } }
        let result = try await ICloudRetentionCoordinator(repository: fixture.repository).executeNext(approvalID: fixture.approval.approvalID, using: cloud)
        XCTAssertEqual(result.attempts[0].stage, .accepted)
        XCTAssertEqual(try fixture.database.read { try ArticleStateRecord.fetchOne($0, key: "item")?.isStarred }, true)
        let outgoing = try fixture.repository.outgoingRecords().first { $0.envelope.kind == .starred }
        XCTAssertEqual(outgoing?.envelope.fields["value"]?.value, .flag(true))
        XCTAssertGreaterThan(try XCTUnwrap(outgoing?.envelope.fields["value"]?.version.counter), 10)
        XCTAssertEqual(try fixture.database.read { try Bool.fetchOne($0, sql: "SELECT is_pending FROM icloud_sync_changes WHERE kind='starred'") }, true)
    }

    func testStrictJobPayloadRejectsPrivateAndUnknownFields() async throws {
        let fixture = try await fixture(), job = try ICloudRetentionJob(approval: fixture.approval)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: job.serialized()) as? [String: Any])
        json["guid"] = source
        XCTAssertThrowsError(try ICloudRetentionJob.decode(JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "guid")
        var entries = try XCTUnwrap(json["attempts"] as? [[String: Any]])
        entries[0]["serverFields"] = "private"; json["attempts"] = entries
        XCTAssertThrowsError(try ICloudRetentionJob.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testSDKEncoderRejectsFreshGuardWithoutServerTag() async throws {
        let fixture = try await fixture(), job = try ICloudRetentionJob(approval: fixture.approval)
        let attempt = try XCTUnwrap(job.nextAttempt)
        guard case .prepared(let batch) = try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: fixture.snapshot,
            articleRecordName: attempt.articleRecordName, protection: .init(), operationID: attempt.operationID, observedClock: 50, deviceID: device) else { return XCTFail() }
        var submitted = job
        submitted.attempts[0].stage = .submitted; submitted.attempts[0].processedRecords = batch.processedRecordCount
        submitted.attempts[0].proposalDigest = batch.proposalDigest
        let fresh = try batch.recordsToSave.map { prepared in
            let record = try ICloudRecordCodec.encode(prepared.envelope, systemFields: nil, generation: generation)
            return ICloudPreparedRecord(envelope: prepared.envelope, systemFields: ICloudRecordCodec.systemFields(record), origins: [], isPending: true)
        }
        let unproven = ICloudRetentionAtomicBatch(generation: generation, operationID: batch.operationID, recordsToSave: fresh,
            recordNamesToDelete: batch.recordNamesToDelete, processedRecordCount: batch.processedRecordCount, proposalDigest: batch.proposalDigest)
        XCTAssertThrowsError(try ICloudRetentionCloudKitTransport.records(unproven, job: submitted))
        XCTAssertThrowsError(try ICloudRetentionCloudKitTransport.receipts([:], deletions: [:], batch: batch))
    }

    func testV21MigrationPreservesFrozenArchiveAndAddsOnlyEmptyJob() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionJobMigration-\(UUID())")
        directories.append(directory); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v21-icloud-writer-protocol-binding")
        try pool.write { db in
            try AccountRecord(id: "old", type: "iCloud", displayName: "Old", createdAt: 1, updatedAt: 1).save(db)
            try db.execute(sql: "INSERT INTO icloud_sync_scope(account_id,capture_enabled,suppress_capture,pause_reason,engine_state) VALUES('old',0,1,'accountChanged',?)", arguments: [Data([3, 1, 4])])
            try db.execute(sql: "UPDATE accounts SET is_enabled=0,is_archived=1 WHERE id='old'")
        }
        let old = try pool.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM icloud_sync_scope")) }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            let columns = old.columnNames.map { "\"" + $0 + "\"" }.joined(separator: ",")
            XCTAssertEqual(try Row.fetchOne(db, sql: "SELECT \(columns) FROM icloud_sync_scope"), old)
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT retention_job FROM icloud_sync_scope"))
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        XCTAssertThrowsError(try pool.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET retention_job=?", arguments: [Data([1])]) })
    }

    func testClockMaintenanceRequiresIndependentApprovalAndDefaultsOff() async throws {
        let fixture = try await fixture()
        XCTAssertFalse(fixture.approval.allowsClockMaintenance)
        let granted = ICloudRetentionApproval(approvalID: fixture.approval.approvalID, generation: generation,
            systemFingerprint: "fixture-user", articleRecordNames: fixture.approval.articleRecordNames,
            retentionDays: 183, weeklyRecordLimit: 400, allowsClockMaintenance: true)
        let job = try ICloudRetentionJob(approval: granted)
        XCTAssertTrue(try ICloudRetentionJob.decode(job.serialized()).approval.allowsClockMaintenance)
    }

    func testClockProbePreservesFullQuotaWithoutExpiringOrDatingReservations() async throws {
        let fixture = try await fixture()
        let full = try ICloudRetentionQuota().allocating(400, operationID: UUID().uuidString, serverDate: now)
        let metadata = ICloudCloudRecordMetadata(envelope: try full.envelope(version: .init(counter: 30, deviceID: device)),
            creationDate: now, modificationDate: now, systemFields: Data([1]), changeTag: "actual-server-tag")
        let point = ICloudRetentionPointSnapshot(generation: generation, requestedNames: [ICloudRetentionQuota.recordName],
            records: [ICloudRetentionQuota.recordName: metadata], missingNames: [])
        let stamp = UUID().uuidString
        let prepared = try ICloudRetentionQuotaClock.prepare(snapshot: point, writer: .init(counter: 50, deviceID: device), stamp: stamp)
        let ledger = try ICloudRetentionQuota(envelope: prepared.envelope)
        XCTAssertEqual(ledger.reservations, full.reservations); XCTAssertEqual(ledger.lastServerDate, full.lastServerDate)
        XCTAssertEqual(ledger.clockStamp, stamp); XCTAssertEqual(ledger.reservations.first?.processedRecords, 400)
        XCTAssertNil(ledger.reservations.first?.confirmedAt); XCTAssertEqual(prepared.systemFields, metadata.systemFields)
        XCTAssertEqual(prepared.envelope.fields["ledger"]?.version.counter, 51)
        XCTAssertEqual(fixture.snapshot.generation, generation)
    }

    func testClockQuotaCreationRequiresCompleteUnknownItemPointProof() throws {
        let names: Set<String> = [ICloudRetentionQuota.recordName]
        let absent = ICloudRetentionPointSnapshot(generation: generation, requestedNames: names, records: [:], missingNames: names)
        let prepared = try ICloudRetentionQuotaClock.prepare(snapshot: absent, writer: .init(counter: 50, deviceID: device))
        XCTAssertNil(prepared.systemFields)
        XCTAssertTrue(try ICloudRetentionQuota(envelope: prepared.envelope).reservations.isEmpty)
        let incomplete = ICloudRetentionPointSnapshot(generation: generation, requestedNames: names, records: [:], missingNames: [])
        XCTAssertThrowsError(try ICloudRetentionQuotaClock.prepare(snapshot: incomplete, writer: .init(counter: 50, deviceID: device)))
        XCTAssertThrowsError(try ICloudRetentionQuotaClock.prepare(snapshot: absent, writer: .init(counter: Int64.max, deviceID: device)))
    }

    func testAlreadyAcceptedLedgerRequiresRetirementMarkerEvenIfAllTargetsAreAbsent() async throws {
        let fixture = try await fixture(), job = try ICloudRetentionJob(approval: fixture.approval)
        let attempt = try XCTUnwrap(job.nextAttempt)
        let quota = try ICloudRetentionQuota().allocating(4, operationID: attempt.operationID, serverDate: now)
        var records = fixture.snapshot.records.filter { ![.read, .starred, .content].contains($0.value.envelope.kind) }
        records[ICloudRetentionQuota.recordName] = .init(envelope: try quota.envelope(version: .init(counter: 50, deviceID: device)),
            creationDate: now, modificationDate: now, systemFields: Data([1]), changeTag: "accepted-tag")
        var point = ICloudRetentionPointSnapshot(generation: generation, requestedNames: fixture.snapshot.requestedNames,
            records: records, missingNames: fixture.snapshot.requestedNames.subtracting(records.keys))
        guard case .alreadyAccepted(let cost) = try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: point,
            articleRecordName: attempt.articleRecordName, protection: .init(), operationID: attempt.operationID,
            observedClock: 50, deviceID: device) else { return XCTFail("Absent targets are not an unexecuted no-candidate") }
        XCTAssertEqual(cost, 4)
        records = records.filter { $0.value.envelope.kind != .retention }
        point = .init(generation: generation, requestedNames: fixture.snapshot.requestedNames,
            records: records, missingNames: fixture.snapshot.requestedNames.subtracting(records.keys))
        XCTAssertThrowsError(try ICloudRetentionAtomicBatchPlanner.prepare(snapshot: point,
            articleRecordName: attempt.articleRecordName, protection: .init(), operationID: attempt.operationID,
            observedClock: 50, deviceID: device))
    }

    func testScheduleDefaultsDisabledAndCannotEnableWithoutClockMaintenanceApproval() async throws {
        let fixture = try await fixture(); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let state = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertFalse(state.enabled); XCTAssertNil(state.deadline)
        do { _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID); XCTFail("Administrative saves require separate approval") }
        catch { XCTAssertEqual(error as? ICloudRetentionJobError, .approvalMismatch) }
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), scheduler = ICloudRetentionScheduler(repository: fixture.repository)
        try await scheduler.resumeIfEnabled(approvalID: fixture.approval.approvalID, using: cloud)
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.sends, 0)
    }

    func testRetryAfterSurvivesReopenAndForwardClockDoesNotSkipMinimumWait() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 900.0])
        let deadline = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: error, now: now)
        XCTAssertEqual(deadline, now.addingTimeInterval(900))
        let state = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        let repeated = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: error, now: now.addingTimeInterval(100))
        XCTAssertEqual(repeated, deadline)
        let unchanged = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTAssertEqual(unchanged, state)
        let reopened = try LibraryDatabase(databaseURL: fixture.url), restored = ICloudRecordRepository(database: reopened, accountID: "cloud")
        let durable = try await restored.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertEqual(durable, state); XCTAssertEqual(try durable.coldWait(now: now.addingTimeInterval(86_400)), 900)
    }

    func testQuotaBackoffDoesNotPretendToRenewServerLedger() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        let deadline = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: ICloudRetentionError.budgetExceeded, now: now)
        XCTAssertEqual(deadline, now.addingTimeInterval(86_400))
        XCTAssertNil(try fixture.database.read { try String.fetchOne($0, sql: "SELECT envelope_json FROM icloud_records WHERE record_name=?", arguments: [ICloudRetentionQuota.recordName]) })
    }

    func testPermanentErrorCreatesNoAutomaticRetryWindow() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        let deadline = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: CKError(.permissionFailure), now: now)
        XCTAssertNil(deadline)
        let state = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertNil(state.deadline); XCTAssertEqual(state.revision, 0)
    }

    func testStaleWakeCannotClearNewerPersistedDelay() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        _ = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: nil, now: now)
        let old = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        try await fixture.repository.clearRetentionWake(approvalID: fixture.approval.approvalID, expectedRevision: old.revision)
        _ = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: CKError(.networkFailure), now: now)
        do { try await fixture.repository.clearRetentionWake(approvalID: fixture.approval.approvalID, expectedRevision: old.revision); XCTFail("Stale callback") }
        catch { XCTAssertEqual(error as? ICloudRetentionJobError, .jobChanged) }
        let current = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertNotNil(current.deadline); XCTAssertGreaterThan(current.revision, old.revision)
    }

    func testAtomicPartialFailureRetriesOnlyWhenEveryFailureIsRecognized() {
        let errors: [AnyHashable: any Error] = ["fence": CKError(.serverRecordChanged), "quota": CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 300.0])]
        XCTAssertEqual(ICloudRetentionSchedulingPolicy.delay(for: CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: errors]), attempt: 1), 300)
        let permanent: [AnyHashable: any Error] = ["fence": CKError(.serverRecordChanged), "quota": CKError(.permissionFailure)]
        XCTAssertNil(ICloudRetentionSchedulingPolicy.delay(for: CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: permanent]), attempt: 1))
        XCTAssertEqual(ICloudRetentionSchedulingPolicy.delay(for: ICloudCloudResetError.operationInProgress, attempt: 1), 60)
    }

    func testScheduleIntegrityRejectsIncompleteWakeAndRevisionOverflow() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        try fixture.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET retention_wake_at=1,retention_wake_delay=NULL") }
        do { _ = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTFail("Corrupt waiting state") } catch {}
        try fixture.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET retention_wake_at=NULL,retention_wake_revision=?", arguments: [Int64.max]) }
        do { _ = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID, for: nil, now: now); XCTFail("Overflow") } catch {}
        XCTAssertThrowsError(try fixture.database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET retention_wake_revision=retention_wake_revision+1") })
    }

    private func waitForScheduler(_ events: RetentionSchedulerEvents) async throws {
        for _ in 0..<2_000 {
            let state = await events.snapshot()
            if state.finished || state.failed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Scheduler did not reach a terminal event within 10 seconds")
    }

    func testApprovedBackgroundScheduleFinishesAndDisablesItsTimer() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), events = RetentionSchedulerEvents()
        let date = now
        let scheduler = ICloudRetentionScheduler(repository: fixture.repository, now: { date }, sleep: { await events.slept($0) })
        try await scheduler.start(approvalID: fixture.approval.approvalID, using: cloud, onEvent: { await events.event($0) })
        try await waitForScheduler(events)
        let event = await events.snapshot(); XCTAssertTrue(event.finished); XCTAssertFalse(event.failed)
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1)
        let state = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTAssertFalse(state.enabled)
    }

    func testBackgroundAmbiguousSuccessWaitsThenRecoversWithoutRepeatingDelete() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), events = RetentionSchedulerEvents(); await cloud.fail(afterCommit: true)
        let date = now
        let scheduler = ICloudRetentionScheduler(repository: fixture.repository, now: { date }, sleep: { await events.slept($0) })
        try await scheduler.start(approvalID: fixture.approval.approvalID, using: cloud, onEvent: { await events.event($0) })
        try await waitForScheduler(events)
        let event = await events.snapshot(); XCTAssertTrue(event.finished); XCTAssertEqual(event.sleeps, [60])
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1); XCTAssertEqual(counts.reads, 2)
    }

    func testColdSchedulerRespectsDurableWaitBeforeAnySDKAttempt() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        _ = try await fixture.repository.setRetentionScheduleEnabled(true, approvalID: fixture.approval.approvalID)
        _ = try await fixture.repository.scheduleRetentionWake(approvalID: fixture.approval.approvalID,
            for: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 600.0]), now: now)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), events = RetentionSchedulerEvents()
        let date = now.addingTimeInterval(86_400)
        let reopened = try LibraryDatabase(databaseURL: fixture.url)
        let scheduler = ICloudRetentionScheduler(repository: .init(database: reopened, accountID: "cloud"), now: { date }, sleep: { await events.slept($0) })
        try await scheduler.resumeIfEnabled(approvalID: fixture.approval.approvalID, using: cloud, onEvent: { await events.event($0) })
        try await waitForScheduler(events)
        let event = await events.snapshot(); XCTAssertTrue(event.finished); XCTAssertEqual(event.sleeps, [600])
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 1)
    }

    private func waitForGate(_ gate: RetentionSchedulerGate) async throws {
        for _ in 0..<2_000 {
            if await gate.isWaiting() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected a bounded pending callback")
    }

    func testForegroundBurstsDoNotReplaceRetryWaitAndExplicitStopDisablesRestart() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), gate = RetentionSchedulerGate()
        await cloud.fail(afterCommit: false)
        let date = now
        let scheduler = ICloudRetentionScheduler(repository: fixture.repository, now: { date }, sleep: { _ in await gate.wait() })
        try await scheduler.start(approvalID: fixture.approval.approvalID, using: cloud)
        try await waitForGate(gate)
        let before = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        for _ in 0..<5 { try await scheduler.start(approvalID: fixture.approval.approvalID, using: cloud) }
        let unchanged = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID)
        XCTAssertEqual(unchanged, before)
        do { try await scheduler.stop(approvalID: UUID().uuidString); XCTFail("Wrong operation cannot stop the owned timer") } catch {}
        let stillEnabled = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTAssertTrue(stillEnabled.enabled)
        try await scheduler.stop(approvalID: fixture.approval.approvalID)
        let disabled = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTAssertFalse(disabled.enabled)
        try await scheduler.resumeIfEnabled(approvalID: fixture.approval.approvalID, using: cloud)
        await gate.release()
        let counts = await cloud.counts(); XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.sends, 1)
    }

    func testScheduleStopRejectsLatePointResponseWithoutAnyDelete() async throws {
        let fixture = try await fixture(clockMaintenance: true); _ = try await fixture.repository.beginRetentionJob(fixture.approval)
        let cloud = RetentionJobCloud(snapshot: fixture.snapshot), gate = RetentionSchedulerGate()
        await cloud.fetched { await gate.wait() }
        let scheduler = ICloudRetentionScheduler(repository: fixture.repository)
        try await scheduler.start(approvalID: fixture.approval.approvalID, using: cloud)
        try await waitForGate(gate)
        try await scheduler.stop(approvalID: fixture.approval.approvalID)
        await gate.release()
        let counts = await cloud.counts(); XCTAssertEqual(counts.sends, 0)
        let job = try await fixture.repository.retentionJob(approvalID: fixture.approval.approvalID); XCTAssertEqual(job.attempts[0].stage, .pending)
        let state = try await fixture.repository.retentionScheduleState(approvalID: fixture.approval.approvalID); XCTAssertFalse(state.enabled)
    }
}
