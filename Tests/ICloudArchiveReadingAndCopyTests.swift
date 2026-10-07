import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class ICloudArchiveReadingAndCopyTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private let archive = "archive", current = "current", feed = "legacy-feed-id", folder = "archive-folder"
    private let generation = "00000000-0000-0000-0000-000000000002"
    private var reading: ICloudArchiveReadingRepository { .init(database: database, accountID: archive) }
    private var copying: ICloudLocalCopyRepository { .init(database: database) }
    private var context: ICloudLocalCopyRepository.Context { .init(userFingerprint: "current-user", generation: generation) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveReadingCopy-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        try database.write { db in
            try AccountRecord(id: archive, type: "iCloud", displayName: "Old Cloud", createdAt: 1, updatedAt: 1).insert(db)
            try AccountRecord(id: "local-default", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).insert(db)
            try FolderRecord(id: "foreign-folder", accountID: "local-default", name: "Foreign", updatedAt: 1).insert(db)
        }
        let old = ICloudRecordRepository(database: database, accountID: archive)
        try old.activate(); try old.bindSystemUserFingerprint("original-user")
        try database.write { db in
            try FeedRecord(id: feed, accountID: archive, title: "Old Feed", feedURL: "https://archive.example/rss", updatedAt: 1).insert(db)
            try FeedRecord(id: "other-feed", accountID: archive, title: "Other", feedURL: "https://other.example/rss", updatedAt: 1).insert(db)
            for (id,url) in [("credential-feed","https://user:fake-password@private.example/rss"),
                             ("duplicate-a","https://duplicate.example/rss"),("duplicate-b","https://duplicate.example/rss"),
                             ("review-feed","https://query.example/rss?token=fake")] {
                try FeedRecord(id:id,accountID:archive,title:id,feedURL:url,updatedAt:1).insert(db)
            }
            try FeedRecord(id: "deleted-feed", accountID: archive, title: "Deleted", feedURL: "https://deleted.example/rss", isDeleted: true, updatedAt: 1).insert(db)
            try FolderRecord(id: folder, accountID: archive, name: "Archive Folder", updatedAt: 1).insert(db)
            try FeedFolderRecord(feedID: feed, folderID: folder).insert(db)
            try FeedFolderRecord(feedID: feed, folderID: "foreign-folder").insert(db)
            for (id,title,date,guid,body,star) in [
                ("rss","News &amp; Reading 100%_literal",2_000.0," opaque " as String?,"<p>Saved RSS</p><img src=\"https://private.example/pixel\"><script>bad()</script>" as String?,true),
                ("cache","Cached Page",1_000,nil,nil,false),
                ("text","Text Cache",900,nil,nil,true),
                ("empty","Empty Page",800,nil,nil,false)
            ] {
                try ItemRecord(id: id, accountID: archive, externalID: id, feedID: feed, createdAt: date, updatedAt: 1, sourceItemID: guid).insert(db)
                try ArticleRecord(itemID: id, title: title, url: id == "rss" ? "https://archive.example/post?private=value" : "file:///private/path",
                    summary: "", contentHTML: body, contentUpdatedAt: 1).insert(db)
                try ArticleStateRecord(itemID: id, isRead: false, isStarred: star, dateArrived: 1, updatedAt: 1).insert(db)
            }
            for index in 0..<102 {
                let id = "page-\(index)"
                try ItemRecord(id: id, accountID: archive, externalID: id, feedID: feed, createdAt: Double(index), updatedAt: 1).insert(db)
                try ArticleRecord(itemID: id, title: "Page \(index)", summary: "Saved excerpt", contentUpdatedAt: 1).insert(db)
                try ArticleStateRecord(itemID: id, isRead: true, isStarred: false, dateArrived: 1, updatedAt: 1).insert(db)
            }
            try ItemRecord(id: "deleted-item", accountID: archive, externalID: "deleted-item", feedID: "deleted-feed", createdAt: 9_000, updatedAt: 1).insert(db)
            try ArticleRecord(itemID: "deleted-item", title: "Hidden Deleted Feed", contentUpdatedAt: 1).insert(db)
            try ArticleCacheRecord(itemID: "rss", text: "Stale full-page cache", html: "<p>Stale webpage</p>", fetchedAt: 1).insert(db)
            try ArticleCacheRecord(itemID: "cache", text: "Saved webpage", html: "<p>Saved webpage</p>", fetchedAt: 1, normalizationRevision: 0).insert(db)
            try ArticleCacheRecord(itemID: "text", text: "<script>private text</script>\nSecond line", fetchedAt: 1).insert(db)
            let segments = String(data: try JSONEncoder().encode([BilingualSegment(id: "p1", original: "Original paragraph", translation: "Saved translation")]), encoding: .utf8)!
            for (id,owner,item,subject,kind,content,complete,json) in [
                ("bound",archive as String?,"rss" as String?,"opaque","summary","Saved summary",true,nil as String?),
                ("legacy",nil,nil,"cache","translation","Legacy translation",true,nil),
                ("orphan",archive,nil,"unlinked","summary","Saved orphan",true,nil),
                ("bilingual",archive,"rss","rss","bilingual","",true,segments),
                ("partial",archive,"rss","rss","summary","Saved partial",false,nil),
                ("global",nil,nil,"global-memory","translation","Global secret",true,nil),
                ("foreign","local-default","rss","rss","summary","Foreign secret",true,nil)
            ] {
                try AIArtifactRecord(id: id, accountID: owner, itemID: item, subjectKey: subject, kind: kind,
                    contentHash: "hash", model: "model", targetLanguage: "zh", content: content,
                    segmentsJSON: json, isComplete: complete, createdAt: 1, updatedAt: 1).insert(db)
            }
            try db.execute(sql: """
                UPDATE icloud_sync_scope SET cloud_generation = '00000000-0000-0000-0000-000000000001',
                    initialized_zones = 3, pause_reason = 'accountChanged', engine_state = X'0102',
                    capture_enabled = 0, suppress_capture = 1 WHERE account_id = ?;
                UPDATE accounts SET is_enabled = 0, is_archived = 1 WHERE id = ?;
                """, arguments: [archive,archive])
            try AccountRecord(id: current, type: "iCloud", displayName: "Current Cloud", createdAt: 1, updatedAt: 1).insert(db)
            try FeedRecord(id: "current-feed", accountID: current, title: "Current", feedURL: "https://current.example/rss", updatedAt: 1).insert(db)
        }
        let target = ICloudRecordRepository(database: database, accountID: current)
        try target.activate(); try target.bindSystemUserFingerprint("current-user")
        try database.write { try $0.execute(sql: "UPDATE icloud_sync_scope SET cloud_generation = ?, initialized_zones = 3 WHERE account_id = ?", arguments: [generation,current]) }
    }
    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func sourceSnapshot() throws -> [String:[Row]] {
        try database.read { db in
            var result: [String:[Row]] = [:]
            for table in ["accounts","feeds","folders","items","icloud_sync_scope","icloud_sync_changes","icloud_content_changes"] {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(table == "accounts" ? "id" : "account_id") = ? ORDER BY rowid", arguments: [archive])
            }
            for table in ["articles","article_states","article_caches"] {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE item_id IN (SELECT id FROM items WHERE account_id = ?) ORDER BY rowid", arguments: [archive])
            }
            result["ai"] = try Row.fetchAll(db, sql: "SELECT * FROM ai_artifacts WHERE account_id = ? OR item_id IN (SELECT id FROM items WHERE account_id = ?) OR subject_key IN (SELECT id FROM items WHERE account_id = ?) ORDER BY rowid", arguments: [archive,archive,archive])
            result["relationships"] = try Row.fetchAll(db, sql: "SELECT * FROM feed_folders WHERE feed_id IN (SELECT id FROM feeds WHERE account_id = ?) ORDER BY rowid", arguments: [archive])
            return result
        }
    }
    private func selection() -> ICloudLocalCopyRepository.Selection {
        .init(sourceAccountID: archive, targetAccountID: current, feedIDs: [feed], folderIDs: [folder], articles: .reliableArticles, reviewedLinkIDs: [])
    }

    func testCatalogAndPaginationReadLegacyIdentitiesWithoutChangingArchive() async throws {
        let before = try sourceSnapshot(), catalog = try await reading.catalog()
        XCTAssertEqual(Set(catalog.feeds.map(\.id)),[feed,"other-feed","credential-feed","duplicate-a","duplicate-b","review-feed"])
        XCTAssertEqual(catalog.folders.map(\.id),[folder])
        let first = try await reading.page(.init()), second = try await reading.page(.init(page:1))
        XCTAssertEqual(first.items.count,100); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.items.count,6); XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.items.first?.id,"rss")
        XCTAssertEqual(Set(first.items.map(\.id)).intersection(second.items.map(\.id)),[])
        XCTAssertFalse(first.items.contains { $0.id == "deleted-item" })
        XCTAssertEqual(try sourceSnapshot(),before)
    }
    func testArticleFiltersAndLiteralSearchStayInSelectedArchive() async throws {
        let stars = try await reading.page(.init(folderID:folder,starredOnly:true))
        XCTAssertEqual(Set(stars.items.map(\.id)),["rss","text"])
        let percent = try await reading.page(.init(search:"100%_"))
        XCTAssertEqual(percent.items.map(\.id),["rss"])
        XCTAssertEqual(percent.items.first?.title,"News & Reading 100%_literal")
        for query in [ICloudArchiveQuery(feedID:"current-feed"),.init(folderID:"foreign-folder"),.init(search:"' OR 1=1 --")] {
            let value = try await reading.page(query); XCTAssertTrue(value.items.isEmpty)
        }
    }
    func testRSSBodyIsReadOfflineWithoutMarkingReadRepairingCacheOrRunningAI() async throws {
        let before = try sourceSnapshot(), detail = try await reading.detail(id:"rss",section:.articles)
        XCTAssertTrue(detail.document!.html.contains("Saved RSS"))
        XCTAssertFalse(detail.document!.html.contains("Stale webpage"))
        XCTAssertFalse(detail.document!.html.contains("bad()"))
        XCTAssertTrue(detail.document!.html.contains(ReaderDocumentRenderer.localArchiveCSP))
        XCTAssertNil(detail.document!.baseURL)
        XCTAssertEqual(detail.originalURL?.absoluteString,"https://archive.example/post?private=value")
        XCTAssertEqual(Set(detail.localAI.map(\.id)),["bound","bilingual","partial"])
        XCTAssertTrue(detail.localAI.first { $0.id == "bilingual" }!.content.contains("Original paragraph\nSaved translation"))
        XCTAssertFalse(detail.localAI.first { $0.id == "partial" }!.isComplete)
        XCTAssertEqual(try sourceSnapshot(),before)
    }
    func testSavedWebpageAndTextFallbackNeverRepairOldCacheAndEmptyBodyIsExplicit() async throws {
        let before = try sourceSnapshot(), cached = try await reading.detail(id:"cache",section:.articles)
        XCTAssertTrue(cached.document!.html.contains("Saved webpage"))
        XCTAssertNil(cached.originalURL)
        let text = try await reading.detail(id:"text",section:.articles)
        XCTAssertTrue(text.document!.html.contains("&lt;script&gt;private text&lt;/script&gt;<br>Second line"))
        let empty = try await reading.detail(id:"empty",section:.articles)
        XCTAssertNil(empty.document)
        XCTAssertEqual(try sourceSnapshot(),before)
    }
    func testAIIncludesLegacyAndUnlinkedArchiveResultsButExcludesOtherAccountsAndGlobalMemory() async throws {
        let page = try await reading.page(.init(section:.ai))
        XCTAssertEqual(Set(page.items.map(\.id)),["bound","legacy","orphan","bilingual","partial"])
        XCTAssertEqual(page.items.first { $0.id == "bound" }?.title,"News & Reading 100%_literal")
        let legacy = try await reading.detail(id:"legacy",section:.ai)
        XCTAssertEqual(legacy.localAI.first?.content,"Legacy translation")
        let orphan = try await reading.detail(id:"orphan",section:.ai)
        XCTAssertEqual(orphan.localAI.first?.content,"Saved orphan")
        for id in ["global","foreign"] {
            do { _ = try await reading.detail(id:id,section:.ai); XCTFail("Foreign AI must remain outside this archive") }
            catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.unavailableSource) }
        }
    }
    func testOrdinaryDisabledCloudLocalAndForeignItemsCannotUseArchiveReader() async throws {
        for account in [current,"local-default","missing"] {
            do { _ = try await ICloudArchiveReadingRepository(database:database,accountID:account).catalog(); XCTFail("Only frozen archives may open") }
            catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.unavailableSource) }
        }
        do { _ = try await reading.detail(id:"current-feed",section:.articles); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.unavailableSource) }
    }
    func testCancelledOrUnboundedQueriesDoNotReadOrChangeArchive() async throws {
        let before = try sourceSnapshot()
        for query in [ICloudArchiveQuery(page:-1),.init(page:100_001),.init(search:String(repeating:"x",count:1_025))] {
            do { _ = try await reading.page(query); XCTFail() }
            catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.safetyLimit) }
        }
        let reader = reading
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await reader.detail(id:"rss",section:.articles) }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try sourceSnapshot(),before)
    }
    func testArchiveResourcePolicyChangesSignatureWithoutChangingStandardReaderPolicy() {
        let article = PreparedArticle(text:"Content",html:"<p>Content</p>",imageURLs:[],baseURL:nil,source:.feed)
        let standard = ReaderDocumentRenderer.renderDocument(article:article,documentIdentity:"id")
        let offline = ReaderDocumentRenderer.renderDocument(article:article,documentIdentity:"id",resourcePolicy:.localArchive)
        XCTAssertTrue(standard.html.contains(ReaderDocumentRenderer.standardCSP))
        XCTAssertEqual(standard.renderSignature,ReaderDocumentRenderer.renderSignature(for:article,documentIdentity:"id"))
        XCTAssertNotEqual(standard.renderSignature,offline.renderSignature)
    }
    func testArchiveCopyCreatesOnlyReliableNewTargetRowsAndPreservesOriginalScopeAndAI() async throws {
        let before = try sourceSnapshot(), catalog = try await copying.sourceCatalog(accountID:archive)
        XCTAssertTrue(catalog.sourceIsArchive); XCTAssertFalse(catalog.sourceIsEnabled)
        let plan = try await copying.prepare(selection:selection(),context:context,catalog:catalog)
        XCTAssertEqual(plan.counts.articles,1); XCTAssertEqual(plan.counts.rssBodies,1)
        let result = try await copying.execute(.init(plan))
        XCTAssertEqual(result.feeds,1); XCTAssertEqual(result.folders,1); XCTAssertEqual(result.relationships,1)
        XCTAssertEqual(try sourceSnapshot(),before)
        try database.read { db in
            let item = try ItemRecord.filter(Column("account_id") == current).fetchOne(db)!
            XCTAssertEqual(item.sourceItemID," opaque ")
            XCTAssertEqual(try ArticleRecord.fetchOne(db,key:item.id)?.contentHTML,"<p>Saved RSS</p><img src=\"https://private.example/pixel\"><script>bad()</script>")
            XCTAssertEqual(try ArticleStateRecord.fetchOne(db,key:item.id)?.isRead,false)
            XCTAssertEqual(try ArticleStateRecord.fetchOne(db,key:item.id)?.isStarred,true)
            XCTAssertNil(try ArticleCacheRecord.fetchOne(db,key:item.id))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM ai_artifacts WHERE account_id = ?",arguments:[current]),0)
            XCTAssertGreaterThan(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM icloud_sync_changes WHERE account_id = ? AND is_pending = 1",arguments:[current])!,0)
        }
    }
    func testArchiveCopyHonorsExistingTargetAndTombstoneAndCannotReviveSource() async throws {
        try database.write { db in
            try FeedRecord(id:"occupied",accountID:current,title:"Keep Target",feedURL:"https://archive.example/rss",isDeleted:true,updatedAt:1).insert(db)
            try FolderRecord(id:"occupied-folder",accountID:current,name:"Archive Folder",updatedAt:1).insert(db)
        }
        let before = try sourceSnapshot(), plan = try await copying.prepare(selection:selection(),context:context)
        XCTAssertEqual(plan.counts.feeds,0); XCTAssertEqual(plan.counts.articles,0); XCTAssertEqual(plan.counts.folders,0)
        _ = try await copying.execute(.init(plan))
        XCTAssertEqual(try sourceSnapshot(),before)
        XCTAssertTrue(try database.read { try FeedRecord.fetchOne($0,key:"occupied")!.isDeleted })
        do { _ = try await AccountRepository(database:database).updateAccountEnabled(id:archive,isEnabled:true); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.readonlyArchive) }
    }
    func testArchivePreviewUsesCurrentCloudAndNeverMistakesArchiveForCopyTarget() async throws {
        let preview = try await ICloudMigrationPreviewRepository(database:database).preview(sourceAccountID:archive)
        XCTAssertEqual(preview.targetFeeds,1)
        XCTAssertEqual(preview.targetStatus,.locallyBound)
        for id in [current] {
            do { _ = try await copying.sourceCatalog(accountID:id); XCTFail("Ordinary cloud accounts cannot copy as sources") }
            catch { XCTAssertEqual(error as? ICloudLocalCopyError,.invalidSelection) }
        }
    }
    func testCredentialAndAmbiguousArchiveFeedsStayArchivedAndQueryLinkNeedsIndividualReview() async throws {
        let before = try sourceSnapshot(), catalog = try await copying.sourceCatalog(accountID:archive)
        XCTAssertEqual(catalog.feeds.first { $0.id == "credential-feed" }?.blocked,.credentials)
        XCTAssertNil(catalog.feeds.first { $0.id == "credential-feed" }?.address)
        XCTAssertEqual(catalog.feeds.first { $0.id == "duplicate-a" }?.blocked,.duplicateIdentity)
        XCTAssertTrue(catalog.feeds.first { $0.id == "review-feed" }!.requiresLinkReview)
        let selected = ICloudLocalCopyRepository.Selection(sourceAccountID:archive,targetAccountID:current,
            feedIDs:["credential-feed","duplicate-a","duplicate-b","review-feed"],folderIDs:[],articles:.reliableArticles,reviewedLinkIDs:[])
        do { _ = try await copying.prepare(selection:selected,context:context,catalog:catalog); XCTFail("Blocked links cannot be smuggled through a reviewed catalog") }
        catch { XCTAssertEqual(error as? ICloudLocalCopyError,.stalePlan) }
        let plan = try await copying.prepare(selection:selected,context:context)
        XCTAssertEqual(plan.counts.feeds,0)
        _ = try await copying.execute(.init(plan))
        let reviewed = ICloudLocalCopyRepository.Selection(sourceAccountID:archive,targetAccountID:current,
            feedIDs:["review-feed"],folderIDs:[],articles:.none,reviewedLinkIDs:["review-feed"])
        let approved = try await copying.prepare(selection:reviewed,context:context,catalog:catalog)
        XCTAssertEqual(approved.counts.feeds,1)
        _ = try await copying.execute(.init(approved))
        XCTAssertEqual(try sourceSnapshot(),before)
    }
    func testNormallyDisabledCloudIsNotAnArchiveSource() async throws {
        try database.write { try $0.execute(sql:"UPDATE accounts SET is_enabled = 0 WHERE id = ?",arguments:[current]) }
        do { _ = try await copying.sourceCatalog(accountID:current); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudLocalCopyError,.invalidSelection) }
        do { _ = try await ICloudArchiveReadingRepository(database:database,accountID:current).catalog(); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.unavailableSource) }
    }
    func testMalformedFrozenScopeFailsClosedForReadingAndCopy() async throws {
        try database.write { db in
            try db.execute(sql:"UPDATE icloud_sync_scope SET capture_enabled = 0, suppress_capture = 1, pause_reason = '' WHERE account_id = ?",arguments:[current])
            try db.execute(sql:"UPDATE accounts SET is_enabled = 0, is_archived = 1 WHERE id = ?",arguments:[current])
        }
        do { _ = try await copying.sourceCatalog(accountID:current); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudLocalCopyError,.invalidSelection) }
        do { _ = try await ICloudArchiveReadingRepository(database:database,accountID:current).catalog(); XCTFail() }
        catch { XCTAssertEqual(error as? ICloudArchiveRecoveryError,.unavailableSource) }
    }
}
