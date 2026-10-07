import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T0 and E2T1a: syntax hides unless the caret is on its line, and a table
/// cell renders its inline markdown.
final class CM6LivePreviewTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func boot(_ text: String) throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("boot") {
            ((try? self.js("typeof window.loreEditor")) as? String) == "object"
        }
        _ = try js("window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))")
        // Park the caret at the END, which every test document terminates with a
        // blank line for.
        //
        // Without this the caret sits at offset 0, line 1 is the caret's line,
        // and its syntax is CORRECTLY revealed — which failed four assertions
        // that were really testing "the caret is not here". Worth stating
        // because the screenshot that prompted these tests looked right for the
        // same reason in reverse: that note's first line is blank, so nothing
        // was revealed and the reveal rule was invisible in the picture.
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().length)")
    }

    @MainActor @discardableResult
    private func js(_ source: String) throws -> Any? {
        var result: Any?
        var failure: Error?
        var done = false
        webView.evaluateJavaScript(source) { v, e in
            result = v
            failure = e
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { throw failure }
        return result
    }

    @MainActor
    private func waitFor(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// What the READER sees, which is not the document.
    @MainActor
    private func rendered() throws -> String {
        try js("document.querySelector('.cm-content').innerText") as? String ?? ""
    }

    @MainActor
    private func putCaret(inLineContaining needle: String) throws {
        _ = try js(
            """
            (() => {
              const doc = window.loreEditor.text();
              window.loreEditor.selectAt(doc.indexOf(\(CM6EditorView.Coordinator.jsString(needle))));
            })()
            """)
    }

    // MARK: - E2T0

    /// The defect the first real-note screenshot showed: `##` on screen beside
    /// every heading, which is a source editor with colours, not Live Preview.
    @MainActor
    func test_headingMarkersHideUnlessTheCaretIsOnTheLine() throws {
        try boot("# Title\n\nbody text here\n\n## Section\n\n")
        var shown = try rendered()
        XCTAssertTrue(shown.contains("Title"))
        XCTAssertFalse(shown.contains("# Title"), "the hashes must not be on screen")
        XCTAssertFalse(shown.contains("## Section"))

        try putCaret(inLineContaining: "## Section")
        shown = try rendered()
        XCTAssertTrue(
            shown.contains("## Section"),
            "the caret's own line shows its syntax, so it can be edited")
        XCTAssertFalse(
            shown.contains("# Title"),
            "and ONLY that line — reveal is line-scoped, not document-scoped")
    }

    @MainActor
    func test_emphasisAndCodeMarkersHide() throws {
        try boot("some **bold** and *italic* and `code` here\n\nother line\n\n")
        let shown = try rendered()
        XCTAssertTrue(shown.contains("bold"))
        XCTAssertFalse(shown.contains("**bold**"))
        XCTAssertFalse(shown.contains("*italic*"))
        XCTAssertFalse(shown.contains("`code`"))
    }

    /// A five-item list must not show all five bullets because the caret is in
    /// one of them — the block-scope mistake M9 had to undo in the native
    /// renderer.
    @MainActor
    func test_revealIsLineScopedInAList() throws {
        try boot("- one\n- two\n- three\n\n")
        try putCaret(inLineContaining: "two")
        let shown = try rendered()
        XCTAssertEqual(
            shown.components(separatedBy: "- ").count - 1, 1,
            "exactly one line shows its marker")
    }

    @MainActor
    func test_thematicBreakBecomesARule() throws {
        try boot("above\n\n---\n\nbelow\n\n")
        XCTAssertEqual(try js("document.querySelectorAll('.cm-lore-rule').length") as? Int, 1)
        XCTAssertFalse(try rendered().contains("---"))
    }

    /// A fence gets a panel, drawn as LINE decorations — a mark over a
    /// multi-line range paints a ragged staircase instead.
    @MainActor
    func test_fencedCodeGetsAPanelOnEveryLine() throws {
        try boot("intro\n\n```bash\none\ntwo\n```\n\nafter\n")
        let panels =
            try js(
                """
                document.querySelectorAll('.cm-lore-code, .cm-lore-code-first, .cm-lore-code-last').length
                """) as? Int ?? 0
        XCTAssertGreaterThanOrEqual(panels, 3, "every line of the fence is on the panel")
    }

    // MARK: - E2T1a

    /// `**Web**` appeared with its asterisks INSIDE a rendered table in the
    /// first screenshot, which reads as the table being half-rendered.
    @MainActor
    func test_tableCellsRenderTheirInlineMarkdown() throws {
        try boot("| A | B |\n|---|---|\n| **Web** | `code` |\n| *it* | plain |\n\n")
        XCTAssertEqual(
            try js("document.querySelectorAll('.cm-lore-table strong').length")
                as? Int, 1)
        XCTAssertEqual(
            try js("document.querySelectorAll('.cm-lore-table code').length")
                as? Int, 1)
        XCTAssertEqual(
            try js("document.querySelectorAll('.cm-lore-table em').length")
                as? Int, 1)
        XCTAssertFalse(try rendered().contains("**Web**"))
        // The DOCUMENT still says what the author wrote.
        let source = try js("window.loreEditor.text()") as? String ?? ""
        XCTAssertTrue(source.contains("**Web**"), "rendering must not rewrite the source")
    }

    /// Unrecognised inline syntax is left literal rather than swallowed. The
    /// renderer is a deliberate subset, and its failure must be visible text
    /// rather than missing text.
    @MainActor
    func test_unsupportedInlineSyntaxInACellStaysLiteral() throws {
        try boot("| A |\n|---|\n| ~~struck~~ and [link](x) |\n\n")
        let shown = try rendered()
        XCTAssertTrue(shown.contains("~~struck~~"), "left as typed, not dropped")
        XCTAssertTrue(shown.contains("[link](x)"))
    }
    /// A `---` must not cost three lines of height for a one-pixel rule.
    ///
    /// Measured, ordinary line 23px:
    ///
    ///     inline widget ....  70px for the rule's own line, 116px between the
    ///                         paragraphs either side
    ///     block widget .....   25px, and 70px between the paragraphs
    ///
    /// The `hr` is a block element and was being laid out INSIDE a line box
    /// that still reserved its own full line height around it. `block: true`
    /// makes the rule replace the line instead of sitting in it.
    ///
    /// The remaining 70px is not slack: it is two real blank lines (23 each,
    /// which Obsidian also renders) plus the 25px rule. Asserted as a ceiling
    /// rather than an exact value, so a font-size change does not fail it.
    @MainActor
    func test_aThematicBreakCostsOneLineNotThree() throws {
        try boot("Paragraph before.\n\n---\n\nParagraph after.\n\n")
        let measured =
            try js(
                """
                (() => {
                  const hr = document.querySelector('.cm-lore-rule');
                  const all = Array.from(document.querySelectorAll('.cm-content > *'));
                  const before = all.find(l => l.innerText && l.innerText.startsWith('Paragraph before'));
                  const after = all.find(l => l.innerText && l.innerText.startsWith('Paragraph after'));
                  if (!hr || !before || !after) return -1;
                  const b = before.getBoundingClientRect(), a = after.getBoundingClientRect();
                  return Math.round(a.top - (b.top + b.height));
                })()
                """) as? Int ?? -1
        XCTAssertGreaterThan(measured, 0, "the rule must render at all")
        let lineHeight =
            try js(
                """
                (() => {
                  const all = Array.from(document.querySelectorAll('.cm-content > .cm-line'));
                  return Math.round(all[0].getBoundingClientRect().height);
                })()
                """) as? Int ?? -1
        XCTAssertGreaterThan(lineHeight, 0)
        // Two blank lines plus the rule. Four line heights is the ceiling; the
        // inline version was five.
        XCTAssertLessThan(
            measured, lineHeight * 4,
            "a one-pixel rule is costing \(measured)px against a "
                + "\(lineHeight)px line")
    }

}
