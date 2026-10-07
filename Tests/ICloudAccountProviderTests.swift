@preconcurrency import CloudKit
import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ICloudProviderProbe: ICloudAccountSyncing {
    private var events: [String] = []
    private var progress: [AccountRefreshProgress?] = []
    let records: ICloudRecordRepository
    let incoming: [ICloudReceivedRecord]
    let failsFetch: Bool
    let failsSend: Bool

    init(records: ICloudRecordRepository, incoming: [ICloudReceivedRecord] = [], failsFetch: Bool = false, failsSend: Bool = false) {
        self.records = records; self.incoming = incoming
        self.failsFetch = failsFetch; self.failsSend = failsSend
    }
    func fetchChanges() async throws {
        events.append("fetch")
        if failsFetch { throw NSError(domain: "secret-private-url", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-credential"]) }
        try records.receive(incoming)
    }
    func sendChanges() async throws {
        events.append("send")
        let prepared = try records.outgoingRecords()
        if failsSend { throw URLError(.notConnectedToInternet) }
        for value in prepared {
            try records.confirm(value, server: .init(envelope: value.envelope, systemFields: nil, bodyData: value.bodyData))
        }
    }
    func stop() async { events.append("stop") }
    func recordRSS() { events.append("rss") }
    func recordProgress(_ value: AccountRefreshProgress?) { progress.append(value) }
    func snapshot() -> ([String], [AccountRefreshProgress?]) { (events, progress) }
}

final class ICloudAccountProviderTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var records: ICloudRecordRepository!
    private let account = "icloud-test"
    private let feed = UUID().uuidString
    private let feedURL = URL(string: "https://example.com/rss")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudProvider-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write {
            try AccountRecord(id: account, type: "iCloud", displayName: "iCloud", createdAt: 1, updatedAt: 1).save($0)
        }
        records = ICloudRecordRepository(database: database, accountID: account)
        try records.activate()
    }
    override func tearDownWithError() throws {
        records = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func addFeed() throws {
        try database.write { try FeedRecord(id: feed, accountID: account, title: "Feed", feedURL: feedURL.absoluteString, updatedAt: 1).save($0) }
    }

    func testFeedInTwoOPMLFoldersIsFetchedOnlyOncePerRefresh() async throws {
        try addFeed()
        try database.write { db in
            for name in ["One", "Two"] {
                let folder = UUID().uuidString
                try FolderRecord(id: folder, accountID: account, name: name, updatedAt: 1).save(db)
                try FeedFolderRecord(feedID: feed, folderID: folder).save(db)
            }
        }
        let probe = ICloudProviderProbe(records: records)
        let result = try await provider(probe).refresh(reason: .manual)
        XCTAssertEqual(result.status, .success)
        let events = await probe.snapshot().0
        XCTAssertEqual(events.filter { $0 == "rss" }.count, 1)
    }
    private func provider(_ probe: ICloudProviderProbe) -> ICloudAccountProvider {
        ICloudAccountProvider(
            accountID: account, database: database,
            customFeedFetcher: { _, _ in
                await probe.recordRSS()
                return .updated(ParsedFeed(title: "Feed", siteURL: nil, iconURL: nil,
                    entries: [ParsedFeedEntry(id: "source-guid", title: "Article", author: nil, url: nil,
                                             publishedAt: nil, summary: "Feed body", contentHTML: "<p>Body</p>")]),
                    etag: nil, lastModified: nil)
            },
            sync: probe, onProgress: { await probe.recordProgress($0) }
        )
    }
    private func syncState() throws -> AccountSyncStateRecord {
        try database.read { try XCTUnwrap(AccountSyncStateRecord.fetchOne($0, key: account)) }
    }
    private func incomingRead() throws -> ICloudReceivedRecord {
        let article = try XCTUnwrap(ICloudSyncIdentity.articleRecordName(feedURL: feedURL, sourceItemID: "source-guid"))
        return try .init(envelope: ICloudRecordEnvelope(
            kind: .read, recordName: "read-v1:" + article.dropFirst("article-v1:".count),
            feedURL: feedURL.absoluteString, sourceItemID: "source-guid",
            fields: ["value": .init(value: .flag(true), version: .init(counter: 50, deviceID: UUID().uuidString.lowercased()))]),
            systemFields: nil)
    }

    func testFetchRSSInboxAndSendOrderRestoresStateAndPersistsSuccessfulHealth() async throws {
        try addFeed()
        let probe = ICloudProviderProbe(records: records, incoming: [try incomingRead()])
        let result = try await provider(probe).refresh(reason: .manual)
        XCTAssertEqual(result.status, .success)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.0, ["fetch", "rss", "send"])
        XCTAssertNil(snapshot.1.last!)
        XCTAssertEqual(snapshot.1.compactMap { $0 }.last?.completed, 1)
        XCTAssertTrue(try database.read { try XCTUnwrap(ArticleStateRecord.fetchOne($0, sql: "SELECT * FROM article_states")).isRead })
        let state = try syncState()
        XCTAssertTrue(state.initialSyncCompleted)
        XCTAssertNotNil(state.lastSyncCompletedAt)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(try records.pendingCount(), 0)
    }

    func testCloudFetchFailureStillFetchesRSSAndReportsSafeErrorWithoutSending() async throws {
        try addFeed()
        let probe = ICloudProviderProbe(records: records, failsFetch: true)
        let result = try await provider(probe).refresh(reason: .scheduled)
        guard case .failed(let message) = result.status else { return XCTFail("Cloud failure must not report success") }
        XCTAssertFalse(message.contains("private-credential"))
        XCTAssertFalse(message.contains("secret-private-url"))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.0, ["fetch", "rss"])
        XCTAssertNil(snapshot.1.last!)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        XCTAssertNil(try syncState().lastSyncCompletedAt)
        XCTAssertEqual(try syncState().consecutiveFailureCount, 1)
        XCTAssertGreaterThan(try records.pendingCount(), 0)
    }

    func testFailedSendRetainsQueueAndDoesNotAdvanceSuccessfulSyncTime() async throws {
        try addFeed()
        let probe = ICloudProviderProbe(records: records, failsSend: true)
        let result = try await provider(probe).refresh(reason: .manual)
        guard case .failed = result.status else { return XCTFail("Send failure must not report success") }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.0, ["fetch", "rss", "send"])
        XCTAssertNil(try syncState().lastSyncCompletedAt)
        XCTAssertGreaterThan(try records.pendingCount(), 0)
    }

    func testRSSFailurePreservesIndependentCloudSyncAndReportsFailure() async throws {
        try addFeed()
        let probe = ICloudProviderProbe(records: records)
        let provider = ICloudAccountProvider(accountID: account, database: database,
            customFeedFetcher: { _, _ in throw URLError(.badServerResponse) }, sync: probe)
        let result = try await provider.refresh(reason: .manual)
        guard case .failed = result.status else { return XCTFail("RSS failure must be visible") }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.0, ["fetch", "send"])
        XCTAssertNil(try syncState().lastSyncCompletedAt)
        XCTAssertEqual(try records.pendingCount(), 0)
    }

    func testPausedScopeKeepsRSSAvailableAndFinishesProgress() async throws {
        try addFeed()
        try records.pause(reason: "accountChanged")
        let probe = ICloudProviderProbe(records: records, failsFetch: true)
        let result = try await provider(probe).refresh(reason: .manual)
        guard case .failed = result.status else { return XCTFail("Paused scope must stay failed") }
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") }, 1)
        let snapshot = await probe.snapshot()
        XCTAssertNil(snapshot.1.last!)
    }

    func testFolderCRUDUsesCloudIdentityAndDoesNotRequireCloudNetwork() async throws {
        let probe = ICloudProviderProbe(records: records, failsFetch: true)
        let provider = provider(probe)
        let folder = try await provider.addFolder(name: "News")
        XCTAssertNotNil(UUID(uuidString: folder.id))
        let added = try await provider.addFeed(url: feedURL, title: "Feed", folder: "News")
        XCTAssertEqual(added.folder, "News")
        try await provider.deleteFolder(name: "News")
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM folders") }, 0)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 1)
        let events = await probe.snapshot().0
        XCTAssertTrue(events.isEmpty)
    }

    func testCoordinatorRoutesByProviderTypeAndExcludesCustomLocalAccountID() async throws {
        try database.write {
            try AccountRecord(id: "custom-local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save($0)
        }
        let probe = ICloudProviderProbe(records: records)
        let coordinator = SyncCoordinator()
        await coordinator.registerProvider(LocalAccountProvider(accountID: "custom-local", database: database))
        await coordinator.registerProvider(provider(probe))
        let results = await coordinator.refreshRemoteAccounts()
        XCTAssertEqual(Set(results.keys), [account])
        let events = await probe.snapshot().0
        XCTAssertEqual(events, ["fetch", "send"])
    }

    func testZoneInitializationIsIndependentOfEngineSerializationAndPersistsEachZone() throws {
        XCTAssertEqual(try records.missingZones(), ICloudRecordZone.allCases)
        try records.persistEngineState(Data([1]))
        XCTAssertEqual(try records.missingZones(), ICloudRecordZone.allCases)
        try records.markZoneInitialized(.library)
        XCTAssertEqual(try records.missingZones(), [.articles])
        let reopened = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let restarted = ICloudRecordRepository(database: reopened, accountID: account)
        XCTAssertEqual(try restarted.missingZones(), [.articles])
        try restarted.markZoneInitialized(.articles)
        XCTAssertTrue(try records.missingZones().isEmpty)
        try restarted.pause(reason: "zoneDeleted")
        XCTAssertThrowsError(try records.missingZones())
    }

    func testCloudFailureMessagesDistinguishActionableCausesAndExcludeServerDescriptions() {
        let cases: [(CKError.Code, String)] = [
            (.quotaExceeded, I18N.localized("iCloud 存储空间不足，请释放空间后再同步。", englishFallback: "iCloud storage is full. Free up space and sync again.")),
            (.requestRateLimited, I18N.localized("iCloud 暂时繁忙，稍后会重试；本地更改已保留。", englishFallback: "iCloud is busy. Sync will retry; your local changes are retained.")),
            (.permissionFailure, I18N.localized("iCloud 连接配置不可用，本机资料已保留。", englishFallback: "The iCloud connection configuration is unavailable. Your local data is retained.")),
            (.notAuthenticated, I18N.localized("请先在系统设置中登录 iCloud。", englishFallback: "Sign in to iCloud in System Settings."))
        ]
        for (code, expected) in cases {
            let cloud = CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "https://private.example/rss?token=secret", CKErrorRetryAfterKey: 90]))
            let message = ICloudSyncFailure.message(for: cloud)
            XCTAssertEqual(message, expected)
            XCTAssertFalse(message.contains("private.example"))
            XCTAssertFalse(message.contains("secret"))
        }
        XCTAssertNotEqual(ICloudSyncFailure.message(for: ICloudEngineError.restricted),
                          ICloudSyncFailure.message(for: ICloudEngineError.temporarilyUnavailable))
    }
}
