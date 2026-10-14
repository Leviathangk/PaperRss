import XCTest
import WebKit
import PaperRssCore
@testable import PaperRssDesktop

@MainActor
final class TranslationPresentationTests: XCTestCase, WKNavigationDelegate {
    private var navigation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    private func load(_ content: String) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        webView.navigationDelegate = self
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="paper-rss-load-generation" content="7">
        <meta name="paper-rss-document-identity" content="test-article">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'">
        <style>:root { --paper-ink: #302D27; --paper-muted: #6F695E; }
        body { font: 17px/1.72 sans-serif; } p { margin: 1em 0; }
        .paper-rss-translation p { margin: 0; }
        \(ReaderTranslationPresentation.style)</style></head><body>
        \(content)<button id="outside">Outside</button></body></html>
        """
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        _ = try await run(ReaderTranslationPresentation.bootstrapScript)
        _ = try await run("""
        window.translationFlushes = 0;
        window.addEventListener('paperRssLayoutRefresh', () => window.translationFlushes++);
        window.paperRssVisibleTranslationNodes = Array.from(document.querySelectorAll('[data-paper-rss-id]')).filter(node => {
          const rect = node.getBoundingClientRect(); return rect.bottom > 0 && rect.top < window.innerHeight;
        }).slice(0, 10);
        """)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private func update(_ id: String = "p0", text: String = "译文", loading: Bool = false) async throws {
        try await synchronize(updates: [["id": id, "text": text, "isLoading": loading]])
    }

    private func synchronize(updates: [[String: Any]] = [], removals: [String] = []) async throws {
        let previous = try await run("return window.translationFlushes;") as? Int ?? 0
        _ = try await run(PaperReaderBridge.translationSynchronizationScript, arguments: [
            "updates": updates, "removals": removals, "generation": 7, "documentIdentity": "test-article"
        ])
        _ = try await run("""
        const deadline = Date.now() + 3000;
        while (window.translationFlushes <= previous) {
          if (Date.now() > deadline) throw new Error('Translation frame did not flush');
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        """, arguments: ["previous": previous])
    }

    func testIncrementalTranslationHasStyleAndReplacementPreservesDOMAndHeight() async throws {
        try await load("<p data-paper-rss-id='p0'>A long original paragraph with <a id='link' href='https://example.com'>a link</a>. " + String(repeating: "More original text. ", count: 35) + "</p><p id='next'>Next paragraph</p>")
        _ = try await run("window.original = document.querySelector('[data-paper-rss-id]');")
        try await update(text: "短译文")
        let styled = try await run("return document.getElementById('paper-rss-translation-p0').classList.contains('paper-rss-translation');")
        XCTAssertEqual(styled as? Bool, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let before = try await run("window.host = document.querySelector('.paper-rss-replacement'); return document.getElementById('next').getBoundingClientRect().top;") as? Double
        let hidden = try await run("return window.original.inert && window.original.getAttribute('aria-hidden') === 'true';")
        XCTAssertEqual(hidden as? Bool, true)
        _ = try await run("window.host.focus();")
        let after = try await run("return document.getElementById('next').getBoundingClientRect().top;") as? Double
        XCTAssertEqual(try XCTUnwrap(before), try XCTUnwrap(after), accuracy: 0.5)
        let original = try await run("return document.querySelector('[data-paper-rss-id]') === window.original && !window.original.inert && !!document.getElementById('link');")
        XCTAssertEqual(original as? Bool, true)
        let opacity = try await run("""
        document.getAnimations().forEach(animation => animation.finish());
        return getComputedStyle(window.original).opacity === '1' &&
          getComputedStyle(document.getElementById('paper-rss-translation-p0')).opacity === '0';
        """) as? Bool
        XCTAssertEqual(opacity, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#123456');")
        let restored = try await run("return !document.querySelector('.paper-rss-replacement') && document.querySelector('[data-paper-rss-id]') === window.original && !window.original.hasAttribute('aria-hidden') && !window.original.inert;")
        XCTAssertEqual(restored as? Bool, true)
    }

    func testPendingFailureAndRemovalNeverHideSource() async throws {
        try await load("<p data-paper-rss-id='p0'>Original</p>")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        try await update(loading: true)
        let pending = try await run("return !document.querySelector('.paper-rss-replacement') && getComputedStyle(document.querySelector('.paper-rss-translation')).display === 'none';")
        XCTAssertEqual(pending as? Bool, true)
        try await update()
        try await synchronize(removals: ["p0"])
        let removed = try await run("return !document.querySelector('.paper-rss-replacement') && !document.querySelector('.paper-rss-translation') && document.querySelector('[data-paper-rss-id]').textContent === 'Original';")
        XCTAssertEqual(removed as? Bool, true)
    }

    func testCachedMarkupAndSemanticBlocksUseSamePresentation() async throws {
        let sources = [
            "<h1 data-paper-rss-id='title'>Title</h1>",
            "<blockquote data-paper-rss-id='p0'><p>Quoted words</p></blockquote>",
            "<ul data-paper-rss-id='p1'><li>First</li><li>Second</li></ul>",
            "<table data-paper-rss-id='p2'><tbody><tr><td>Cell</td></tr></tbody></table>"
        ]
        let ids = ["title", "p0", "p1", "p2"]
        let html = zip(sources, ids).map { $0.0 + ArticleExtractor.translationMarkup(for: "译文", id: $0.1) }.joined()
        try await load(html)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let result1 = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(result1, 4)
        let valid = try await run("return !!document.querySelector('ul > li') && !!document.querySelector('table > tbody > tr > td') && !!document.querySelector('blockquote > p');")
        XCTAssertEqual(valid as? Bool, true)
        try await update("p1", text: "新译文")
        let result2 = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(result2, 4)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#494640');")
        let result3 = try await run("return document.querySelectorAll('[data-paper-rss-id]').length;") as? Int
        XCTAssertEqual(result3, 4)
    }

    func testSelectionAndLinkFocusKeepOriginalVisible() async throws {
        try await load("<p data-paper-rss-id='p0'>Original <a id='link' href='https://example.com'>linked text</a></p>")
        try await update()
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640'); document.querySelector('.paper-rss-replacement').focus(); document.getElementById('link').focus();")
        let result4 = try await run("return !document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result4, true)
        // WebKit 聚焦外部按钮会自行清空选区；用真正的悬浮离开来验证选择保持。
        _ = try await run("""
        document.getElementById('outside').focus();
        const host = document.querySelector('.paper-rss-replacement');
        host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
        const range = document.createRange();
        range.selectNodeContents(document.getElementById('link'));
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
        host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
        """)
        let result5 = try await run("return !document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result5, true)
        _ = try await run("window.getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange'));")
        let result6 = try await run("return document.querySelector('[data-paper-rss-id]').inert;") as? Bool
        XCTAssertEqual(result6, true)
    }
    func testPointerReversalAndLongArticleAvoidLayoutReadsDuringHover() async throws {
        let html = (0..<150).map { "<p data-paper-rss-id='p\($0)'>Original paragraph \($0)</p>" }.joined()
        try await load(html)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let updates = (0..<150).map { ["id": "p\($0)", "text": "译文", "isLoading": false] as [String: Any] }
        try await synchronize(updates: updates)
        let count = try await run("return document.querySelectorAll('.paper-rss-replacement').length;") as? Int
        XCTAssertEqual(count, 150)
        let result = try await run("""
        const host = document.querySelector('.paper-rss-replacement');
        const source = host.querySelector('[data-paper-rss-id]');
        const originalBounds = Element.prototype.getBoundingClientRect;
        let layoutReads = 0;
        Element.prototype.getBoundingClientRect = function() { layoutReads++; return originalBounds.call(this); };
        let reveals = true;
        const fine = matchMedia('(hover: hover) and (pointer: fine)').matches;
        for (let i = 0; i < 30; i++) {
          host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
          if (fine) reveals = reveals && !source.inert;
          host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
          reveals = reveals && source.inert;
        }
        Element.prototype.getBoundingClientRect = originalBounds;
        return reveals && layoutReads === 0;
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testDefinitionAndCaptionKeepValidContainers() async throws {
        try await load("<dl><dt data-paper-rss-id='p0'>Term</dt></dl><figure><figcaption data-paper-rss-id='p1'>Caption</figcaption></figure>")
        try await update("p0")
        try await update("p1")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let valid = try await run("return !!document.querySelector('dl > dt > .paper-rss-replacement') && !!document.querySelector('figure > figcaption > .paper-rss-replacement');") as? Bool
        XCTAssertEqual(valid, true)
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#494640');")
        let restored = try await run("return document.querySelector('dt').textContent === 'Term' && document.querySelector('figcaption').textContent === 'Caption';") as? Bool
        XCTAssertEqual(restored, true)
    }

    func testTableCellTranslationStaysInsideTheCellAndPreservesTableStructure() async throws {
        try await load("<table><tr><th data-paper-rss-id='p0'>Page</th><td data-paper-rss-id='p1'>What you can configure</td></tr></table>")
        // 流式更新必须插进本格内部，afterend 会把译文插成 tr 的非法子元素。
        try await update("p0", text: "页面")
        try await update("p1", text: "您可以配置的内容")
        let inside = try await run("""
        return document.querySelector('th > .paper-rss-translation') &&
               document.querySelector('td > .paper-rss-translation') &&
               document.querySelectorAll('tr').length === 1 &&
               document.querySelectorAll('th, td').length === 2;
        """) as? Bool
        XCTAssertEqual(inside, true, "单元格译文必须留在本格内")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let stacked = try await run("""
        return !!document.querySelector('th > .paper-rss-replacement') &&
               !!document.querySelector('td > .paper-rss-replacement') &&
               document.querySelectorAll('table tr').length === 1;
        """) as? Bool
        XCTAssertEqual(stacked, true, "替换模式层叠必须留在单元格内部，不得把 td 移出 tr")
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('comparison', '#494640');")
        let restored = try await run("""
        return document.querySelector('th').textContent.includes('Page') &&
               document.querySelector('th').textContent.includes('页面') &&
               document.querySelectorAll('table tr').length === 1;
        """) as? Bool
        XCTAssertEqual(restored, true)
    }

    func testClearingMultiParagraphSelectionRestoresIntermediateParagraphs() async throws {
        try await load((0..<3).map { "<p data-paper-rss-id='p\($0)'>Original paragraph \($0)</p>" }.joined())
        for i in 0..<3 { try await update("p\(i)") }
        _ = try await run("window.paperRssTranslationPresentation.setPreferences('replacement', '#494640');")
        let result = try await run("""
        const hosts = Array.from(document.querySelectorAll('.paper-rss-replacement'));
        const enter = host => host.dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}));
        const leave = host => host.dispatchEvent(new PointerEvent('pointerout', {bubbles: true, pointerType: 'mouse', relatedTarget: document.body}));
        enter(hosts[1]);
        const selection = window.getSelection();
        const range = document.createRange();
        range.setStart(hosts[0], 0);
        range.setEndAfter(hosts[2]);
        selection.addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
        leave(hosts[1]);
        enter(hosts[1]); leave(hosts[1]);
        enter(hosts[2]); leave(hosts[2]);
        document.dispatchEvent(new Event('selectionchange'));
        selection.removeAllRanges();
        document.dispatchEvent(new Event('selectionchange'));
        return hosts.every(host => host.querySelector('[data-paper-rss-id]').inert);
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testIncrementalUpdateOfLongArticleOnlyMeasuresViewportAnchor() async throws {
        let html = (0..<1_000).map { "<p data-paper-rss-id='p\($0)'>Original paragraph \($0)</p>" }.joined()
        try await load(html)
        _ = try await run("""
        window.paperRssVisibleTranslationNodes = [document.querySelector('[data-paper-rss-id="p0"]')];
        window.translationBoundsReads = 0;
        const originalBounds = Element.prototype.getBoundingClientRect;
        Element.prototype.getBoundingClientRect = function() {
          window.translationBoundsReads++; return originalBounds.call(this);
        };
        """)
        try await update("p1", text: "增量译文")
        let reads = try await run("return window.translationBoundsReads;") as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(reads), 3, "不应对一千段正文逐一测量布局")
        let translation = try await run("return document.querySelector('#paper-rss-translation-p1 .paper-rss-translation-text').textContent;") as? String
        XCTAssertEqual(translation, "增量译文")
    }

    func testInsertionAboveViewportPreservesReadingPositionDuringScroll() async throws {
        let paragraphs = (0..<50).map { "<p data-paper-rss-id='p\($0)'>Paragraph \($0). " + String(repeating: "Original text. ", count: 10) + "</p>" }.joined()
        try await load(paragraphs)
        _ = try await run("""
        const anchor = document.querySelector('[data-paper-rss-id="p8"]');
        window.scrollTo(0, anchor.getBoundingClientRect().top + window.scrollY - 40);
        window.paperRssReaderScrolling = true;
        window.paperRssVisibleTranslationNodes = [anchor];
        window.anchorBeforeTranslation = anchor.getBoundingClientRect().top;
        """)
        try await update("p1", text: String(repeating: "较长的译文会增加上方段落高度。", count: 40))
        let delta = try await run("return document.querySelector('[data-paper-rss-id=\"p8\"]').getBoundingClientRect().top - window.anchorBeforeTranslation;") as? Double
        XCTAssertEqual(try XCTUnwrap(delta), 0, accuracy: 1,
                       "译文插入引起的高度变化不能带着当前阅读位置跳动")
    }

    func testScrollingDisplaysTranslationWithoutWaitingAndModeChangeRemovesIt() async throws {
        try await load("<p data-paper-rss-id='p0'>Original</p>")
        _ = try await run("window.paperRssReaderScrolling = true;")
        _ = try await run(PaperReaderBridge.translationSynchronizationScript, arguments: [
            "updates": [["id": "p0", "text": "即时译文", "isLoading": false]], "removals": [String](),
            "generation": 7, "documentIdentity": "test-article"
        ])
        let displayed = try await run("await new Promise(resolve => setTimeout(resolve, 180)); return document.querySelector('.paper-rss-translation-text')?.textContent;") as? String
        XCTAssertEqual(displayed, "即时译文")
        _ = try await run("window.paperRssReaderScrolling = false;")
        try await synchronize(removals: ["p0"])
        let withdrawn = try await run("return !document.querySelector('.paper-rss-translation') && document.querySelector('[data-paper-rss-id]').textContent === 'Original';") as? Bool
        XCTAssertEqual(withdrawn, true)
    }
}
