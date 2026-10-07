import AinkradAppKit
import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import LoreFeature

/// E4T2: one document holding every construct Lore renders, shot in BOTH
/// surfaces so they can be reviewed side by side.
///
/// Against **the Lore that ships**, not against Obsidian. The question this
/// answers is narrow and specific: is there anything today's editor renders
/// that the CodeMirror surface does not?
///
/// It is a test rather than a pair of hand-made screenshots because a hand-made
/// pair is out of date the moment either surface changes, and because the two
/// shots have to come from the same document and the same theme or the
/// comparison proves nothing. The PNGs are written to `$LORE_PARITY_DIR` when
/// it is set (`make parity`, one pair per host palette: `native-<palette>.png`,
/// `cm6-<palette>.png` — S15/S16 of the Epic 5B screen inventory), otherwise to
/// a temporary directory for the first palette only, so the normal suite pays
/// for one pair rather than seven. The assertions are the machine-checkable
/// part — neither surface may render blank, and every construct must leave a
/// mark.
final class CM6ParityShotTests: XCTestCase {

    private var windows: [NSWindow] = []
    /// The bridges `boot(_:tokens:)` installs; a web view holds its
    /// navigation delegate weakly.
    private var coordinators: [CM6EditorView.Coordinator] = []
    override func tearDown() {
        windows.removeAll()
        coordinators.removeAll()
        super.tearDown()
    }

    /// One of everything. Ordered so the shot reads top to bottom like a
    /// checklist.
    static let parityDocument = """
        # Heading one

        ## Heading two

        ### Heading three

        Prose with **bold**, *italic*, ~~strikethrough~~, `inline code`, and a
        hard-wrapped line so paragraph spacing is visible.

        A [[Wikilink]], an aliased [[Target|alias]], a [markdown link](https://x.test/p),
        and a #tag plus #nested/tag.

        - a bullet
        - another
            - nested
                - deeper

        1. ordered
        2. second

        - [ ] an open task
        - [x] a done task

        > A plain block quote
        > over two lines.

        > [!note] A callout with a title
        > Its body.

        > [!warning]
        > A callout with no title.

        ```swift
        let fenced = "code block"
        ```

        | Area | Owner | Note |
        |---|---|---|
        | Editor | Ahmed | see [[Design Doc]] |
        | Index | Ahmed | **unchanged** |

        Maths: inline $\\pi r^2$ and a block:

        $$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$

        ---

        A footnote reference[^1] and an unresolved embed ![[missing.png]].

        [^1]: The footnote text.

        """

    // MARK: - the two shots

    @MainActor
    func test_bothSurfacesRenderTheWholeParityDocument() throws {
        var palettes = try parityPalettes()
        let directory: URL
        if let parity = try parityOutputDirectory() {
            directory = parity
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lore-parity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            palettes = Array(palettes.prefix(1))
        }

        for palette in palettes {
            let native = try shootNative(Self.parityDocument, palette: palette)
            try write(native, to: directory.appendingPathComponent("native-\(palette.id).png"))

            let cm6 = try shootCM6(Self.parityDocument, palette: palette)
            try write(cm6, to: directory.appendingPathComponent("cm6-\(palette.id).png"))

            // Neither may be blank. A uniformly-coloured image is what a surface
            // that failed to boot produces, and it is indistinguishable from a
            // working one in a size check.
            XCTAssertGreaterThan(
                distinctRowCount(of: native), 20,
                "the native surface rendered nothing (\(palette.id))")
            XCTAssertGreaterThan(
                distinctRowCount(of: cm6), 20,
                "the CM6 surface rendered nothing (\(palette.id))")
        }

        print("PARITY SHOTS \(directory.path)")
    }

    /// The machine-checkable half of the checklist: every construct leaves a
    /// mark on the CM6 surface. A screenshot pair tells a human whether it
    /// looks right; this tells CI whether anything vanished.
    @MainActor
    func test_everyConstructLeavesAMarkOnTheCM6Surface() throws {
        let webView = try boot(Self.parityDocument)
        func number(_ expression: String) throws -> Int {
            (try js(expression, in: webView) as? Int) ?? -1
        }
        // Present, and counted rather than merely non-zero, so a construct
        // rendering once when the document holds three is a failure too.
        // Three: `[[Wikilink]]`, `[[Target|alias]]`, and `[[Design Doc]]` inside
        // the table cell. The markdown link and the footnote are neither.
        XCTAssertEqual(try number("window.loreEditor.wikilinkTargets().length"), 3)
        XCTAssertEqual(try number("window.loreEditor.tagNames().length"), 2)
        XCTAssertEqual(try number("window.loreEditor.checkboxStates().length"), 2)
        XCTAssertEqual(try number("window.loreEditor.calloutKinds().length"), 2)
        XCTAssertEqual(try number("window.loreEditor.tableCount()"), 1)
        XCTAssertEqual(try number("document.querySelectorAll('.cm-lore-rule').length"), 1)
        XCTAssertGreaterThan(try number("document.querySelectorAll('.cm-lore-bullet').length"), 3)
        XCTAssertGreaterThan(
            try number(
                "document.querySelectorAll('.cm-lore-code, "
                    + ".cm-lore-code-first, .cm-lore-code-last').length"), 2)
        // Maths needs its engine, which arrives on demand.
        try waitFor("the maths engine") {
            ((try? self.js("window.loreEditor.mathEngineLoaded()", in: webView)) as? Bool) == true
        }
        XCTAssertEqual(try number("window.loreEditor.mathCount()"), 2)
        XCTAssertEqual(try number("window.loreEditor.mathErrorCount()"), 0)
        XCTAssertEqual(try number("window.loreEditor.embedMissingTargets().length"), 1)

        // And the document is untouched by all of it.
        XCTAssertEqual(
            try js("window.loreEditor.text()", in: webView) as? String,
            Self.parityDocument)
    }

    /// The four gaps the parity shots found against the Lore that ships, each
    /// pinned so it cannot reopen.
    ///
    /// Every one was invisible to the E2 tests, because each of those asked
    /// "does the construct I just built work?" and none asked "does this
    /// surface still do everything the old one did?". That is the whole value of
    /// a checklist against the shipping editor rather than against Obsidian.
    @MainActor
    func test_theFourGapsFoundByTheParityShots() throws {
        let webView = try boot(
            "# A heading\n\nProse with ~~struck~~ text and `inline code`.\n\n"
                + "A reference[^1] here.\n\n[^1]: The note.\n\n")
        func number(_ expression: String) throws -> Int {
            (try js(expression, in: webView) as? Int) ?? -1
        }
        let shown =
            try js(
                "document.querySelector('.cm-content').innerText",
                in: webView) as? String ?? ""

        // 1. Strikethrough. CommonMark has no such node, so `~~struck~~` kept
        //    its tildes and was never struck; GFM is enabled now.
        XCTAssertFalse(shown.contains("~~"), "the tildes must be hidden: \(shown)")
        XCTAssertTrue(shown.contains("struck"))

        // 2. The inline-code pill M9.9 draws natively.
        XCTAssertEqual(try number("document.querySelectorAll('.cm-lore-inline-code').length"), 1)

        // 3. Heading rhythm — a class per level, which the stylesheet spaces.
        XCTAssertEqual(try number("document.querySelectorAll('.cm-lore-h1').length"), 1)

        // 4. Footnotes: a superscript reference and a labelled definition,
        //    rather than a bare `^1` left sitting in the prose.
        XCTAssertEqual(try number("document.querySelectorAll('.cm-lore-footnote-ref').length"), 1)
        XCTAssertEqual(try number("document.querySelectorAll('.cm-lore-footnote-def').length"), 1)
        XCTAssertFalse(shown.contains("[^1]"), "the notation must be gone: \(shown)")
        XCTAssertFalse(shown.contains("^1"), "not even the caret: \(shown)")
    }

    /// Enabling GFM for strikethrough must not disturb the constructs this file
    /// hand-rolls. GFM brings its own table and task-list nodes, and the tables
    /// and tasks here scan lines independently of the tree.
    @MainActor
    func test_enablingGFMDidNotDisturbTablesOrTasks() throws {
        let webView = try boot(
            "| A | B |\n|---|---|\n| one | two |\n\n- [ ] open\n- [x] done\n\n")
        XCTAssertEqual(try js("window.loreEditor.tableCount()", in: webView) as? Int, 1)
        XCTAssertEqual(
            try js("window.loreEditor.checkboxStates()", in: webView) as? [Bool],
            [false, true])
        XCTAssertEqual(
            try js(
                "document.querySelectorAll('.cm-lore-bullet').length",
                in: webView) as? Int, 0,
            "a task shows its checkbox, not a bullet as well")
    }

    // MARK: - the native surface

    @MainActor
    private func shootNative(_ text: String, palette: ParityPalette) throws -> NSBitmapImageRep {
        // Let the editor's own asynchronous styling passes run. The native
        // surface styles on a background actor and applies later, so a shot
        // taken immediately is of unstyled text.
        try shoot(
            MarkdownEditor(text: .constant(text), tokens: palette.tokens),
            size: CGSize(width: 1000, height: 1600), palette: palette, settleFor: 2)
    }

    // MARK: - the CM6 surface

    /// With `tokens`, the page boots through the REAL coordinator path —
    /// document and theme handed over on `didFinish`, exactly as
    /// `CM6EditorView.makeNSView` does — so a palette reaches the CSS
    /// variables by the bridge Lore ships, not by a copy of it.
    @MainActor
    private func boot(_ text: String, tokens: HostThemeTokens? = nil) throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1600))
        let window = makeOffscreenWindow(webView.frame)
        window.contentView = webView
        windows.append(window)
        var coordinator: CM6EditorView.Coordinator?
        if let tokens {
            let bridge = CM6EditorView.Coordinator(text: .constant(text))
            bridge.webView = webView
            bridge.pendingDocument = text
            bridge.pendingTheme = (tokens, .default)
            webView.navigationDelegate = bridge
            // As `makeNSView` sets it: the page paints `--bg` itself.
            webView.setValue(false, forKey: "drawsBackground")
            coordinators.append(bridge)
            coordinator = bridge
        }
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("boot") {
            ((try? self.js("typeof window.loreEditor", in: webView)) as? String) == "object"
        }
        if let coordinator {
            // `finishLoading` clears both once it has pushed them.
            try waitFor("the theme bridge") {
                coordinator.pendingTheme == nil && coordinator.pendingDocument == nil
            }
        } else {
            _ = try js(
                "window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))",
                in: webView)
        }
        // The caret at the end, so nothing is revealed as source — the reader's
        // view of a note they have just opened and not yet clicked into.
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().length)", in: webView)
        return webView
    }

    @MainActor
    private func shootCM6(_ text: String, palette: ParityPalette) throws -> NSBitmapImageRep {
        let webView = try boot(text, tokens: palette.tokens)
        try waitFor("the maths engine") {
            ((try? self.js("window.loreEditor.mathEngineLoaded()", in: webView)) as? Bool) == true
        }
        settle(1)
        var captured: NSImage?
        var done = false
        webView.takeSnapshot(with: nil) { image, _ in
            captured = image
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let image = try XCTUnwrap(captured, "takeSnapshot produced nothing")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    // MARK: - plumbing

    @MainActor @discardableResult
    private func js(_ source: String, in webView: WKWebView) throws -> Any? {
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
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
