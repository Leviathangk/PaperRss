import XCTest
@testable import PaperRssCore

@MainActor
final class ArticleFetchPreferenceTests: XCTestCase {
    private func fixture() -> (Feed, Entry) {
        let feed = Feed(title: "FreshRSS fixture", feedURL: URL(string: "https://example.test/feed")!)
        let entry = Entry(id: "short-article", feedID: feed.id, title: "Short article",
                          url: URL(string: "https://example.test/article"),
                          summary: "订阅摘要", contentHTML: "<p>服务端已经抓取的短正文。</p>")
        return (feed, entry)
    }

    private func store(_ feed: Feed, _ entry: Entry, loader: MockPageLoader,
                       preferences: UserDefaults? = nil, cache: ArticleCache? = nil) -> AppStore {
        AppStore(testDatabase: AppDatabase(feeds: [feed], entries: [entry],
            articleCaches: cache.map { [entry.id: $0] } ?? [:], readingStates: [:],
            artifacts: [], llmConfiguration: .default),
            pageLoader: loader, articleFetchPreferences: preferences)
    }

    private func fullPage() -> String {
        "<html><body><article><p>" + String(repeating: "Fetched full article with detailed evidence and background. ", count: 40) + "</p></article></body></html>"
    }

    func testPreferenceDefaultsOnAndPersistsInIsolatedDefaults() throws {
        let name = "ArticleFetchPreferenceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let (feed, entry) = fixture()
        let first = store(feed, entry, loader: MockPageLoader(), preferences: preferences)
        XCTAssertTrue(first.automaticallyFetchArticleContent)
        first.setAutomaticallyFetchArticleContent(false)
        let second = store(feed, entry, loader: MockPageLoader(), preferences: preferences)
        XCTAssertFalse(second.automaticallyFetchArticleContent)
    }

    func testDisabledReadingPrefetchAndAIUseFeedWithoutFetchingOrWritingCache() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        let prefetched = await subject.prepareArticle(for: entry, policy: .localOnly)
        let prepared = await subject.prepareArticle(for: entry)
        let aiText = try await subject.articleText(for: entry)
        XCTAssertEqual(prefetched.source, .feed)
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertTrue(aiText.contains("服务端已经抓取的短正文"))
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
    }

    func testReenablingInvalidatesShortMemoryPreviewAndFetchesFullArticle() async {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        _ = await subject.prepareArticle(for: entry)
        XCTAssertNotNil(subject.memoizedPreparedArticle(for: entry))
        subject.setAutomaticallyFetchArticleContent(true)
        XCTAssertNil(subject.memoizedPreparedArticle(for: entry))
        let result = await subject.prepareArticle(for: entry)
        XCTAssertEqual(result.source, .web)
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testDisabledPolicyRetainsLegacyCacheWithoutNetworkOrRevisionWrite() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        let text = String(repeating: "Previously fetched full content. ", count: 40)
        let cache = ArticleCache(entryID: entry.id, text: text, html: "<p>\(text)</p>",
                                 fetchedAt: .now, sourceURL: entry.url, isSanitized: true, normalizationRevision: 0)
        let subject = store(feed, entry, loader: loader, cache: cache)
        subject.setAutomaticallyFetchArticleContent(false)
        let result = await subject.prepareArticle(for: entry)
        XCTAssertEqual(result.source, .cache)
        XCTAssertTrue(result.text.contains("Previously fetched"))
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertEqual(try subject.localProvider.fetchCache(entryID: entry.id)?.normalizationRevision, 0)
    }

    func testManualRefetchStillWorksWhenAutomaticFetchIsDisabled() async {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        let subject = store(feed, entry, loader: loader)
        subject.setAutomaticallyFetchArticleContent(false)
        let refreshed = await subject.refetchArticle(for: entry)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(loader.requestCount, 1)
        let prepared = await subject.prepareArticle(for: entry)
        XCTAssertTrue(prepared.text.contains("Fetched full article"))
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testDisablingDuringFetchDiscardsOldResponseAndCacheWrite() async throws {
        let (feed, entry) = fixture()
        let loader = MockPageLoader()
        loader.responseMap[entry.url!] = fullPage()
        loader.delay = 0.1
        let subject = store(feed, entry, loader: loader)
        let request = Task { await subject.prepareArticle(for: entry) }
        // Yield until the mock has entered its suspended network request.
        for _ in 0..<100 where loader.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(loader.requestCount, 1)
        subject.setAutomaticallyFetchArticleContent(false)
        let prepared = await request.value
        XCTAssertEqual(prepared.source, .feed)
        XCTAssertNil(try subject.localProvider.fetchCache(entryID: entry.id))
        XCTAssertEqual(subject.memoizedPreparedArticle(for: entry)?.source, .feed)
    }

    func testDisabledPolicyWithNoContentDoesNotFetch() async {
        let (feed, original) = fixture()
        let entry = Entry(id: original.id, feedID: feed.id, title: "Title only", url: original.url)
        let loader = MockPageLoader()
        let result = await ArticlePreparationEngine(pageLoader: loader).prepare(
            entry: entry, cached: nil, policy: .storedContent)
        XCTAssertEqual(loader.requestCount, 0)
        XCTAssertNil(result.updatedCache)
        XCTAssertEqual(result.prepared.source, .fallback)
    }
}
