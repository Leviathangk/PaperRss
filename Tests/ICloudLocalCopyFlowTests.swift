import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor CopyRestoreGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor CopyFlowSync: ICloudAccountSyncing {
    let database: LibraryDatabase
    private var events: [String] = []
    private var gate: CopyRestoreGate?
    private var incoming: [ICloudReceivedRecord] = []
    private var failRestore = false, failAnnouncement = false
    init(database: LibraryDatabase) { self.database = database }
    func fetchChanges() async throws { events.append("fetch") }
    func sendChanges() async throws { events.append("send") }
    func stop() async { events.append("stop") }
    func localChangesAvailable() async throws {
        events.append("announce")
        if failAnnouncement { throw NSError(domain: "private-rss-url", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-token"]) }
    }
    func restoreForLocalCopy() async throws -> ICloudLocalCopyRepository.Context {
        events.append("restore")
        if let gate { self.gate = nil; await gate.wait() }
        if failRestore { throw URLError(.notConnectedToInternet) }
        let account = try database.read { try AccountRecord.filter(Column("type") == "iCloud").fetchOne($0)! }
        let records = ICloudRecordRepository(database: database, accountID: account.id)
        try records.receive(incoming)
        return try database.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT user_fingerprint, cloud_generation FROM icloud_sync_scope WHERE account_id = ?", arguments: [account.id])!
            return .init(userFingerprint: row["user_fingerprint"], generation: row["cloud_generation"])
        }
    }
    func holdNextRestore(_ gate: CopyRestoreGate) { self.gate = gate }
    func setIncoming(_ records: [ICloudReceivedRecord]) { incoming = records }
    func setFailures(restore: Bool = false, announcement: Bool = false) { failRestore = restore; failAnnouncement = announcement }
    func snapshot() -> [String] { events }
}

@MainActor
final class ICloudLocalCopyFlowTests: XCTestCase {
    private var store: AppStore!
    private var sync: CopyFlowSync!
    private var cloud: AccountRecord!
    private let generation = "00000000-0000-0000-0000-000000000001"

    override func setUp() async throws {
        store = AppStore(testDatabase: .empty)
        sync = CopyFlowSync(database: store.libraryDatabase)
        cloud = try await store.createICloudAccount(fingerprint: "test-user", sync: sync)
        try store.libraryDatabase.write { db in
            try db.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ?, initialized_zones = 3 WHERE account_id = ?",
                           arguments: [generation, cloud.id])
        }
    }
    override func tearDown() async throws {
        try await store.removeAccount(accountID: cloud.id)
        let directory = URL(fileURLWithPath: store.libraryDatabase.databasePath).deletingLastPathComponent()
        cloud = nil; sync = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func addLocal(_ address: String = "https://local.example/rss", article: Bool = false) throws -> Feed {
        let feed = try store.localProvider.addFeed(title: "Local", feedURL: URL(string: address)!)
        if article {
            try store.libraryDatabase.write { db in
                _ = try ArticleRepository(database: store.libraryDatabase).mergeParsedEntries(feedID: feed.id.uuidString,
                    parsedEntries: [.init(id: "opaque-guid", title: "RSS Article", author: nil, url: nil, publishedAt: nil,
                                         summary: "RSS Summary", contentHTML: "<p>RSS body</p>")], in: db)
                try db.execute(sql: "UPDATE article_states SET is_read = 1, is_starred = 1 WHERE item_id IN (SELECT id FROM items WHERE account_id = 'local-default')")
            }
        }
        store.reloadState()
        return feed
    }
    private func catalog() async throws -> ICloudCopySourceCatalog {
        try await store.iCloudCopySourceCatalog(sourceAccountID: "local-default")
    }
    private func selection(_ feeds: Feed...) -> ICloudCopySelection {
        .init(feedIDs: Set(feeds.map { $0.id.uuidString }), folderIDs: [], includeReliableArticles: true)
    }
    private func prepare(_ selection: ICloudCopySelection, catalog: ICloudCopySourceCatalog? = nil) async throws -> ICloudCopyReview {
        let source: ICloudCopySourceCatalog
        if let catalog { source = catalog } else { source = try await self.catalog() }
        return try await store.prepareICloudLocalCopyAfterEntitlementCheck(catalog: source, selection: selection)
    }
    private func rows() throws -> [Row] {
        try store.libraryDatabase.read { db in
            var result: [Row] = []
            for table in ["feeds", "folders", "feed_folders", "items", "articles", "article_states", "icloud_sync_scope",
                          "icloud_sync_changes", "icloud_content_changes", "icloud_records", "icloud_record_mappings"] {
                result += try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }
    private func waitForGate(_ gate: CopyRestoreGate) async throws {
        for _ in 0..<100 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "CopyFlowTestTimeout", code: 1)
    }

    func testCatalogStaysLocalAndRedactsFeedAndWebsiteCredentials() async throws {
        _ = try addLocal("https://user:private-password@private.example/rss")
        let website = try addLocal("https://public.example/rss")
        try store.libraryDatabase.write { try $0.execute(sql: "UPDATE feeds SET site_url = 'https://user:site-password@private.example/' WHERE id = ?", arguments: [website.id.uuidString]) }
        let malformed = try addLocal("https://malformed.example/rss")
        try store.libraryDatabase.write { try $0.execute(sql: "UPDATE feeds SET site_url = 'https://user:malformed-password@private.example/path with space' WHERE id = ?", arguments: [malformed.id.uuidString]) }
        let before = try rows(), network = await sync.snapshot()
        let result = try await catalog()
        XCTAssertEqual(result.feeds.count, 3)
        XCTAssertTrue(result.feeds.allSatisfy { $0.blocked != nil && $0.address == nil && $0.siteAddress == nil })
        XCTAssertFalse(String(reflecting: result).contains("private-password"))
        XCTAssertFalse(String(reflecting: result).contains("site-password"))
        XCTAssertFalse(String(reflecting: result).contains("malformed-password"))
        XCTAssertEqual(try rows(), before)
        let after = await sync.snapshot()
        XCTAssertEqual(after, network)
    }

    func testPrepareRestoresTargetWithoutCopyAndConfirmationCommitsAndReloadsProjection() async throws {
        let local = try addLocal(article: true)
        let before = try rows()
        let review = try await prepare(selection(local))
        XCTAssertEqual(review.counts.feeds, 1); XCTAssertEqual(review.counts.articles, 1)
        XCTAssertEqual(try rows(), before)
        let eventsBefore = await sync.snapshot()
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: false); XCTFail("Must require privacy review") }
        catch ICloudLocalCopyError.reviewRequired {}
        let eventsAfter = await sync.snapshot()
        XCTAssertEqual(eventsBefore, eventsAfter)
        let result = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true)
        XCTAssertEqual(result.counts.feeds, 1); XCTAssertEqual(result.counts.rssBodies, 1); XCTAssertNil(result.syncWarning)
        XCTAssertEqual(store.feeds(for: cloud.id).count, 1)
        XCTAssertEqual(store.feeds(for: "local-default").map(\.id), [local.id])
        let events = await sync.snapshot()
        XCTAssertEqual(events.suffix(3), ["restore", "restore", "announce"])
        XCTAssertGreaterThan(try store.libraryDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE is_pending = 1")! }, 0)
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("One confirmation only") }
        catch ICloudLocalCopyError.stalePlan {}
    }

    func testSourceAddressChangingBeforePlanPreparationNeedsNewCatalogWithoutNetwork() async throws {
        let feed = try addLocal("https://local.example/rss?a=1")
        let source = try await catalog(), beforeNetwork = await sync.snapshot()
        try store.libraryDatabase.write { try $0.execute(sql: "UPDATE feeds SET feed_url = 'https://private.example/new-token/rss' WHERE id = ?", arguments: [feed.id.uuidString]) }
        let before = try rows()
        do {
            _ = try await prepare(.init(feedIDs: [feed.id.uuidString], folderIDs: [], includeReliableArticles: true, reviewedLinkIDs: [feed.id.uuidString]), catalog: source)
            XCTFail("Old link review cannot authorize a new address")
        } catch ICloudLocalCopyError.stalePlan {}
        XCTAssertEqual(try rows(), before)
        let afterNetwork = await sync.snapshot()
        XCTAssertEqual(afterNetwork, beforeNetwork)
    }

    func testOrphanTargetStateProtectsWholeFeedAndOnlyNewFeedCopies() async throws {
        let existing = try addLocal(), new = try addLocal("https://new.example/rss")
        let url = existing.feedURL
        let article = try ICloudSyncIdentity.articleRecordName(feedURL: url, sourceItemID: "remote-only")!
        let wire = try ICloudRecordEnvelope(kind: .read, recordName: "read-v1:" + article.dropFirst("article-v1:".count),
            feedURL: url.absoluteString, sourceItemID: "remote-only", fields: ["value": .init(value: .flag(true), version: .bootstrap)])
        await sync.setIncoming([.init(envelope: wire, systemFields: nil)])
        let review = try await prepare(selection(existing, new))
        XCTAssertEqual(review.counts.feeds, 1); XCTAssertEqual(review.counts.skippedFeeds, 1)
        let result = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true)
        XCTAssertEqual(result.counts.feeds, 1)
        XCTAssertEqual(store.feeds(for: cloud.id).map(\.feedURL), [new.feedURL])
    }

    func testSourceStateChangingAfterReviewRejectsWithoutCopy() async throws {
        let feed = try addLocal(article: true), review = try await prepare(selection(feed))
        try store.libraryDatabase.write { try $0.execute(sql: "UPDATE article_states SET is_starred = 0") }
        let before = try rows()
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("Needs another preview") }
        catch ICloudLocalCopyError.stalePlan {}
        XCTAssertEqual(try rows(), before)
        XCTAssertTrue(store.feeds(for: cloud.id).isEmpty)
    }

    func testGenerationChangeAfterReviewRejectsWithoutCopy() async throws {
        let feed = try addLocal(), review = try await prepare(selection(feed))
        try store.libraryDatabase.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = '00000000-0000-0000-0000-000000000002'") }
        let before = try rows()
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("Old generation review is invalid") }
        catch ICloudLocalCopyError.stalePlan {}
        XCTAssertEqual(try rows(), before)
    }

    func testUnavailableRestoreDoesNotCopyOrSendAndReturnsSafeError() async throws {
        let feed = try addLocal(), before = try rows()
        await sync.setFailures(restore: true)
        do { _ = try await prepare(selection(feed)); XCTFail("Needs successful restore") }
        catch { XCTAssertFalse(store.iCloudErrorMessage(error).contains("private-token")) }
        XCTAssertEqual(try rows(), before)
        let events = await sync.snapshot()
        XCTAssertEqual(events.last, "restore")
    }

    func testPostCommitAnnouncementFailureReturnsCommittedResultAndKeepsQueue() async throws {
        let feed = try addLocal(article: true), review = try await prepare(selection(feed))
        await sync.setFailures(announcement: true)
        let result = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true)
        XCTAssertEqual(result.counts.feeds, 1); XCTAssertNotNil(result.syncWarning)
        XCTAssertFalse(result.syncWarning!.contains("private-token")); XCTAssertFalse(result.syncWarning!.contains("private-rss-url"))
        XCTAssertEqual(store.feeds(for: cloud.id).count, 1)
        XCTAssertGreaterThan(try store.libraryDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_content_changes WHERE is_pending = 1")! }, 0)
    }

    func testBusyPrepareAndCallerCancellationDoNotLeaveCopyOrApproval() async throws {
        let feed = try addLocal(), source = try await catalog(), choice = selection(feed)
        let gate = CopyRestoreGate()
        await sync.holdNextRestore(gate)
        let operation = Task { try await self.prepare(choice, catalog: source) }
        defer { operation.cancel(); Task { await gate.open() } }
        try await waitForGate(gate)
        do { _ = try await prepare(choice, catalog: source); XCTFail("Busy copy is not restarted") }
        catch ICloudLocalCopyError.copyInProgress {}
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled preview cannot be confirmed") }
        catch is CancellationError {}
        XCTAssertTrue(store.feeds(for: cloud.id).isEmpty)
        let events = await sync.snapshot()
        XCTAssertFalse(events.contains("announce"))
    }

    func testProviderStopInvalidatesAnAlreadyPreparedReview() async throws {
        let feed = try addLocal(), review = try await prepare(selection(feed))
        let candidate = await store.syncCoordinator.provider(for: cloud.id)
        let provider = try XCTUnwrap(candidate as? ICloudAccountProvider)
        await provider.stop()
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("Stopped session review is invalid") }
        catch ICloudLocalCopyError.stalePlan {}
        XCTAssertTrue(store.feeds(for: cloud.id).isEmpty)
    }

    func testCancelledConfirmationDoesNotCopyAndCannotReuseApproval() async throws {
        let feed = try addLocal(article: true), review = try await prepare(selection(feed))
        let gate = CopyRestoreGate(), before = try rows()
        await sync.holdNextRestore(gate)
        let operation = Task { try await self.store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true) }
        defer { operation.cancel(); Task { await gate.open() } }
        try await waitForGate(gate)
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled confirmation cannot copy") }
        catch is CancellationError {}
        XCTAssertEqual(try rows(), before)
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("Needs a new review") }
        catch ICloudLocalCopyError.stalePlan {}
    }

    func testAccountDisabledDuringConfirmationInvalidatesRunningCopy() async throws {
        let feed = try addLocal(), review = try await prepare(selection(feed))
        let gate = CopyRestoreGate()
        await sync.holdNextRestore(gate)
        let operation = Task { try await self.store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true) }
        defer { operation.cancel(); Task { await gate.open() } }
        try await waitForGate(gate)
        try await store.setAccountEnabled(accountID: cloud.id, isEnabled: false)
        let before = try rows()
        await gate.open()
        do { _ = try await operation.value; XCTFail("Disabled account cannot copy") }
        catch is CancellationError {}
        catch ICloudLocalCopyError.unavailableTarget {}
        XCTAssertEqual(try rows(), before)
        XCTAssertTrue(store.feeds(for: cloud.id).isEmpty)
    }

    func testDiscardedReviewCannotBeExecutedAndPublicUnentitledEntriesNeverNetwork() async throws {
        let feed = try addLocal(), source = try await catalog(), choice = selection(feed)
        let review = try await prepare(choice, catalog: source)
        await store.discardICloudLocalCopyReview(id: review.id)
        do { _ = try await store.executeICloudLocalCopyAfterEntitlementCheck(reviewID: review.id, privacyReviewed: true); XCTFail("Discarded review") }
        catch ICloudLocalCopyError.stalePlan {}
        guard !store.supportsICloudSync else { throw XCTSkip("Entitled runner") }
        let before = try rows(), network = await sync.snapshot()
        do { _ = try await store.prepareICloudLocalCopy(catalog: source, selection: choice); XCTFail("Public entry requires entitlement") }
        catch ICloudEngineError.notEntitled {}
        do { _ = try await store.executeICloudLocalCopy(reviewID: UUID(), privacyReviewed: true); XCTFail("Public confirmation requires entitlement") }
        catch ICloudEngineError.notEntitled {}
        XCTAssertEqual(try rows(), before)
        let after = await sync.snapshot()
        XCTAssertEqual(after, network)
    }

    func testCopyErrorsHaveLocalizedMessagesWithoutSourceValues() throws {
        for error in [ICloudLocalCopyError.invalidSelection, .unavailableTarget, .targetRequiresReview, .stalePlan,
                      .scanLimitExceeded, .copyInProgress, .reviewRequired] {
            let message = ICloudSyncFailure.message(for: error)
            XCTAssertFalse(message.isEmpty); XCTAssertFalse(message.contains("private-token"))
        }
    }
}
