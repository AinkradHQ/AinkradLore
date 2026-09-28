import XCTest
@testable import LoreFeature

final class HTMLToMarkdownTests: XCTestCase {
    private func md(_ html: String) -> String { HTMLToMarkdown.convert(html).markdown }

    func testConvertsInlineEmphasis() {
        XCTAssertEqual(md("<p>a <b>bold</b> and <i>italic</i> plan</p>"),
                       "a **bold** and *italic* plan")
    }

    func testConvertsHeadingsAndLists() {
        let out = md("<h2>Shopping</h2><ul><li>milk</li><li>eggs</li></ul>")
        XCTAssertTrue(out.contains("## Shopping"))
        XCTAssertTrue(out.contains("- milk"))
        XCTAssertTrue(out.contains("- eggs"))
    }

    func testConvertsChecklists() {
        let out = md("<ul><li><input type='checkbox' checked>done</li>"
                     + "<li><input type='checkbox'>todo</li></ul>")
        XCTAssertTrue(out.contains("- [x] done"))
        XCTAssertTrue(out.contains("- [ ] todo"))
    }

    func testWarnsRatherThanDroppingUnsupportedMarkup() {
        let result = HTMLToMarkdown.convert("<p>text</p><object data='x'></object>")
        XCTAssertEqual(result.warnings.first?.kind, .unsupportedElement)
        XCTAssertTrue(result.warnings.first?.detail.contains("object") ?? false)
    }

    func testLeavesPlainTextUntouched() {
        XCTAssertEqual(md("<p>just words</p>"), "just words")
    }

    func testConvertsAnchorWithHref() {
        XCTAssertEqual(md("<p>see <a href=\"https://example.com\">here</a></p>"),
                       "see [here](https://example.com)")
    }

    func testDecodesNamedAndNumericEntities() {
        XCTAssertEqual(md("<p>Tom &amp; Jerry&#39;s &lt;plan&gt; &#x2019;quoted&#x2019;</p>"),
                       "Tom & Jerry's <plan> \u{2019}quoted\u{2019}")
    }

    func testHandlesSelfClosingTags() {
        let out = md("<p>line one<br/>line two</p>")
        XCTAssertTrue(out.contains("line one"))
        XCTAssertTrue(out.contains("line two"))
    }

    func testScriptContentIsNotLeakedIntoOutput() {
        let result = HTMLToMarkdown.convert(
            "<p>before</p><script>if (a > b) { doEvil(); }</script><p>after</p>")
        XCTAssertFalse(result.markdown.contains("doEvil"))
        XCTAssertFalse(result.markdown.contains("a > b"))
        XCTAssertTrue(result.markdown.contains("before"))
        XCTAssertTrue(result.markdown.contains("after"))
    }

    func testStyleContentIsNotLeakedIntoOutput() {
        let result = HTMLToMarkdown.convert(
            "<p>before</p><style>p { color: red; }</style><p>after</p>")
        XCTAssertFalse(result.markdown.contains("color: red"))
        XCTAssertTrue(result.markdown.contains("before"))
        XCTAssertTrue(result.markdown.contains("after"))
    }

    func testCommentsContainingGreaterThanAreFullySkipped() {
        let out = md("<!-- a > b --><p>x</p>")
        XCTAssertEqual(out, "x")
    }

    func testUnmatchedClosingAnchorIsANoOp() {
        XCTAssertEqual(md("<p>no link</a> here</p>"), "no link here")
    }
}
