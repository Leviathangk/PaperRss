import Foundation
import GRDB
import XCTest
@testable import PaperRssCore

final class OPMLStructureTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var provider: LocalAccountProvider!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLStructureTests-\(UUID())")
        database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        provider = LocalAccountProvider(accountID: "opml-cloud", database: database)
        try database.write {
            try AccountRecord(id: "opml-cloud", type: "iCloud", displayName: "Cloud", createdAt: 1, updatedAt: 1).save($0)
            try AccountRecord(id: "opml-local", type: "local", displayName: "Local", createdAt: 1, updatedAt: 1).save($0)
        }
        try ICloudRecordRepository(database: database, accountID: "opml-cloud").activate()
    }
    override func tearDownWithError() throws {
        provider = nil; database = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func data(_ body: String) -> Data {
        Data("<opml version=\"2.0\"><body>\(body)</body></opml>".utf8)
    }

    func testTitlesSiteURLsEmptyFoldersAndMultipleMembershipsRoundTrip() throws {
        let document = data("""
            <outline text="Empty"/>
            <outline text="News &amp; Science">
              <outline title="" text="Title &quot;one&quot;" xmlUrl="https://example.com/rss?a=1&amp;b=2" htmlUrl="https://example.com"/>
            </outline>
            <outline text="Favorites">
              <outline title="Duplicate title" xmlUrl="https://example.com/rss?a=1&amp;b=2"/>
            </outline>
            """)
        let added = try provider.importOPML(document)
        XCTAssertEqual(added.count, 1)
        let feeds = try provider.fetchFeeds()
        XCTAssertTrue(feeds.allSatisfy { $0.title == "Title \"one\"" })
        XCTAssertTrue(feeds.allSatisfy { $0.siteURL == URL(string: "https://example.com") })
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_folders") }, 2)
        let output = try OPMLService.parse(data: provider.exportOPML())
        XCTAssertEqual(Set(output.folders), ["Empty", "News & Science", "Favorites"])
        XCTAssertEqual(output.subscriptions.count, 2)
        XCTAssertEqual(Set(output.subscriptions.compactMap(\.folder)), ["News & Science", "Favorites"])
        XCTAssertEqual(try provider.importOPML(provider.exportOPML()), [])
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 1)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed_folders") }, 2)
    }

    func testNestedFolderNamesArePreservedAsPathsWithinExistingFlatModel() throws {
        _ = try provider.importOPML(data("""
            <outline text="Parent"><outline text="Child"><outline text="Feed" xmlUrl="https://example.com/rss"/></outline></outline>
            """))
        XCTAssertEqual(try provider.fetchFeeds().first?.folder, "Parent / Child")
        XCTAssertEqual(Set(try OPMLService.parse(data: provider.exportOPML()).folders), ["Parent", "Parent / Child"])
    }

    func testMalformedOrInvalidFeedDocumentDoesNotPartiallyImport() throws {
        for source in [
            "<opml><body><outline text=\"Valid\" xmlUrl=\"https://example.com/rss\"/>",
            "<opml><body><outline text=\"Valid\" xmlUrl=\"https://example.com/rss\"/><outline xmlUrl=\"file:///private/file\"/></body></opml>",
            "<rss><body><outline xmlUrl=\"https://example.com/rss\"/></body></rss>"
        ] {
            XCTAssertThrowsError(try provider.importOPML(Data(source.utf8)))
            XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds") }, 0)
            XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM folders") }, 0)
        }
    }

    func testExternalAndInternalEntitiesAreRejectedIncludingUTF16() throws {
        let source = """
            <!DOCTYPE opml [<!ENTITY private SYSTEM "file:///etc/passwd">]>
            <opml><body><outline text="&private;"/></body></opml>
            """
        XCTAssertThrowsError(try OPMLService.parse(data: Data(source.utf8)))
        XCTAssertThrowsError(try OPMLService.parse(data: XCTUnwrap(source.data(using: .utf16))))
        let internalSource = source.replacingOccurrences(of: "SYSTEM \"file:///etc/passwd\"", with: "\"recursive &private;\"")
        XCTAssertThrowsError(try OPMLService.parse(data: Data(internalSource.utf8)))
    }

    func testExistingFeedIdentityTitleAndStatesRemainWhenNewFolderIsImported() throws {
        _ = try provider.importOPML(data("<outline title=\"Chosen title\" xmlUrl=\"https://example.com/rss\"/>"))
        let original = try XCTUnwrap(provider.fetchFeeds().first)
        let item = "existing-item"
        try database.write { db in
            try ItemRecord(id: item, accountID: "opml-cloud", externalID: item, feedID: original.id.uuidString, createdAt: 1, updatedAt: 1).save(db)
            try ArticleRecord(itemID: item, title: "History").save(db)
            try ArticleStateRecord(itemID: item, isRead: true, isStarred: true, dateArrived: 1, updatedAt: 1).save(db)
        }
        _ = try provider.importOPML(data("<outline text=\"New folder\"><outline title=\"Imported duplicate\" xmlUrl=\"https://example.com/rss\"/></outline>"))
        let feed = try XCTUnwrap(provider.fetchFeeds().first)
        XCTAssertEqual(feed.id, original.id)
        XCTAssertEqual(feed.title, "Chosen title")
        XCTAssertEqual(feed.folder, "New folder")
        XCTAssertTrue(try database.read { try ArticleStateRecord.fetchOne($0, key: item)?.isStarred } == true)
        XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feeds WHERE account_id = 'opml-local'") }, 0)
    }

    func testAsyncImportOfOnlyEmptyFoldersRetainsFolderChanges() async throws {
        let imported = try await provider.importOPMLAsync(data("<outline text=\"Empty\"/>"))
        XCTAssertEqual(imported, [])
        XCTAssertEqual(try OPMLService.parse(data: provider.exportOPML()).folders, ["Empty"])
        XCTAssertEqual(try database.read { try String.fetchOne($0, sql: "SELECT kind FROM icloud_sync_changes WHERE kind = 'folder'") }, "folder")
    }
}
