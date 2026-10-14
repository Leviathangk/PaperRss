import XCTest
import Foundation
@testable import PaperRssCore

final class ReaderBlockSemanticsTests: XCTestCase {

    func testMixedParagraphPreservesMediaLinksAndEmphasis() {
        let source = """
        <img src="https://example.com/cover.jpg">
        <p><strong>工具标题</strong><br>
        <a href="https://example.com/tool">工具链接</a><br>
        介绍文字<br>
        <img src="https://example.com/tool.png"></p>
        """
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertEqual(ArticleExtractor.imageURLs(from: output, baseURL: nil),
                       ArticleExtractor.imageURLs(from: source, baseURL: nil))
        XCTAssertTrue(output.contains("<strong>工具标题</strong>"))
        XCTAssertTrue(output.contains("<a href=\"https://example.com/tool\">工具链接</a>"))
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: source).map(\.id), ["p0"])
    }

    func testExplicitBreakParagraphsRetainInlineHTMLAndTranslationAnchors() {
        let source = "<p><strong>第一段</strong><br><br>第二段<img src=\"https://example.com/a.png\"></p>"
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        let segments = paragraphs.map {
            BilingualSegment(id: $0.id, original: $0.original, translation: "译文" + $0.id)
        }
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)
        XCTAssertEqual(paragraphs.map(\.id), ["p0_0", "p0_1"])
        XCTAssertTrue(output.contains("<strong>第一段</strong>"))
        XCTAssertTrue(output.contains("第二段<img src=\"https://example.com/a.png\">"))
        XCTAssertTrue(output.contains("paper-rss-translation-p0_1"))
    }

    func testNestedInlineBreaksFallBackToIntactBlock() {
        let source = "<p><a href=\"https://example.com\">第一行<br><br>第二行<img src=\"https://example.com/a.png\"></a></p>"
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: source).map(\.id), ["p0"])
        XCTAssertEqual(output.replacingOccurrences(of: " data-paper-rss-id=\"p0\"", with: ""), source)
    }

    func testSourceFormattingDoesNotChangeMediaOrParagraphIDs() {
        let compact = "<p><strong>标题</strong><br><a href=\"https://example.com/tool\">链接</a><br>说明<img src=\"https://example.com/a.png\"></p>"
        let formatted = compact.replacingOccurrences(of: "<br>", with: "<br>\n")
        let first = ArticleExtractor.insertingInlineTranslations(into: compact, segments: [])
        let second = ArticleExtractor.insertingInlineTranslations(into: formatted, segments: [])
        XCTAssertEqual(ArticleExtractor.readerParagraphs(in: compact).map(\.id), ArticleExtractor.readerParagraphs(in: formatted).map(\.id))
        XCTAssertEqual(second.replacingOccurrences(of: "\n", with: ""), first)
    }

    func testMalformedAndMediaOnlyFragmentsKeepOriginalHTML() {
        for source in [
            "<p>前文<br><br><img src=\"https://example.com/a.png\"><br><br>后文</p>",
            "<p><strong>未闭合<br><br>文本<img src=\"https://example.com/a.png\"></p>",
            "<p>开头<br><br></p>",
            "<p><code>代码<br><br>仍然是代码</code></p>"
        ] {
            let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
            XCTAssertEqual(output.replacingOccurrences(of: " data-paper-rss-id=\"p0\"", with: ""), source)
        }
    }

    func testOldSubparagraphTranslationCannotAttachToNewIntactBlock() {
        let source = "<p><strong>标题</strong><br>\n说明<img src=\"https://example.com/a.png\"></p>"
        let old = BilingualSegment(id: "p0_0", original: "标题", translation: "旧译文")
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [old], pendingIDs: ["p0"])
        XCTAssertFalse(output.contains("旧译文"))
        XCTAssertTrue(output.contains("paper-rss-translation-p0\""))
        XCTAssertTrue(output.contains("<img"))
    }

    func testInsertingTranslationsPreservesBlockquoteSemantics() {
        let source = """
        <blockquote>
        <p>第一段引用正文，阐述核心观点。</p>
        <p>第二段引用正文，进一步补充说明。</p>
        </blockquote>
        <p>后续普通段落文本。</p>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1", "p2"], "嵌套段落的引用块应拆分为段落级翻译单元")
        XCTAssertEqual(paragraphs.map(\.original), [
            "第一段引用正文，阐述核心观点。",
            "第二段引用正文，进一步补充说明。",
            "后续普通段落文本。"
        ])

        let segments = [
            BilingualSegment(id: "p0", original: paragraphs[0].original, translation: "第一段译文"),
            BilingualSegment(id: "p1", original: paragraphs[1].original, translation: "第二段译文"),
            BilingualSegment(id: "p2", original: paragraphs[2].original, translation: "正文译文")
        ]
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        XCTAssertTrue(output.contains("<blockquote"), "多段引用必须在插入注解后保留 blockquote 语义")
        XCTAssertTrue(output.contains("</blockquote>"))

        guard let quoteClose = output.range(of: "</blockquote>"),
              let transP0 = output.range(of: "paper-rss-translation-p0"),
              let transP1 = output.range(of: "paper-rss-translation-p1"),
              let origP1 = output.range(of: "第二段引用正文") else {
            XCTFail("译文节点或原文未在输出中找到")
            return
        }

        // 段落级插入：第一段译文位于第二段原文之前，且两段译文均位于 </blockquote> 闭合之前
        XCTAssertTrue(transP0.upperBound < origP1.lowerBound, "第一段译文应插在第一段段落后、第二段段落前")
        XCTAssertTrue(transP1.upperBound < quoteClose.lowerBound, "第二段译文必须保留在 blockquote 内部")
    }

    func testStandaloneBlockquoteInsertsTranslationInsideClosingTag() {
        let source = "<blockquote>单一纯文本引用，无内部 p 标签。</blockquote>"
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0"])

        let segments = [
            BilingualSegment(id: "p0", original: paragraphs[0].original, translation: "纯文本引用译文")
        ]
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        guard let quoteClose = output.range(of: "</blockquote>"),
              let transP0 = output.range(of: "paper-rss-translation-p0") else {
            XCTFail("纯文本引用译文节点未正确生成")
            return
        }
        XCTAssertTrue(transP0.upperBound < quoteClose.lowerBound, "无嵌套引用块的译文必须插在 </blockquote> 闭合标签之前")
    }

    func testNonStrictLineBreaksPreserveSingleNewlinesAndAlignTranslation() {
        let htmlWithBr = "<p>Is this plugin open source? Yes<br>\nIs this plugin completely free? Yes<br>\nCommunity: Link</p>"
        let plain = htmlWithBr.plainText
        XCTAssertFalse(plain.contains("\n\n"), "<br> 后的换行符不应被膨胀为多余空行")
        XCTAssertEqual(plain.components(separatedBy: "\n").count, 3)

        // 模拟大模型将单换行文本返回了双换行（产生空行）的情况
        let llmOutputWithExtraBlankLines = "此插件是开源的吗？是的\n\n此插件完全免费吗？是的\n\n社区：链接"
        let aligned = llmOutputWithExtraBlankLines.aligningNewlines(withOriginal: plain)
        XCTAssertFalse(aligned.contains("\n\n"), "对齐后的译文应消除多余空行，与原文行距保持一致")
        XCTAssertEqual(aligned.components(separatedBy: "\n").count, 3)
    }

    func testInsertingTranslationsPreservesHeadingAndPreformattedSemantics() {
        let source = """
        <h2 class="jltoc--item">01 显存划的线</h2>
        <pre><code>line one
        line two</code></pre>
        <p>正文段落。</p>
        """

        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])

        XCTAssertTrue(output.contains("<h2"), "h2 标题必须保留标题语义")
        XCTAssertFalse(output.contains("<h2 class=\"paper-rss-subparagraph\""), "标题不应被展平为子段落")
        XCTAssertTrue(output.contains("<pre"), "pre 代码块必须保留 pre 语义")
    }

    func testInsertingTranslationsStableForSimpleParagraphs() {
        let source = "<p>单一普通段落，没有换行拆分。</p>"
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])
        XCTAssertTrue(output.contains("data-paper-rss-id"), "普通段落仍需稳定的段落 ID 注解")
    }

    func testInsertingTranslationsTranslatesTablePerCellInsideTheTable() throws {
        let source = """
        <table>
            <thead><tr><th>Symbol</th><th>Meaning</th></tr></thead>
            <tbody>
                <tr><td>$L$</td><td>Number of unique labels.</td></tr>
                <tr><td>$(\\mathbf{x}^l, y)$</td><td>Labeled dataset.</td></tr>
            </tbody>
        </table>
        <ul><li>第一项</li><li>第二项</li></ul>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        // 单元格是翻译单元；纯公式单元格（$L$、$(\mathbf{x}^l, y)$）不进入翻译管线。
        // 列表各项（li）为独立翻译单元（Issue #44 优化）。
        XCTAssertEqual(paragraphs.map(\.id), ["p0_0", "p0_1", "p0_2", "p0_3", "p1_0", "p1_1"])
        XCTAssertEqual(paragraphs.map(\.original), ["Symbol", "Meaning", "Number of unique labels.", "Labeled dataset.", "第一项", "第二项"])

        let translations = [
            ("p0_0", "符号"), ("p0_1", "含义"), ("p0_2", "唯一标签数量。"), ("p0_3", "带标注的数据集。"),
            ("p1_0", "第一项译文"), ("p1_1", "第二项译文")
        ]
        let segments = try translations.map { pair -> BilingualSegment in
            let original = try XCTUnwrap(paragraphs.first(where: { $0.id == pair.0 })).original
            return BilingualSegment(id: pair.0, original: original, translation: pair.1)
        }
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        // 译文必须落在本格内部：aside 之前是本格闭合标签，之后才是表格结构
        XCTAssertTrue(output.contains("<th data-paper-rss-id=\"p0_0\">Symbol<aside id=\"paper-rss-translation-p0_0\""))
        XCTAssertTrue(output.contains("</th>"))
        XCTAssertTrue(output.contains("<td data-paper-rss-id=\"p0_2\">Number of unique labels.<aside id=\"paper-rss-translation-p0_2\""))
        // 表格结构与文本保持完整
        XCTAssertTrue(output.contains("<tr"), "表格行必须保留")
        XCTAssertTrue(output.contains("$L$"), "纯公式单元格必须原样保留")
        XCTAssertTrue(output.contains("<td>$L$</td>"), "公式单元格不注解")
        XCTAssertEqual(output.components(separatedBy: "<table").count, source.components(separatedBy: "<table").count)
        XCTAssertEqual(output.components(separatedBy: "</table>").count, source.components(separatedBy: "</table>").count)
        // 表格外不允许出现任何表格译文
        let tableEnd = try XCTUnwrap(output.range(of: "</table>")?.upperBound)
        XCTAssertFalse(output[tableEnd...].contains("paper-rss-translation-p0"), "单元格译文不允许被搬到表格之外")
        // 列表各项作为独立翻译单元，译文插在对应 li 内部
        XCTAssertTrue(output.contains("<li data-paper-rss-id=\"p1_0\">第一项<aside id=\"paper-rss-translation-p1_0\""))
        XCTAssertTrue(output.contains("<li data-paper-rss-id=\"p1_1\">第二项<aside id=\"paper-rss-translation-p1_1\""))
    }

    func testTableWithStrayTextOutsideCellsFallsBackToWholeTableUnit() throws {
        // 游离文本（如 caption）不受信任：整表退回单一翻译单元路径，译文在表后。
        let source = "<table><caption>Table 1</caption><tr><td>Alpha</td><td>Beta</td></tr></table>"
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0"])

        let output = ArticleExtractor.insertingInlineTranslations(
            into: source,
            segments: [BilingualSegment(id: "p0", original: paragraphs[0].original, translation: "整表译文")]
        )
        XCTAssertTrue(output.contains("<table data-paper-rss-id=\"p0\""))
        let tableEnd = try XCTUnwrap(output.range(of: "</table>")?.upperBound)
        let translationStart = try XCTUnwrap(output.range(of: "<aside id=\"paper-rss-translation-p0\"")?.lowerBound)
        XCTAssertLessThanOrEqual(tableEnd, translationStart, "退化路径的译文必须在完整表格之后")
        XCTAssertTrue(output.contains("Alpha"), "退化路径必须保留全部单元格")
    }

    func testCodeBlocksAreNeverTranslationUnits() throws {
        let source = """
        <p>安装命令如下。</p>
        <pre><code>export PAPERRSS_MODE=production
        echo $PAPERRSS_MODE</code></pre>
        <p>结束段落。</p>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.original), ["安装命令如下。", "结束段落。"], "代码块不是自然语言，不进入翻译管线")
        let segments = paragraphs.map { BilingualSegment(id: $0.id, original: $0.original, translation: "译" + $0.id) }
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        XCTAssertEqual(output.components(separatedBy: " data-paper-rss-id").count, 3, "只有两个段落被注解为可翻译单元")
        XCTAssertTrue(output.contains("<pre><code>export PAPERRSS_MODE=production\necho $PAPERRSS_MODE</code></pre>"), "代码内容必须原样保留")
        // 译文 aside 只挂在两个段落上，代码块内部没有译文
        XCTAssertEqual(output.components(separatedBy: "id=\"paper-rss-translation-").count - 1, 2)
        let preEnd = try XCTUnwrap(output.range(of: "</code></pre>")?.upperBound)
        let followingParagraph = try XCTUnwrap(output.range(of: "<p data-paper-rss-id=\"p1\"", range: preEnd..<output.endIndex))
        XCTAssertNil(output.range(of: "paper-rss-translation", range: preEnd..<followingParagraph.lowerBound), "代码块内不得出现译文")
    }

    func testSyntaxHighlightedCodeInsideNestedDivsIsNeverTranslated() throws {
        // React.dev 等站点把代码包在多层 div + 语法高亮 span 里：
        // 已移除 pre 匹配，代码内部的 div 绝不能再变成翻译单元。
        let source = """
        <p>To animate part of your UI, wrap it in ViewTransition:</p>
        <div><div><div><div><pre><code class="sp-pre-placeholder grow-[2]"><div><span>import</span> <span>{</span> <span>ViewTransition</span> <span>}</span> <span>from</span> <span>&#x27;react&#x27;</span><span>;</span><br></div><div>const x = 1;</div></code></pre></div></div></div></div>
        <p>后续段落。</p>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(
            paragraphs.map(\.original),
            ["To animate part of your UI, wrap it in ViewTransition:", "后续段落。"],
            "语法高亮 div 不得成为翻译单元"
        )
        let segments = paragraphs.map { BilingualSegment(id: $0.id, original: $0.original, translation: "译" + $0.id) }
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        let preStart = try XCTUnwrap(output.range(of: "<pre")?.lowerBound)
        let preEnd = try XCTUnwrap(output.range(of: "</pre>")?.lowerBound)
        XCTAssertNil(output.range(of: "data-paper-rss-id", range: preStart..<preEnd),
                     "pre 内部不得出现任何段落注解")
        XCTAssertTrue(output.contains("<span>import</span>") && output.contains("const x = 1;"), "代码与高亮标记必须原样保留")
        XCTAssertEqual(output.components(separatedBy: "id=\"paper-rss-translation-").count - 1, 2, "只有两个段落有译文")
    }

    func testPlainDivWrappingCodeBlockIsNotTranslated() throws {
        let source = """
        <div><pre><code>npm install paper-rss</code></pre></div>
        <p>说明文字。</p>
        """
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.original), ["说明文字。"], "仅包裹代码的 div 不得成为翻译单元")
        let output = ArticleExtractor.insertingInlineTranslations(
            into: source,
            segments: [BilingualSegment(id: "p0", original: "说明文字。", translation: "译文")]
        )
        let preEnd = try XCTUnwrap(output.range(of: "</pre>")?.upperBound)
        XCTAssertNil(output.range(of: "data-paper-rss-id", range: output.startIndex..<preEnd), "代码包装内不得出现翻译注解")
        XCTAssertNotNil(output.range(of: "data-paper-rss-id", range: preEnd..<output.endIndex), "代码后的段落必须正常翻译")
        XCTAssertTrue(output.contains("<div><pre><code>npm install paper-rss</code></pre></div>"))
    }

    func testTableCellsContainingCodeAreNotTranslated() throws {
        let source = "<table><tr><td>说明文字</td><td><pre><code>let x = 1</code></pre></td></tr></table>"
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.original), ["说明文字"], "含代码块的单元格不进入翻译管线")

        let output = ArticleExtractor.insertingInlineTranslations(
            into: source,
            segments: [BilingualSegment(id: "p0", original: "说明文字", translation: "说明译文")]
        )
        XCTAssertTrue(output.contains("<td><pre><code>let x = 1</code></pre></td>"), "代码单元格必须原样保留")
        XCTAssertTrue(output.contains("<td data-paper-rss-id=\"p0\">说明文字<aside"), "文本单元格保持单元格内对照")
    }

    func testRootDivDoesNotCollapseWholeArticleIntoOneTranslationUnit() {
        let source = """
        <div class="article-content">
            <p>第一段正文。</p>
            <p>第二段正文。</p>
            <p>第三段正文。</p>
        </div>
        """

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)

        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1", "p2"])
        XCTAssertEqual(paragraphs.map(\.original), ["第一段正文。", "第二段正文。", "第三段正文。"])
    }

    func testNestedListsDecomposeIntoItemLevelTranslationUnits() throws {
        let source = """
        <ul><li>外层第一项<ul><li>内层项目</li></ul></li><li>外层第二项</li></ul>
        <p>列表后的段落。</p>
        """
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0_0", "p0_1", "p0_2", "p1"])
        XCTAssertEqual(paragraphs[0].original, "外层第一项")
        XCTAssertEqual(paragraphs[1].original, "内层项目")
        XCTAssertEqual(paragraphs[2].original, "外层第二项")
        XCTAssertEqual(paragraphs[3].original, "列表后的段落。")

        let segments = [
            BilingualSegment(id: "p0_0", original: "外层第一项", translation: "外层第一项译文"),
            BilingualSegment(id: "p0_1", original: "内层项目", translation: "内层项目译文"),
            BilingualSegment(id: "p0_2", original: "外层第二项", translation: "外层第二项译文"),
            BilingualSegment(id: "p1", original: "列表后的段落。", translation: "列表后的段落译文")
        ]

        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        XCTAssertEqual(output.components(separatedBy: "<ul").count, source.components(separatedBy: "<ul").count)
        XCTAssertEqual(output.components(separatedBy: "</ul>").count, source.components(separatedBy: "</ul>").count)
        XCTAssertEqual(output.components(separatedBy: "<li").count, source.components(separatedBy: "<li").count)
        XCTAssertEqual(output.components(separatedBy: "</li>").count, source.components(separatedBy: "</li>").count)

        // 父列表项译文必须落在子 <ul> 之前，而不是沉底到 </ul> 之后
        let trans0Start = try XCTUnwrap(output.range(of: "paper-rss-translation-p0_0")?.lowerBound)
        let innerLiStart = try XCTUnwrap(output.range(of: "data-paper-rss-id=\"p0_1\"")?.lowerBound)
        XCTAssertLessThan(trans0Start, innerLiStart, "父项译文必须位于嵌套子列表项之前")

        // 子列表项译文必须落在自身 </li> 闭合前
        let trans1Start = try XCTUnwrap(output.range(of: "paper-rss-translation-p0_1")?.lowerBound)
        let trans2Start = try XCTUnwrap(output.range(of: "paper-rss-translation-p0_2")?.lowerBound)
        XCTAssertLessThan(trans1Start, trans2Start, "子项译文必须位于后续外层第二项译文之前")

        let outerListEnd = try XCTUnwrap(output.range(of: "</ul>")?.lowerBound)
        XCTAssertLessThan(trans2Start, output.endIndex, "外层第二项译文存在")
    }

    func testFlatListsDecomposeIntoItemLevelTranslationUnits() throws {
        let source = """
        <ul>
          <li>First list item</li>
          <li>Second list item</li>
        </ul>
        <p>Following paragraph</p>
        """
        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        XCTAssertEqual(paragraphs.map(\.id), ["p0_0", "p0_1", "p1"])
        XCTAssertEqual(paragraphs[0].original, "First list item")
        XCTAssertEqual(paragraphs[1].original, "Second list item")
        XCTAssertEqual(paragraphs[2].original, "Following paragraph")

        let segments = [
            BilingualSegment(id: "p0_0", original: "First list item", translation: "第一项译文"),
            BilingualSegment(id: "p0_1", original: "Second list item", translation: "第二项译文")
        ]
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: segments)

        // 译文必须落在对应 li 闭合之前，保证列表结构合法且逐项紧凑对照
        XCTAssertTrue(output.contains("First list item<aside id=\"paper-rss-translation-p0_0\""))
        XCTAssertTrue(output.contains("Second list item<aside id=\"paper-rss-translation-p0_1\""))
        XCTAssertTrue(output.contains("第一项译文"))
        XCTAssertTrue(output.contains("第二项译文"))
    }

    func testMalformedNestedBlocksNeverProduceOverlappingTranslationRanges() {
        let source = "<p>Before<div>Nested block</div>After</p><p>Following paragraph</p>"

        let paragraphs = ArticleExtractor.readerParagraphs(in: source)
        let output = ArticleExtractor.insertingInlineTranslations(into: source, segments: [])

        XCTAssertEqual(paragraphs.map(\.id), ["p0", "p1"], "不完整嵌套段落整块保留")
        XCTAssertEqual(paragraphs.map(\.original).joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression), "Before Nested block After Following paragraph")
        XCTAssertTrue(output.contains("Before"))
        XCTAssertTrue(output.contains("Nested block"))
        XCTAssertTrue(output.contains("After"))
        XCTAssertTrue(output.contains("Following paragraph"))
    }

    func testDiagnosePaperBlogArticle() throws {
        guard let html = try? String(contentsOfFile: "/tmp/paper_article.html") else { return }
        let paras = ArticleExtractor.readerParagraphs(in: html, title: "Paper Blog: Write Simply, Blog Cleanly")
        let originals = paras.map(\.original)

        // 嵌套列表成功拆分：包含独立父项与各自子项
        XCTAssertTrue(originals.contains("Dual Operating Modes:"), "父项必须拆分为独立单元")
        XCTAssertTrue(originals.contains(where: { $0.contains("Global Mode") }), "嵌套子项必须拆分为独立单元")
        XCTAssertTrue(originals.contains(where: { $0.contains("Local Project Mode") }), "嵌套子项必须拆分为独立单元")

        // 底部段落完整提取
        XCTAssertTrue(originals.contains(where: { $0.contains("Related Guide") }), "文章底部 Related Guide 必须被提取")
        XCTAssertTrue(originals.contains(where: { $0.contains("Run `paper doctor`") || $0.contains("Run paper doctor") }), "文章底部 Tip 必须被提取")

        // 验证插入译文时父项译文落在子列表前
        let dualModePara = try XCTUnwrap(paras.first(where: { $0.original == "Dual Operating Modes:" }))
        let testSegment = BilingualSegment(id: dualModePara.id, original: dualModePara.original, translation: "双运行模式：")
        let output = ArticleExtractor.insertingInlineTranslations(into: html, segments: [testSegment])

        let asideIndex = try XCTUnwrap(output.range(of: "id=\"paper-rss-translation-\(dualModePara.id)\"")?.lowerBound)
        let sublistIndex = try XCTUnwrap(output.range(of: "Global Mode")?.lowerBound)
        XCTAssertLessThan(asideIndex, sublistIndex, "Dual Operating Modes 译文必须位于 Global Mode 子列表前")
    }
}
