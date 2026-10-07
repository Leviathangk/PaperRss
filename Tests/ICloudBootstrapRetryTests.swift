@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private final class BootstrapClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

/// Cancellation deliberately does not resume these sleepers. Releasing an old
/// waiter later verifies that it cannot resurrect a stopped provider session.
private actor BootstrapSleeper {
    private var waits: [(Duration, CheckedContinuation<Void, Never>?)] = []
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { waits.append((duration, $0)) }
    }
    var durations: [Duration] { waits.map(\.0) }
    func release(_ index: Int) {
        waits[index].1?.resume()
        waits[index].1 = nil
    }
    func releaseAll() {
        for index in waits.indices { release(index) }
    }
}

private actor BootstrapProbe: ICloudAccountSyncing {
    nonisolated let supportsAutomaticSync = true
    private(set) var requiresBootstrapRetry = true
    private let records: ICloudRecordRepository
    private var errors: [any Error]
    private var callbacks: [@Sendable (ICloudAutomaticSyncEvent) async -> Void] = []
    private(set) var attempts = 0
    private(set) var preparations = 0
    private(set) var stops = 0

    init(records: ICloudRecordRepository, errors: [any Error] = []) {
        self.records = records; self.errors = errors
    }
    func prepareAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        preparations += 1
        callbacks.append(onEvent)
    }
    func startAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        try await prepareAutomaticSync(onEvent: onEvent)
        try await localChangesAvailable()
    }
    func localChangesAvailable() async throws {
        attempts += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        requiresBootstrapRetry = false
        await callbacks.last?(.started)
        for value in try records.outgoingRecords() {
            try records.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        await callbacks.last?(.completed)
    }
    func fetchChanges() async throws { try await localChangesAvailable() }
    func sendChanges() async throws { try await localChangesAvailable() }
    func stop() async { stops += 1; requiresBootstrapRetry = true }
    func emit(_ error: any Error, session: Int = 0) async { await callbacks[session](.failed(error)) }
    func failNextBootstrap(_ error: any Error) { requiresBootstrapRetry = true; errors.append(error) }
}

final class ICloudBootstrapRetryTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var records: ICloudRecordRepository!
    private var clock: BootstrapClock!
    private var sleeper: BootstrapSleeper!
    private var providers: [ICloudAccountProvider] = []
    private let account = "cloud-bootstrap"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BootstrapTests-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        records = ICloudRecordRepository(database: database, accountID: account)
        try records.activate()
        clock = BootstrapClock()
        sleeper = BootstrapSleeper()
    }
    override func tearDown() async throws {
        for provider in providers { await provider.stop() }
        providers = []
        await sleeper.releaseAll()
        records = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func provider(_ probe: BootstrapProbe, database: LibraryDatabase? = nil) -> ICloudAccountProvider {
        let clock = self.clock!, sleeper = self.sleeper!
        let value = ICloudAccountProvider(accountID: account, database: database ?? self.database,
            sync: probe, bootstrapNow: { clock.now() }, bootstrapSleep: { await sleeper.sleep($0) })
        providers.append(value)
        return value
    }
    private func eventually(_ predicate: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected bootstrap retry condition", file: file, line: line)
    }
    private func state() throws -> AccountSyncStateRecord? {
        try database.read { try AccountSyncStateRecord.fetchOne($0, key: account) }
    }

    func testTransientPolicyUsesBoundedBackoffAndServerWait() {
        let network = CKError(.networkFailure)
        XCTAssertEqual((1...7).map { ICloudBootstrapRetryPolicy.delay(for: network, attempt: $0)! },
                       [2, 4, 8, 16, 32, 60, 60])
        let busy = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0])
        XCTAssertEqual(ICloudBootstrapRetryPolicy.delay(for: busy, attempt: 1), 120)
        let extreme = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: Double.greatestFiniteMagnitude])
        XCTAssertEqual(ICloudBootstrapRetryPolicy.delay(for: extreme, attempt: 1), ICloudBootstrapRetryPolicy.maximumDelay)
        let invalid = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: Double.nan])
        XCTAssertEqual(ICloudBootstrapRetryPolicy.delay(for: invalid, attempt: 2), 4)
        XCTAssertEqual(ICloudBootstrapRetryPolicy.delay(for: ICloudEngineError.temporarilyUnavailable, attempt: 1), 30)
    }

    func testPermanentAndRecoveryErrorsNeverStartBackgroundLoops() {
        let errors: [any Error] = [
            CKError(.quotaExceeded), CKError(.notAuthenticated), CKError(.missingEntitlement),
            CKError(.permissionFailure), CKError(.badContainer), CancellationError(),
            ICloudEngineError.notEntitled, ICloudEngineError.noSystemAccount, ICloudEngineError.restricted,
            ICloudRootError.generationChanged, ICloudRootError.rootMissing,
            ICloudRootError.legacyCloudRequiresReview, ICloudRootError.resetInProgress,
            ICloudRecordError.persistenceFailed
        ]
        for error in errors { XCTAssertNil(ICloudBootstrapRetryPolicy.delay(for: error, attempt: 1)) }
    }

    func testPartialCloudFailureHonorsSlowestTransientAndRejectsMixedPermanentFailure() {
        let first = CKRecord.ID(recordName: "one"), second = CKRecord.ID(recordName: "two")
        let transient = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            first: CKError(.networkUnavailable),
            second: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 50.0])
        ]])
        XCTAssertEqual(ICloudBootstrapRetryPolicy.delay(for: transient, attempt: 2), 50)
        let mixed = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            first: CKError(.networkFailure), second: CKError(.quotaExceeded)
        ]])
        XCTAssertNil(ICloudBootstrapRetryPolicy.delay(for: mixed, attempt: 2))
        XCTAssertNil(ICloudBootstrapRetryPolicy.delay(for: CKError(.partialFailure), attempt: 2))
    }

    func testWaitingWindowIsDurableAndBurstsCannotExtendItOrAcknowledgeIntent() async throws {
        let pending = try records.outgoingRecords()
        let cloud = CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 80.0])
        let deadline = try await records.scheduleBootstrapRetry(for: cloud, now: clock.now())
        clock.advance(10)
        let repeated = try await records.scheduleBootstrapRetry(for: cloud, now: clock.now())
        XCTAssertEqual(repeated, deadline)
        XCTAssertEqual(try records.outgoingRecords(), pending)
        let reopened = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let state = try await ICloudRecordRepository(database: reopened, accountID: account).bootstrapRetryState()
        XCTAssertEqual(state.deadline, deadline)
        XCTAssertEqual(state.attempt, 1)
        XCTAssertEqual(state.revision, 1)
    }

    func testExpiredFailuresIncreaseBackoffAndSuccessOnlyClearsMatchingRevision() async throws {
        let error = CKError(.networkUnavailable)
        _ = try await records.scheduleBootstrapRetry(for: error, now: clock.now())
        let old = try await records.bootstrapRetryState()
        clock.advance(2)
        let next = try await records.scheduleBootstrapRetry(for: error, now: clock.now())
        XCTAssertEqual(next, clock.now().addingTimeInterval(4))
        try await records.clearBootstrapRetry(expectedRevision: old.revision)
        let newer = try await records.bootstrapRetryState()
        XCTAssertEqual(newer.deadline, next)
        XCTAssertEqual(newer.attempt, 2)
        try await records.clearBootstrapRetry(expectedRevision: newer.revision)
        let cleared = try await records.bootstrapRetryState()
        XCTAssertNil(cleared.deadline)
        XCTAssertEqual(cleared.attempt, 0)
        XCTAssertGreaterThan(cleared.revision, newer.revision)
    }

    func testBootstrapFailureRetriesWithoutNewUserEditOrRSSRefresh() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.networkFailure)])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        XCTAssertEqual(try state()?.consecutiveFailureCount, 1)
        XCTAssertNil(try state()?.lastSyncCompletedAt)
        XCTAssertNil(try state()?.lastArticleFetchAt)
        let duration = await sleeper.durations
        XCTAssertEqual(duration, [.seconds(2)])
        clock.advance(2)
        await sleeper.release(0)
        try await eventually { try self.state()?.lastSyncCompletedAt != nil && self.state()?.lastError == nil }
        let retry = try await records.bootstrapRetryState()
        XCTAssertNil(retry.deadline)
        XCTAssertEqual(try state()?.consecutiveFailureCount, 0)
        XCTAssertNil(try state()?.lastArticleFetchAt)
    }

    func testPersistedWaitInstallsCallbacksOnRestartWithoutEarlyCloudRequest() async throws {
        _ = try await records.scheduleBootstrapRetry(for: CKError(.requestRateLimited,
            userInfo: [CKErrorRetryAfterKey: 90.0]), now: clock.now())
        let reopened = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let reopenedRecords = ICloudRecordRepository(database: reopened, accountID: account)
        let probe = BootstrapProbe(records: reopenedRecords)
        let provider = provider(probe, database: reopened)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        await provider.resumeAutomaticSync(fetchRemote: true)
        try await Task.sleep(for: .milliseconds(450))
        let attempts = await probe.attempts, preparations = await probe.preparations
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(preparations, 1)
        let durations = await sleeper.durations
        XCTAssertEqual(durations, [.seconds(90)])
        let retry = try await reopenedRecords.bootstrapRetryState()
        XCTAssertEqual(retry.attempt, 1)
        clock.advance(90)
        await sleeper.release(0)
        try await eventually {
            let attempts = await probe.attempts, waiting = await probe.requiresBootstrapRetry
            return attempts > 0 && !waiting
        }
        try await eventually { try await reopenedRecords.bootstrapRetryState().deadline == nil }
    }

    func testRepeatedCallbacksAndLocalEditsKeepOneTimerAndServerDeadline() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.serviceUnavailable,
            userInfo: [CKErrorRetryAfterKey: 120.0])])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        let initial = try await records.bootstrapRetryState()
        clock.advance(10)
        for _ in 0..<8 { await probe.emit(CKError(.networkFailure)) }
        try database.write {
            try FeedRecord(id: UUID().uuidString, accountID: account, title: "Offline edit",
                feedURL: "https://example.com/rss", updatedAt: 1).save($0)
        }
        await provider.resumeAutomaticSync(fetchRemote: true)
        try await Task.sleep(for: .milliseconds(450))
        let retry = try await records.bootstrapRetryState()
        XCTAssertEqual(retry.deadline, initial.deadline)
        XCTAssertEqual(retry.attempt, 1)
        let attempts = await probe.attempts, durations = await sleeper.durations
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(durations.count, 1)
        XCTAssertGreaterThan(try records.pendingCount(), 0)
        XCTAssertEqual(try state()?.consecutiveFailureCount, 1)
    }

    func testSDKOwnedRecordRetryDoesNotCreateBootstrapTimer() async throws {
        let probe = BootstrapProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        await probe.emit(CKError(.networkFailure))
        let retry = try await records.bootstrapRetryState()
        XCTAssertNil(retry.deadline)
        let durations = await sleeper.durations
        XCTAssertTrue(durations.isEmpty)
    }

    func testForegroundRefreshFailureStillSchedulesRecoveryWhileRefreshTaskIsRunning() async throws {
        let probe = BootstrapProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        // Settle the initial metadata notification before simulating a broken
        // engine; this test specifically exercises the foreground path.
        try await Task.sleep(for: .milliseconds(450))
        await probe.failNextBootstrap(CKError(.networkFailure))
        _ = try await provider.refresh(reason: .manual)
        try await eventually { await self.sleeper.durations.count == 1 }
        let retry = try await records.bootstrapRetryState()
        XCTAssertEqual(retry.attempt, 1)
        XCTAssertEqual(try state()?.consecutiveFailureCount, 1)
        clock.advance(2)
        await sleeper.release(0)
        try await eventually { try self.state()?.lastError == nil && self.state()?.consecutiveFailureCount == 0 }
    }

    func testPauseCancelsTimerAndRetainsCapturedLocalEdits() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.networkFailure)])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        try records.pause(reason: "rootMissing")
        try await eventually { await probe.stops > 0 }
        try database.write {
            try FeedRecord(id: UUID().uuidString, accountID: account, title: "Keep",
                feedURL: "https://example.com/paused", updatedAt: 1).save($0)
        }
        clock.advance(2)
        await sleeper.release(0)
        try await Task.sleep(for: .milliseconds(450))
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertGreaterThan(try records.pendingCount(), 0)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT capture_enabled FROM icloud_sync_scope") }, 1)
        XCTAssertNil(try state()?.lastSyncCompletedAt)
    }

    func testDisabledAccountCannotBeResurrectedByTimerOrOldCallbacks() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.networkFailure)])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: [account]) }
        try await eventually { await probe.stops > 0 }
        let before = try state()
        clock.advance(2)
        await sleeper.release(0)
        await probe.emit(CKError(.networkFailure))
        try await Task.sleep(for: .milliseconds(450))
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try state(), before)
    }

    func testStoppedTimerCannotActOnRestartedSession() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.networkFailure)])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        await provider.stop()
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 2 }
        clock.advance(2)
        await sleeper.release(0)
        try await Task.sleep(for: .milliseconds(100))
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(try state()?.lastSyncCompletedAt)
        await sleeper.release(1)
        try await eventually { try self.state()?.lastSyncCompletedAt != nil }
    }

    func testEachActualFailedAttemptSchedulesOneIncreasingDelay() async throws {
        let probe = BootstrapProbe(records: records, errors: [CKError(.networkFailure), CKError(.networkUnavailable)])
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await self.sleeper.durations.count == 1 }
        clock.advance(2)
        await sleeper.release(0)
        try await eventually { await self.sleeper.durations.count == 2 }
        let durations = await sleeper.durations
        XCTAssertEqual(durations, [.seconds(2), .seconds(4)])
        XCTAssertEqual(try state()?.consecutiveFailureCount, 2)
        clock.advance(4)
        await sleeper.release(1)
        try await eventually { try self.state()?.lastSyncCompletedAt != nil }
    }

    func testV17UpgradePreservesGenerationHistoryAndDoesNotActivateSynchronization() throws {
        let url = directory.appendingPathComponent("v17.sqlite")
        let pool = try DatabasePool(path: url.path)
        try DatabaseMigrations.migrator.migrate(pool, upTo: "v17-icloud-root-generation")
        let epoch = UUID().uuidString, feed = UUID().uuidString
        try pool.write { db in
            try AccountRecord(id: "local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: account, type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: feed, accountID: "local", title: "Keep", feedURL: "https://example.com/keep", updatedAt: 1).save(db)
            try ItemRecord(id: "old", accountID: "local", externalID: "old", feedID: feed,
                createdAt: 1, updatedAt: 1, sourceItemID: "opaque-ID").save(db)
            try ArticleStateRecord(itemID: "old", isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
            try db.execute(sql: """
                INSERT INTO icloud_sync_scope (account_id, capture_enabled, cloud_generation, engine_state, initialized_zones)
                VALUES (?, 0, ?, ?, 3)
                """, arguments: [account, epoch, Data([1, 4])])
        }
        try DatabaseMigrations.migrator.migrate(pool)
        try pool.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cloud_generation FROM icloud_sync_scope"), epoch)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT engine_state FROM icloud_sync_scope"), Data([1, 4]))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT capture_enabled FROM icloud_sync_scope"), 0)
            XCTAssertNil(try Double.fetchOne(db, sql: "SELECT root_retry_at FROM icloud_sync_scope"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT root_retry_attempt FROM icloud_sync_scope"), 0)
            XCTAssertEqual(try ItemRecord.fetchOne(db, key: "old")?.sourceItemID, "opaque-ID")
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isRead == true)
            XCTAssertTrue(try ArticleStateRecord.fetchOne(db, key: "old")?.isStarred == true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM icloud_sync_changes"), 0)
            XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
        }
    }
}
