import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T6: `$inline$` and `$$block$$`, rendered by KaTeX.
///
/// The native renderer draws maths with a hand-written parser because AppKit has
/// no TeX engine that does not drag in a web view. This surface IS a web view,
/// so that constraint is gone — but `MarkdownMath`'s all-or-nothing rule is
/// kept: an expression the engine refuses stays SOURCE, so the reader can still
/// tell notation from prose. Half-rendered maths is worse than either.
final class CM6MathTests: XCTestCase {

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
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().length)")
        // KaTeX is a SEPARATE bundle, fetched the first time a document
        // containing `$` is seen — it costs ~29.5 MB per surface and most notes
        // have no maths. So a test that expects rendered maths has to wait for
        // the engine, exactly as a reader would.
        if text.contains("$") {
            try waitFor("the maths engine to load") {
                ((try? self.js("window.loreEditor.mathEngineLoaded()")) as? Bool) == true
            }
        }
    }

    /// The whole point of the split bundle.
    @MainActor
    func test_aNoteWithNoMathsNeverLoadsTheEngine() throws {
        try boot("# Just prose\n\nNo mathematics here at all.\n\n")
        XCTAssertEqual(
            try js("window.loreEditor.mathEngineLoaded()") as? Bool, false,
            "a note without maths must not pay for KaTeX")
        XCTAssertEqual(try count(), 0)
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

    @MainActor private func count() throws -> Int {
        (try js("window.loreEditor.mathCount()") as? Int) ?? -1
    }

    @MainActor private func shown() throws -> String {
        (try js("document.querySelector('.cm-content').innerText") as? String) ?? ""
    }

    // MARK: - it renders

    @MainActor
    func test_inlineMathIsRendered() throws {
        try boot("The area is $\\pi r^2$ exactly.\n\n")
        XCTAssertEqual(try count(), 1)
        XCTAssertEqual(try js("window.loreEditor.mathBlockCount()") as? Int, 0)
        XCTAssertEqual(try js("window.loreEditor.mathRendersTo(0)") as? Bool, true)
        // The delimiters are gone and the source is not on screen.
        let text = try shown()
        XCTAssertFalse(text.contains("\\pi"), "the TeX source must be hidden: \(text)")
    }

    @MainActor
    func test_blockMathIsRenderedAsABlock() throws {
        try boot("Before.\n\n$$\\frac{a}{b} = c$$\n\nAfter.\n\n")
        XCTAssertEqual(try js("window.loreEditor.mathBlockCount()") as? Int, 1)
        let text = try shown()
        XCTAssertTrue(text.contains("Before."))
        XCTAssertTrue(text.contains("After."))
    }

    /// A block spanning lines, which is how Obsidian is written and used:
    ///
    ///     $$
    ///     x = y
    ///     $$
    ///
    /// The native renderer rejects this — its closing rule forbids whitespace
    /// before the delimiter, and here that whitespace is the newline. A
    /// deliberate divergence: the parity goal is Obsidian's behaviour, not the
    /// native renderer's limits, and this surface can render it.
    @MainActor
    func test_aBlockMaySpanLines() throws {
        try boot("Before.\n\n$$\n\\sum_{i=1}^{n} i\n$$\n\nAfter.\n\n")
        XCTAssertEqual(try js("window.loreEditor.mathBlockCount()") as? Int, 1)
        XCTAssertEqual(try js("window.loreEditor.mathErrorCount()") as? Int, 0)
        let text = try shown()
        XCTAssertFalse(text.contains("\\sum"), "the source must be hidden: \(text)")
        XCTAssertTrue(text.contains("Before."))
        XCTAssertTrue(text.contains("After."))
    }

    /// And the caret anywhere inside such a block brings the whole thing back
    /// as source — including its last line, which is a different line from the
    /// one the expression starts on.
    @MainActor
    func test_theCaretInsideAMultiLineBlockRevealsIt() throws {
        try boot("$$\n\\frac{a}{b}\n$$\n\nAfter.\n\n")
        XCTAssertEqual(try js("window.loreEditor.mathBlockCount()") as? Int, 1)
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().indexOf('frac'))")
        XCTAssertEqual(try js("window.loreEditor.mathBlockCount()") as? Int, 0)
        let revealed = try shown()
        XCTAssertTrue(revealed.contains("\\frac{a}{b}"), "got \(revealed)")
    }

    /// KaTeX's own error rendering is a red copy of the source. It must never
    /// appear: the rule is that unparseable maths stays plain source.
    @MainActor
    func test_anExpressionTheEngineRefusesStaysSource() throws {
        try boot("Broken: $\\frobnicate{x}$ here.\n\n")
        XCTAssertEqual(try count(), 0, "nothing should have been replaced")
        XCTAssertEqual(
            try js("window.loreEditor.mathErrorCount()") as? Int, 0,
            "KaTeX's red error markup must never be on screen")
        let text = try shown()
        XCTAssertTrue(
            text.contains("\\frobnicate"),
            "the source must still be readable: \(text)")
    }

    // MARK: - what is not maths

    /// `$5 and $10` in prose is not an expression, and a `$` in a shell snippet
    /// is not either — the same suppression a wikilink gets.
    @MainActor
    func test_currencyAndCodeAreNotMaths() throws {
        try boot(
            """
            It cost $5 and then $10 more.

            Run `echo $HOME` and also:

            ```sh
            echo $PATH $USER
            ```

            """)
        XCTAssertEqual(try count(), 0)
    }

    /// An unclosed `$` must not swallow the rest of the note.
    @MainActor
    func test_anUnclosedDelimiterRendersNothing() throws {
        try boot("An open $ delimiter\n\nand a later paragraph.\n\n")
        XCTAssertEqual(try count(), 0)
        XCTAssertTrue(try shown().contains("later paragraph"))
    }

    @MainActor
    func test_anEmptyExpressionIsNotMaths() throws {
        try boot("Empty $$ and $ $ here.\n\n")
        XCTAssertEqual(try count(), 0)
    }

    // MARK: - the reveal rule, and the invariant

    @MainActor
    func test_theCaretsOwnLineShowsTheSource() throws {
        try boot("Line one has $x^2$ in it.\n\nLine two has $y^2$.\n\n")
        XCTAssertEqual(try count(), 2)
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().indexOf('x^2'))")
        XCTAssertEqual(try count(), 1, "only the other line stays rendered")
        let revealed = try shown()
        XCTAssertTrue(revealed.contains("$x^2$"), "got \(revealed)")
    }

    @MainActor
    func test_renderingChangesNoByteOfTheDocument() throws {
        let source = """
            Inline $\\pi r^2$ and block:

            $$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$

            And a refusal: $\\frobnicate{x}$, and $5 of currency.

            """
        try boot(source)
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
        for needle in ["\\pi", "\\sum", "\\frobnicate"] {
            _ = try js(
                """
                window.loreEditor.selectAt(
                  window.loreEditor.text().indexOf(\(CM6EditorView.Coordinator.jsString(needle))))
                """)
        }
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
    }

    /// The fonts are local files beside the page. If they were not reachable,
    /// KaTeX would still produce markup and the maths would silently render in
    /// a fallback face — so the font is asked about directly.
    @MainActor
    func test_theMathFontIsActuallyLoaded() throws {
        try boot("$x^2$\n\n")
        try waitFor("the KaTeX font to load") {
            ((try? self.js("document.fonts.check('10px KaTeX_Math')")) as? Bool) == true
        }
        XCTAssertEqual(try js("document.fonts.check('10px KaTeX_Math')") as? Bool, true)
    }
}
