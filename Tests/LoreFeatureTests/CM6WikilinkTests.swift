import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T1b: `[[wikilinks]]` render, and clicking one opens its target.
///
/// The two halves are tested separately on purpose. A link that renders but
/// does not open looks finished in a screenshot, which is exactly the failure
/// mode M9 shipped four times — so the bridge message is asserted, not the
/// appearance alone.
final class CM6WikilinkTests: XCTestCase {

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
        // The caret parks at the end. A caret on a link's own line REVEALS it,
        // which is correct behaviour and would fail every render assertion
        // below — see the same note in `CM6LivePreviewTests`.
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

    @MainActor
    private func targets() throws -> [String] {
        try js("window.loreEditor.wikilinkTargets()") as? [String] ?? []
    }

    @MainActor
    private func texts() throws -> [String] {
        try js("window.loreEditor.wikilinkTexts()") as? [String] ?? []
    }

    // MARK: - rendering

    @MainActor
    func test_aWikilinkRendersItsTargetWithoutTheBrackets() throws {
        try boot("See [[Design Doc]] for more.\n\n")
        XCTAssertEqual(try targets(), ["Design Doc"])
        XCTAssertEqual(try texts(), ["Design Doc"])
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertFalse(shown.contains("[["), "the brackets must not be on screen: \(shown)")
    }

    /// The display half of `[[target|display]]` is what the reader sees; the
    /// target half is what a click must carry. Conflating the two gives a link
    /// that opens a note named after its own label.
    @MainActor
    func test_anAliasShowsTheLabelAndCarriesTheTarget() throws {
        try boot("See [[Projects/Design Doc|the design]] for more.\n\n")
        XCTAssertEqual(try texts(), ["the design"])
        XCTAssertEqual(try targets(), ["Projects/Design Doc"])
    }

    /// The reveal rule, for this construct. The marker you need in order to
    /// edit a link is the one you are standing in.
    @MainActor
    func test_theCaretsOwnLineShowsTheSource() throws {
        try boot("See [[Design Doc]] here.\n\nAnd [[Other]] there.\n\n")
        XCTAssertEqual(try targets().sorted(), ["Design Doc", "Other"])
        _ = try js(
            """
            (() => {
              const doc = window.loreEditor.text();
              window.loreEditor.selectAt(doc.indexOf("Design Doc"));
            })()
            """)
        // The caret's line reverts to source; the other line stays rendered.
        XCTAssertEqual(try targets(), ["Other"])
    }

    /// `LinkParser` excludes a `[[link]]` inside code from the link graph, so
    /// rendering one here would offer the reader something clickable that no
    /// backlink and no rename knows about.
    @MainActor
    func test_aLinkInsideCodeIsProseNotALink() throws {
        try boot("Write `[[Target]]` to link.\n\n```\n[[AlsoNotALink]]\n```\n\n")
        XCTAssertEqual(try targets(), [])
    }

    /// An embed is a different construct with a different rendering (E2T1c).
    ///
    /// The first version of this test asserted only `targets() == []`, which
    /// passed while the screenshot showed `![[some-image.png]]` rendered as a
    /// bare accent-coloured `some-image.png`: lezer parses `![[x]]` as an
    /// image, so E2T0's marker-hiding was collapsing it by a DIFFERENT code
    /// path than the one being asserted. So this now asserts what the reader
    /// sees, which is the only thing that would have caught it.
    /// An embed is never a plain link — whatever it becomes.
    ///
    /// It has become three different things across this milestone: source
    /// (before E2T5), an image or a chip (E2T5), and a transclusion box for a
    /// markdown target (E2T1c). What has to stay true through all of that is
    /// that it is not silently collapsed into an ordinary wikilink, which is
    /// what E2T0's marker-hiding was doing.
    @MainActor
    func test_anEmbedIsNeverRenderedAsAPlainLink() throws {
        try boot("An embed: ![[Some Note.md]]\n\n")
        XCTAssertEqual(
            try targets(), [],
            "an embed must never appear among the plain wikilinks")
        // A markdown target is a transclusion. There is no bridge in this
        // harness, so the box stays a placeholder — which still has to name the
        // note rather than show nothing.
        XCTAssertEqual(
            try js("window.loreEditor.transclusionTargets()") as? [String],
            ["Some Note.md"])
    }

    /// A link in a table cell, which the table widget renders itself.
    ///
    /// Also found by the screenshot: every link on the page was rendered
    /// except the one inside the grid, which sat there as `[[Design Doc]]` and
    /// read as the table being half-rendered.
    @MainActor
    func test_aLinkInsideATableCellIsRenderedAndClickable() throws {
        try boot("| A | B |\n|---|---|\n| [[Design Doc]] | two |\n\n")
        XCTAssertEqual(try targets(), ["Design Doc"])
        let cell = try js("document.querySelector('.cm-lore-table td').innerText") as? String ?? ""
        XCTAssertFalse(cell.contains("[["), "the cell must not show brackets: \(cell)")

        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
        _ = try js("window.loreEditor.clickWikilink(0, false)")
        XCTAssertEqual(try js("window.__posted[0].target") as? String, "Design Doc")
    }

    /// Obsidian does not paint a band behind the caret's line. CM6's
    /// `highlightActiveLine` does, full width and wider than the text measure,
    /// and it was the loudest element in the first screenshot.
    @MainActor
    func test_thereIsNoActiveLineBand() throws {
        try boot("One line.\n\nAnother.\n\n")
        XCTAssertEqual(try js("document.querySelectorAll('.cm-activeLine').length") as? Int, 0)
    }

    // MARK: - the click

    @MainActor
    func test_clickingALinkPostsItsRawTargetToSwift() throws {
        try boot("See [[Projects/Design Doc|the design]].\n\n")
        // The bridge is not installed in this harness, so the post is captured
        // rather than delivered — the assertion is about WHAT is sent.
        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
        XCTAssertEqual(try js("window.loreEditor.clickWikilink(0, false)") as? Bool, true)
        XCTAssertEqual(try js("window.__posted.length") as? Int, 1)
        XCTAssertEqual(try js("window.__posted[0].kind") as? String, "openLink")
        XCTAssertEqual(try js("window.__posted[0].target") as? String, "Projects/Design Doc")
        XCTAssertEqual(try js("window.__posted[0].beside") as? Bool, false)
    }

    @MainActor
    func test_cmdClickAsksForTheLinkBeside() throws {
        try boot("See [[Design Doc]].\n\n")
        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
        _ = try js("window.loreEditor.clickWikilink(0, true)")
        XCTAssertEqual(try js("window.__posted[0].beside") as? Bool, true)
    }

    // MARK: - the invariant every E2 task shares

    /// Rendering must not touch the document. This is the whole contract the
    /// search index, the link graph, rename and the MCP tools rest on: every
    /// one of them holds offsets into this string.
    @MainActor
    func test_renderingChangesNoByteOfTheDocument() throws {
        let source = """
            # Notes

            See [[Design Doc]] and [[Projects/Other|other]] and ![[img.png]].

            Write `[[NotALink]]` for the syntax.

            | A | B |
            |---|---|
            | [[In A Cell]] | two |

            """
        try boot(source)
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
        // And still unchanged after the caret has moved through every link,
        // because a reveal is a decoration change and must not be an edit.
        for needle in ["Design Doc", "other", "img.png", "NotALink", "In A Cell"] {
            _ = try js(
                """
                window.loreEditor.selectAt(
                  window.loreEditor.text().indexOf(\(CM6EditorView.Coordinator.jsString(needle))))
                """)
        }
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
    }
}
