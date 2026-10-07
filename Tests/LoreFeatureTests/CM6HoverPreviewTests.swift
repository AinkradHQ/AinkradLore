import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// The link hover preview on the CodeMirror surface.
///
/// The rules are the native editor's (`MarkdownEditorHover`), and the one that
/// decides whether this feels considered or twitchy is the delay: 450ms of
/// STILLNESS, not of presence. Movement within a single link restarts the wait,
/// so crossing a link on the way somewhere else shows nothing — otherwise a
/// document full of links becomes a flicker.
///
/// Rendered in the page, like the completion list: a popover that follows the
/// pointer cannot afford a round trip for its position, and it dismisses on the
/// pointer leaving, which is a DOM event.
final class CM6HoverPreviewTests: XCTestCase {

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
        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
    }

    @MainActor
    private func postedPreviews() throws -> [String] {
        (try js("window.__posted.filter(m => m.kind === 'preview').map(m => m.target)")
            as? [String]) ?? []
    }

    // MARK: - the delay measures stillness

    /// Pointing at a link does not show anything on its own. The request is only
    /// made once the pointer has been still.
    @MainActor
    func test_pointingAtALinkAsksForNothingUntilThePointerRests() throws {
        try boot("See [[Design Doc]] here.\n\n")
        XCTAssertEqual(try js("window.loreEditor.hoverAt(0)") as? Bool, true)
        XCTAssertEqual(try postedPreviews(), [], "nothing is asked for yet")
        XCTAssertEqual(
            try js("window.loreEditor.hoverPendingTarget()") as? String,
            "Design Doc")
        // The stillness elapsing is what asks.
        XCTAssertEqual(try js("window.loreEditor.flushHover()") as? Bool, true)
        XCTAssertEqual(try postedPreviews(), ["Design Doc"])
    }

    /// Movement WITHIN the same link restarts the wait — the delay measures
    /// stillness, not presence. Two moves must still be one request, not two.
    @MainActor
    func test_movingWithinOneLinkRestartsTheWaitRatherThanAskingTwice() throws {
        try boot("See [[Design Doc]] here.\n\n")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.hoverAt(0)")
        XCTAssertEqual(try postedPreviews(), [], "no request has been made yet")
        _ = try js("window.loreEditor.flushHover()")
        XCTAssertEqual(try postedPreviews(), ["Design Doc"], "one request, not three")
    }

    /// The pointer leaving cancels a pending request outright. Crossing a link
    /// on the way somewhere else must show nothing at all.
    @MainActor
    func test_thePointerLeavingCancelsThePendingRequest() throws {
        try boot("See [[Design Doc]] here.\n\n")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.hoverAway()")
        XCTAssertEqual(
            try js("window.loreEditor.flushHover()") as? Bool, false,
            "there is nothing left to fire")
        XCTAssertEqual(try postedPreviews(), [])
    }

    // MARK: - the popover

    @MainActor
    func test_theAnswerDrawsATitleAndAnExcerpt() throws {
        try boot("See [[Design Doc]] here.\n\n")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.flushHover()")
        _ = try js(
            """
            window.loreEditor.showPreview("Design Doc", "Design Doc",
                                          "Route B: use Obsidian's engine.")
            """)
        XCTAssertEqual(try js("window.loreEditor.previewIsOpen()") as? Bool, true)
        XCTAssertEqual(try js("window.loreEditor.previewTitle()") as? String, "Design Doc")
        XCTAssertEqual(
            try js("window.loreEditor.previewBody()") as? String,
            "Route B: use Obsidian's engine.")
    }

    /// The read happens off the main actor and can land after the reader has
    /// left the link. Presenting then would show a preview for a link nobody is
    /// pointing at, so a late answer is dropped.
    @MainActor
    func test_anAnswerThatArrivesAfterThePointerLeftIsDropped() throws {
        try boot("See [[Design Doc]] here.\n\n")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.flushHover()")
        _ = try js("window.loreEditor.hoverAway()")
        XCTAssertEqual(
            try js(
                """
                window.loreEditor.showPreview("Design Doc", "Design Doc", "body")
                """) as? Bool, false)
        XCTAssertEqual(try js("window.loreEditor.previewIsOpen()") as? Bool, false)
    }

    /// And an answer for a DIFFERENT link than the one now under the pointer.
    @MainActor
    func test_anAnswerForAnotherLinkIsDropped() throws {
        try boot("See [[One]] and [[Two]].\n\n")
        _ = try js("window.loreEditor.hoverAt(1)")
        XCTAssertEqual(
            try js(
                """
                window.loreEditor.showPreview("One", "One", "the wrong note")
                """) as? Bool, false)
        XCTAssertEqual(try js("window.loreEditor.previewIsOpen()") as? Bool, false)
    }

    /// A keystroke means the reader is writing, not reading.
    @MainActor
    func test_typingDismissesThePreview() throws {
        try boot("See [[Design Doc]] here.\n\n")
        _ = try js("window.loreEditor.hoverAt(0)")
        _ = try js("window.loreEditor.flushHover()")
        _ = try js(
            """
            window.loreEditor.showPreview("Design Doc", "Design Doc", "body")
            """)
        XCTAssertEqual(try js("window.loreEditor.previewIsOpen()") as? Bool, true)
        _ = try js("window.loreEditor.insertAtEnd('x')")
        XCTAssertEqual(try js("window.loreEditor.previewIsOpen()") as? Bool, false)
    }

    /// An embed chip is a link too, and so is an unresolved embed — both name a
    /// file the reader may want to look into.
    @MainActor
    func test_anEmbedChipCanBePreviewedToo() throws {
        try boot("![[Contract.pdf]]\n\n")
        XCTAssertEqual(try js("window.loreEditor.hoverAt(0)") as? Bool, true)
        XCTAssertEqual(
            try js("window.loreEditor.hoverPendingTarget()") as? String,
            "Contract.pdf")
    }

    // MARK: - the excerpt, which is the native one

    /// Delegated to `LinkPreview.excerpt`, not reimplemented: a second excerpt
    /// function would disagree with the first about where frontmatter ends.
    func test_theExcerptIsTheNativeOne() {
        let contents = """
            ---
            title: Design Doc
            ---
            # Design Doc

            Route B: use Obsidian's engine.
            """
        let excerpt = LinkPreview.excerpt(from: contents)
        XCTAssertFalse(excerpt.contains("title:"), "frontmatter is not the body")
        XCTAssertFalse(excerpt.hasPrefix("# "), "the leading heading is dropped")
        XCTAssertTrue(excerpt.contains("Route B"))
    }

    // MARK: - plumbing

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
}
