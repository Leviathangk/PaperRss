import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

private actor ICloudStoreProbe: ICloudAccountSyncing {
    let database: LibraryDatabase
    private var fetches = 0
    private var sends = 0
    private var stops = 0
    init(database: LibraryDatabase) { self.database = database }
    func fetchChanges() async throws { fetches += 1 }
    func sendChanges() async throws {
        sends += 1
        guard let account = try database.read({ try AccountRecord.filter(Column("type") == "iCloud").fetchOne($0) }) else { return }
        let repository = ICloudRecordRepository(database: database, accountID: account.id)
        for record in try repository.outgoingRecords() {
            try repository.confirm(record, server: .init(envelope: record.envelope, systemFields: nil, bodyData: record.bodyData))
        }
    }
    func stop() async { stops += 1 }
    func counts() -> (Int, Int, Int) { (fetches, sends, stops) }
}

@MainActor
final class ICloudAppStoreTests: XCTestCase {
    private var store: AppStore!
    private var probe: ICloudStoreProbe!

    override func setUp() async throws {
        store = AppStore(testDatabase: .empty, customFeedFetcher: { feed, _ in
            .updated(ParsedFeed(title: feed.title, siteURL: nil, iconURL: nil,
                entries: [ParsedFeedEntry(id: "source-guid", title: "Cloud article", author: nil, url: nil,
                                         publishedAt: nil, summary: "Body", contentHTML: "<p>Body</p>")]),
                etag: nil, lastModified: nil)
        })
        probe = ICloudStoreProbe(database: store.libraryDatabase)
    }
    override func tearDown() async throws {
        if let account = store.accounts.first(where: { $0.type == "iCloud" }) {
            try await store.removeAccount(accountID: account.id)
        }
        let directory = URL(fileURLWithPath: store.libraryDatabase.databasePath).deletingLastPathComponent()
        probe = nil; store = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func addCloud() async throws -> AccountRecord {
        try await store.createICloudAccount(fingerprint: "test-user", sync: probe)
    }

    func testAddingCloudAccountLeavesExistingLocalLibraryAndScopeUntouched() async throws {
        let local = try store.localProvider.addFeed(title: "Local", feedURL: URL(string: "https://local.example/rss")!)
        store.reloadState()
        let account = try await addCloud()
        XCTAssertEqual(store.activeAccountID, account.id)
        XCTAssertEqual(store.feeds(for: "local-default").map(\.id), [local.id])
        XCTAssertTrue(store.feeds(for: account.id).isEmpty)
        XCTAssertEqual(try store.libraryDatabase.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE account_id = 'local-default'")
        }, 0)
        XCTAssertEqual(store.accounts.filter { $0.type == "iCloud" }.count, 1)
        do { _ = try await addCloud(); XCTFail("Duplicate should fail") }
        catch ICloudAccountError.alreadyExists {}
    }

    func testDefaultSubscriptionTargetsActiveCloudAndImmediatelyFetchesItsRSS() async throws {
        let account = try await addCloud()
        let added = await store.addFeed(urlText: "https://cloud.example/rss", title: "Cloud")
        let feed = try XCTUnwrap(added)
        XCTAssertEqual(store.accountID(forFeedID: feed.id), account.id)
        XCTAssertTrue(store.feeds(for: "local-default").isEmpty)
        let items = try store.libraryDatabase.read {
            try ItemRecord.filter(Column("feed_id") == feed.id.uuidString).fetchAll($0)
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.allSatisfy { $0.accountID == account.id })
        XCTAssertEqual(items.first?.sourceItemID, "source-guid")
        XCTAssertEqual(try store.libraryDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article_state_outbox") }, 0)
    }

    func testMovingAndRenamingCloudFolderNeverCreatesLocalFolder() async throws {
        let account = try await addCloud()
        let added = await store.addFeed(urlText: "https://cloud.example/rss", title: "Cloud")
        let feed = try XCTUnwrap(added)
        store.setFeedFolder(feedID: feed.id, folder: "News")
        store.renameFolder(from: "News", to: "Reading", accountID: account.id)
        let folders = try store.libraryDatabase.read { try FolderRecord.fetchAll($0) }
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.accountID, account.id)
        XCTAssertEqual(folders.first?.name, "Reading")
        XCTAssertEqual(store.feeds(for: account.id).first?.folder, "Reading")
    }

    func testOPMLImportAndExportAreScopedToSelectedAccount() async throws {
        let account = try await addCloud()
        let data = Data("""
            <opml version="2.0"><body><outline text="Imported" type="rss" xmlUrl="https://cloud.example/import"/></body></opml>
            """.utf8)
        await store.importOPML(data, targetAccountID: account.id)
        XCTAssertTrue(store.feeds(for: "local-default").isEmpty)
        XCTAssertEqual(store.feeds(for: account.id).count, 1)
        XCTAssertEqual(OPMLService.importURLs(data: store.exportOPML(accountID: account.id)), [URL(string: "https://cloud.example/import")!])
        XCTAssertTrue(OPMLService.importURLs(data: store.exportOPML(accountID: "local-default")).isEmpty)
    }

    func testReloadKeepsOneProviderAndAccountDisableStopsNetworkWithoutDeletingCapture() async throws {
        let account = try await addCloud()
        let initial = await store.syncCoordinator.provider(for: account.id) as? ICloudAccountProvider
        store.reloadState()
        await Task.yield()
        let reloaded = await store.syncCoordinator.provider(for: account.id) as? ICloudAccountProvider
        XCTAssertTrue(initial === reloaded)
        try await store.setAccountEnabled(accountID: account.id, isEnabled: false)
        let stopped = await probe.counts()
        XCTAssertGreaterThan(stopped.2, 0)
        XCTAssertEqual(try store.libraryDatabase.read {
            try Bool.fetchOne($0, sql: "SELECT capture_enabled FROM icloud_sync_scope WHERE account_id = ?", arguments: [account.id])
        }, true)
        XCTAssertEqual(store.accounts.first(where: { $0.id == account.id })?.isEnabled, false)
    }

    func testUnentitledPublicAccountEntryLeavesDatabaseUnchanged() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled runner") }
        do { _ = try await store.addICloudAccount(); XCTFail("Must reject before network") }
        catch ICloudEngineError.notEntitled {}
        XCTAssertFalse(store.accounts.contains { $0.type == "iCloud" })
        XCTAssertEqual(try store.libraryDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope") }, 0)
    }

    func testUnentitledMaintenanceAndOutcomeEntriesDoNotGrantConsent() async throws {
        guard !ICloudSyncEngineDriver.isEntitled else { throw XCTSkip("Entitled runner") }
        let account = try await addCloud()
        do { _ = try await store.prepareICloudRetentionMaintenanceReview(accountID: account.id); XCTFail("Missing capability") }
        catch { XCTAssertEqual(error as? ICloudEngineError, .notEntitled) }
        do {
            try await store.enableICloudRetentionMaintenance(accountID: account.id, reviewID: UUID(), cleanupConfirmed: true,
                futureArticlesConfirmed: false, clockMaintenanceConfirmed: true)
            XCTFail("Future consent required")
        } catch { XCTAssertEqual(error as? ICloudRetentionMaintenanceError, .confirmationRequired) }
        do { _ = try await store.reviewICloudRetentionOutcomes(accountID: account.id, approvalID: UUID().uuidString); XCTFail("Missing capability") }
        catch { XCTAssertEqual(error as? ICloudEngineError, .notEntitled) }
        XCTAssertNil(try store.libraryDatabase.read {
            try Data.fetchOne($0, sql: "SELECT retention_maintenance FROM icloud_sync_scope WHERE account_id=?", arguments: [account.id])
        })
        let counts = await probe.counts(); XCTAssertEqual(counts.0, 1)
    }

    func testAvailabilityAndUnreadOptionStayScopedWhileDisabled() async throws {
        if !ICloudSyncEngineDriver.isEntitled {
            XCTAssertEqual(store.iCloudAccountCreationAvailability, .unsupportedBuild)
        }
        let account = try await addCloud()
        XCTAssertEqual(store.iCloudAccountCreationAvailability, .alreadyExists)
        XCTAssertFalse(store.canAddICloudAccount)
        try await store.setAccountEnabled(accountID: account.id, isEnabled: false)
        let initial = try await store.iCloudAccountSnapshot(accountID: account.id)
        XCTAssertFalse(initial.syncUnreadContent)
        let before = await probe.counts()
        try await store.setICloudSyncUnreadContent(accountID: account.id, enabled: true)
        let changed = try await store.iCloudAccountSnapshot(accountID: account.id)
        XCTAssertTrue(changed.syncUnreadContent)
        let after = await probe.counts()
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(try store.libraryDatabase.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope WHERE account_id = 'local-default'")
        }, 0)
    }

    func testMixedAccountDropRejectsEntireBatchAndCloudDropOrganizesOnlyItsFeeds() async throws {
        let local = try store.localProvider.addFeed(title: "Local", feedURL: URL(string: "https://local.example/rss")!)
        let account = try await addCloud()
        let added = await store.addFeed(urlText: "https://cloud.example/rss", title: "Cloud")
        let cloud = try XCTUnwrap(added)
        XCTAssertFalse(store.moveFeeds([local.id, cloud.id], toFolder: "Mixed", accountID: account.id))
        XCTAssertFalse(store.moveFeeds([cloud.id], toFolder: "Wrong", accountID: "local-default"))
        XCTAssertFalse(store.folders(for: account.id).contains("Mixed"))
        XCTAssertFalse(store.folders(for: "local-default").contains("Wrong"))
        XCTAssertTrue(store.moveFeeds([cloud.id], toFolder: "Cloud Folder", accountID: account.id))
        XCTAssertEqual(store.feeds(for: account.id).first?.folder, "Cloud Folder")
        XCTAssertNil(store.feeds(for: "local-default").first?.folder)
        XCTAssertTrue(store.moveFeeds([cloud.id], toFolder: nil, accountID: account.id))
        XCTAssertEqual(store.rootFeeds(for: account.id).map(\.id), [cloud.id])
    }

    func testRecoveryReviewRemainsAvailableWhileDisabledAndDoesNotStartNetwork() async throws {
        let account = try await addCloud()
        try await store.setAccountEnabled(accountID: account.id, isEnabled: false)
        let before = await probe.counts()
        let first = try await store.iCloudRecoveryReview(accountID: account.id)
        let second = try await store.iCloudRecoveryReview(accountID: account.id)
        let after = await probe.counts()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        do {
            _ = try await store.iCloudRecoveryReview(accountID: "local-default")
            XCTFail("Local accounts must not enter cloud recovery review")
        } catch ICloudRecordError.unavailableScope { }
    }

    func testCloudResidueReviewRejectsDisabledAccountWithoutResumingProviderOrChangingScope() async throws {
        let account = try await addCloud()
        try await store.setAccountEnabled(accountID: account.id, isEnabled: false)
        let before = await probe.counts()
        let scopes = try store.libraryDatabase.read { try Row.fetchAll($0, sql: "SELECT * FROM icloud_sync_scope") }
        do {
            _ = try await store.iCloudCloudResidueReview(accountID: account.id)
            XCTFail("Disabled accounts cannot read cloud metadata")
        } catch ICloudRecordError.unavailableScope { }
        let after = await probe.counts()
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(try store.libraryDatabase.read { try Row.fetchAll($0, sql: "SELECT * FROM icloud_sync_scope") }, scopes)
    }

    func testLocalMigrationPreviewIsAvailableWithoutCloudAndDoesNotActivateSync() async throws {
        _ = try store.localProvider.addFeed(title: "Local", feedURL: URL(string: "https://local.example/rss")!)
        try await store.setAccountEnabled(accountID: "local-default", isEnabled: false)
        let before = await probe.counts()
        let value = try await store.iCloudMigrationPreview(sourceAccountID: "local-default")
        let after = await probe.counts()
        XCTAssertFalse(value.sourceIsEnabled)
        XCTAssertEqual(value.feeds, 1)
        XCTAssertEqual(value.targetStatus, .notCreated)
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertFalse(store.accounts.contains { $0.type == "iCloud" })
        XCTAssertEqual(try store.libraryDatabase.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_scope") }, 0)
    }

    func testCloudSortAndFolderDeletionCaptureChangesWithoutModifyingLocalLibrary() async throws {
        let local = try store.localProvider.addFeed(title: "Local", feedURL: URL(string: "https://local.example/rss")!)
        store.addFolder("Local Folder")
        let account = try await addCloud()
        let firstAdded = await store.addFeed(urlText: "https://cloud.example/first", title: "First")
        let secondAdded = await store.addFeed(urlText: "https://cloud.example/second", title: "Second")
        let first = try XCTUnwrap(firstAdded), second = try XCTUnwrap(secondAdded)
        store.reorderRootFeeds(fromOffsets: [0], toOffset: 2, accountID: account.id)
        XCTAssertEqual(store.rootFeeds(for: account.id).map(\.id), [second.id, first.id])
        XCTAssertEqual(store.feeds(for: "local-default").map(\.id), [local.id])
        store.addFolder("One", targetAccountID: account.id)
        store.addFolder("Two", targetAccountID: account.id)
        store.reorderFolders(fromOffsets: [0], toOffset: 2, accountID: account.id)
        XCTAssertEqual(store.folders(for: account.id), ["Two", "One"])
        XCTAssertTrue(store.moveFeeds([first.id, second.id], toFolder: "One", accountID: account.id))
        let original = store.feeds(in: "One", for: account.id).map(\.id)
        store.reorderFeeds(in: "One", fromOffsets: [0], toOffset: 2, accountID: account.id)
        XCTAssertEqual(store.feeds(in: "One", for: account.id).map(\.id), Array(original.reversed()))
        await store.deleteFolderAsync("One", accountID: account.id)
        XCTAssertFalse(store.folders(for: account.id).contains("One"))
        XCTAssertEqual(Set(store.rootFeeds(for: account.id).map(\.id)), [first.id, second.id])
        XCTAssertTrue(store.folders(for: "local-default").contains("Local Folder"))
        XCTAssertGreaterThan(try store.libraryDatabase.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1", arguments: [account.id]) ?? 0
        }, 0)
    }

    func testStaleSortPositionsAndDuplicateIDsLeaveCloudOrderIntact() async throws {
        let account = try await addCloud()
        let added = await store.addFeed(urlText: "https://cloud.example/rss", title: "Cloud")
        let feed = try XCTUnwrap(added)
        store.addFolder("Folder", targetAccountID: account.id)
        store.reorderRootFeeds(fromOffsets: [2], toOffset: 0, accountID: account.id)
        store.reorderRootFeeds(fromOffsets: [0], toOffset: 3, accountID: account.id)
        store.reorderRootFeeds(orderedIDs: [feed.id, feed.id], accountID: account.id)
        store.reorderFolders(fromOffsets: [2], toOffset: 0, accountID: account.id)
        store.reorderFeeds(in: "Missing", fromOffsets: [0], toOffset: 0, accountID: account.id)
        XCTAssertEqual(store.rootFeeds(for: account.id).map(\.id), [feed.id])
        XCTAssertEqual(store.folders(for: account.id), ["Folder"])
    }
}
