import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor AutomaticCloudProbe: ICloudAccountSyncing {
    nonisolated let supportsAutomaticSync = true
    let records: ICloudRecordRepository
    private var callbacks: [@Sendable (ICloudAutomaticSyncEvent) async -> Void] = []
    private var announcements = 0
    private var stops = 0
    private var rssFetches = 0
    private var running = 0
    private var failuresRemaining: Int
    private let acknowledgementLimit: Int?

    init(records: ICloudRecordRepository, failures: Int = 0, acknowledgementLimit: Int? = nil) {
        self.records = records
        failuresRemaining = failures
        self.acknowledgementLimit = acknowledgementLimit
    }
    func startAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        callbacks.append(onEvent)
    }
    func localChangesAvailable() async throws {
        announcements += 1
        running += 1
        defer { running -= 1 }
        let callback = callbacks.last
        await callback?(.started)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "private-token-url", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-secret"])
        }
        let values = try records.outgoingRecords()
        for value in values.prefix(acknowledgementLimit ?? values.count) {
            try records.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
        await callback?(.changed)
        await callback?(.completed)
    }
    func fetchChanges() async throws {}
    func sendChanges() async throws { try await localChangesAvailable() }
    func stop() async { stops += 1 }
    func recordRSS() { rssFetches += 1 }
    func emit(_ event: ICloudAutomaticSyncEvent, session: Int = 0) async {
        await callbacks[session](event)
    }
    func counts() -> (announcements: Int, stops: Int, starts: Int, rss: Int, running: Int) {
        (announcements, stops, callbacks.count, rssFetches, running)
    }
}

private actor AutomaticRSSGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isReleased = false
    func waitOnce() async {
        if hasEntered { return }
        hasEntered = true
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
    }
    func entered() -> Bool { hasEntered }
    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

final class ICloudAutomaticSyncTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var records: ICloudRecordRepository!
    private var providers: [ICloudAccountProvider] = []
    private let account = "cloud-automatic"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAutomatic-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        records = ICloudRecordRepository(database: database, accountID: account)
        try records.activate()
    }
    override func tearDown() async throws {
        for provider in providers { await provider.stop() }
        providers = []
        records = nil
        database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func provider(_ probe: AutomaticCloudProbe, gate: AutomaticRSSGate? = nil) -> ICloudAccountProvider {
        let provider = ICloudAccountProvider(accountID: account, database: database, customFeedFetcher: { _, _ in
            await gate?.waitOnce()
            await probe.recordRSS()
            return .updated(.init(title: "Feed", siteURL: nil, iconURL: nil, entries: []), etag: nil, lastModified: nil)
        }, sync: probe)
        providers.append(provider)
        return provider
    }
    private func eventually(_ predicate: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected automatic sync condition", file: file, line: line)
    }
    private func state() throws -> AccountSyncStateRecord? {
        try database.read { try AccountSyncStateRecord.fetchOne($0, key: account) }
    }
    @discardableResult
    private func addFeed(title: String = "Feed") throws -> String {
        let id = UUID().uuidString
        try database.write { try FeedRecord(id: id, accountID: account, title: title, feedURL: "https://example.com/\(id)", updatedAt: 1).save($0) }
        return id
    }
    private func settled(_ probe: AutomaticCloudProbe, count: Int) async throws {
        try await eventually {
            let counts = await probe.counts()
            let snapshot = try await self.records.accountSnapshot()
            return counts.announcements >= count && counts.running == 0 && snapshot.pendingChanges == 0
        }
    }

    func testTransactionalBurstCoalescesAndConfirmationsDoNotEchoOrRefreshRSS() async throws {
        let probe = AutomaticCloudProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await settled(probe, count: 1)
        let feed = try addFeed()
        try database.write { db in
            for number in 0..<40 {
                let item = UUID().uuidString
                try ItemRecord(id: item, accountID: account, externalID: item, feedID: feed, createdAt: 1, updatedAt: 1, sourceItemID: "guid-\(number)").save(db)
                try ArticleStateRecord(itemID: item, isRead: true, isStarred: false, dateArrived: 1, updatedAt: 1).save(db)
            }
            try db.execute(sql: "UPDATE feeds SET title = 'Renamed', sort_order = 2 WHERE id = ?", arguments: [feed])
        }
        try await settled(probe, count: 2)
        try await Task.sleep(for: .milliseconds(600))
        let counts = await probe.counts()
        XCTAssertEqual(counts.announcements, 2)
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.rss, 0)
        XCTAssertNil(try state()?.lastArticleFetchAt)
    }

    func testLocalAndReaderAccountsNeverWakeCloudObservation() async throws {
        let probe = AutomaticCloudProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await settled(probe, count: 1)
        try database.write { db in
            try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save(db)
            try AccountRecord(id: "reader", type: "freshRSS", displayName: "Reader", createdAt: 1, updatedAt: 1).save(db)
            try FeedRecord(id: UUID().uuidString, accountID: "local-default", title: "Local", feedURL: "https://local.example/rss", updatedAt: 1).save(db)
            try FeedRecord(id: UUID().uuidString, accountID: "reader", title: "Reader", feedURL: "https://reader.example/rss", updatedAt: 1).save(db)
        }
        try await Task.sleep(for: .milliseconds(600))
        let counts = await probe.counts()
        XCTAssertEqual(counts.announcements, 1)
    }

    func testPauseKeepsCaptureAndResumesOnlyAfterScopeIsExplicitlyUnpaused() async throws {
        let probe = AutomaticCloudProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await settled(probe, count: 1)
        try records.pause(reason: "zoneDeleted")
        try await eventually { await probe.counts().stops > 0 }
        try addFeed()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(try records.pendingCount(), 0)
        let paused = await probe.counts()
        XCTAssertEqual(paused.announcements, 1)
        // This is an isolated recovery fixture, never automatic product behavior.
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET pause_reason = NULL") }
        try await settled(probe, count: 2)
    }

    func testDisabledAccountStopsAndReenableReplaysDurableWorkWithoutBaselineCopy() async throws {
        let probe = AutomaticCloudProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await settled(probe, count: 1)
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 0 WHERE id = ?", arguments: [account]) }
        try await eventually { await probe.counts().stops > 0 }
        try addFeed()
        try await Task.sleep(for: .milliseconds(600))
        let disabled = await probe.counts()
        XCTAssertEqual(disabled.announcements, 1)
        XCTAssertGreaterThan(try records.pendingCount(), 0)
        try database.write { try $0.execute(sql: "UPDATE accounts SET is_enabled = 1 WHERE id = ?", arguments: [account]) }
        await provider.startAutomaticSync()
        try await settled(probe, count: 2)
        let enabled = await probe.counts()
        XCTAssertEqual(enabled.starts, 2)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 1)
    }

    func testTemporaryFailureKeepsQueueAndForegroundRetryClearsSafeError() async throws {
        let probe = AutomaticCloudProbe(records: records, failures: 1)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { try self.state()?.lastError != nil }
        let failed = try XCTUnwrap(state())
        XCTAssertNil(failed.lastSyncCompletedAt)
        XCTAssertFalse(failed.lastError!.contains("private-"))
        let pending = try await records.accountSnapshot()
        XCTAssertGreaterThan(pending.pendingChanges, 0)
        await provider.resumeAutomaticSync()
        try await settled(probe, count: 2)
        try await eventually { try self.state()?.lastError == nil && self.state()?.lastSyncCompletedAt != nil }
        XCTAssertEqual(try state()?.consecutiveFailureCount, 0)
        let counts = await probe.counts()
        XCTAssertEqual(counts.rss, 0)
    }

    func testCallbacksFromStoppedSessionCannotChangeRestartedHealth() async throws {
        let probe = AutomaticCloudProbe(records: records)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await settled(probe, count: 1)
        await provider.stop()
        await provider.startAutomaticSync()
        try await settled(probe, count: 2)
        let before = try state()
        await probe.emit(.failed(ICloudRecordError.accountChanged), session: 0)
        await probe.emit(.completed, session: 0)
        XCTAssertEqual(try state(), before)
    }

    func testCompletedOperationCannotClaimSuccessBeforePendingChangesAreConfirmed() async throws {
        let probe = AutomaticCloudProbe(records: records, acknowledgementLimit: 0)
        let provider = provider(probe)
        await provider.startAutomaticSync()
        try await eventually { await probe.counts().announcements > 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try state()?.lastSyncCompletedAt)
        XCTAssertNotEqual(try state()?.initialSyncCompleted, true)
        let snapshot = try await records.accountSnapshot()
        XCTAssertGreaterThan(snapshot.pendingChanges, 0)
    }

    func testReopenedDatabaseReplaysPendingWorkWithoutANewUserEdit() async throws {
        try addFeed()
        _ = try records.outgoingRecords()
        let reopened = try LibraryDatabase(databaseURL: URL(fileURLWithPath: database.databasePath))
        let restartedRecords = ICloudRecordRepository(database: reopened, accountID: account)
        let probe = AutomaticCloudProbe(records: restartedRecords)
        let restarted = ICloudAccountProvider(accountID: account, database: reopened, sync: probe)
        providers.append(restarted)
        await restarted.startAutomaticSync()
        try await eventually {
            let snapshot = try await restartedRecords.accountSnapshot()
            let counts = await probe.counts()
            return counts.announcements == 1 && counts.running == 0 && snapshot.pendingChanges == 0
        }
        XCTAssertEqual(try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 1)
        XCTAssertEqual(try restartedRecords.pendingCount(), 0)
    }

    func testFullRefreshRequestedDuringSelectedRefreshStillFetchesAllFeeds() async throws {
        let first = try addFeed(), second = try addFeed(title: "Second")
        let probe = AutomaticCloudProbe(records: records), gate = AutomaticRSSGate()
        let provider = provider(probe, gate: gate)
        let selected = Task { try await provider.refresh(feedIDs: [UUID(uuidString: first)!], reason: .manual) }
        try await eventually { await gate.entered() }
        let all = Task { try await provider.refresh(reason: .manual) }
        await Task.yield()
        await gate.release()
        _ = try await selected.value
        _ = try await all.value
        let counts = await probe.counts()
        XCTAssertEqual(counts.rss, 3)
        XCTAssertNotEqual(first, second)
    }
}
