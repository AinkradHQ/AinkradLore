import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T1c: `![[Note.md]]` shows the note.
///
/// The slicing is `TransclusionResolver`'s — `![[note#Heading]]`, `#^block-id`,
/// the frontmatter strip, the cycle and depth caps. These tests are about the
/// SURFACE: that it asks once, draws what it is given, renders it with the same
/// decorations as the outer document, and never expands an embed inside an
/// embed.
final class CM6TransclusionTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    private var bridge: Bridge!

    /// Stands in for the Swift coordinator: records what was asked for and
    /// answers from a fixed set of notes.
    @MainActor
    final class Bridge: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var requests: [String] = []
        var notes: [String: String] = [:]
        /// Withhold the answer, so the placeholder can be asserted.
        var answers = true

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                body["kind"] as? String == "transclude",
                let target = body["target"] as? String
            else { return }
            requests.append(target)
            guard answers else { return }
            let known = notes[target]
            let kind = known == nil ? "error" : "content"
            let text = known ?? "Could not resolve \"\(target)\"."
            webView?.evaluateJavaScript(
                "window.loreEditor.provideTransclusion(\(Self.q(target)), "
                    + "\(Self.q(kind)), \(Self.q(text)))")
        }

        static func q(_ value: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [value])
            let array = String(data: data, encoding: .utf8)!
            return String(array.dropFirst().dropLast())
        }
    }

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func boot(
        _ text: String, notes: [String: String],
        answering: Bool = true
    ) throws {
        bridge = Bridge()
        bridge.notes = notes
        bridge.answers = answering
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "lore")
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: config)
        bridge.webView = webView
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
        // BEFORE `init`, not after.
        //
        // Clearing the "already asked" set after the document was loaded threw
        // away the record of the request `init` had just made, so the next
        // redraw asked a second time — and
        // `test_itDoesNotReAskOnEveryRedraw` failed against perfectly correct
        // code. A test hook placed one line too late invalidated the very
        // invariant it was there to protect.
        _ = try js("window.loreEditor.__resetTransclusionRequests()")
        _ = try js("window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))")
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
    private func text(of index: Int) throws -> String {
        (try js("window.loreEditor.transclusionText(\(index))") as? String) ?? ""
    }

    @MainActor
    private func waitForContent(_ needle: String, at index: Int = 0) throws {
        try waitFor("\"\(needle)\" to arrive") {
            ((try? self.text(of: index)) ?? "").contains(needle)
        }
    }

    // MARK: - it asks, and it draws

    @MainActor
    func test_anEmbeddedNoteIsAskedForOnceAndThenShown() throws {
        try boot(
            "Before.\n\n![[Some Note.md]]\n\nAfter.\n\n",
            notes: ["Some Note.md": "Embedded body.\n"])
        try waitForContent("Embedded body.")
        XCTAssertEqual(bridge.requests, ["Some Note.md"])
        XCTAssertEqual(
            try js("window.loreEditor.transclusionTargets()") as? [String],
            ["Some Note.md"])
        // The outer document still reads normally around it.
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertTrue(shown.contains("Before."))
        XCTAssertTrue(shown.contains("After."))
    }

    /// A redraw happens on every keystroke. Re-asking on each would be a
    /// message per character typed.
    @MainActor
    func test_itDoesNotReAskOnEveryRedraw() throws {
        try boot("![[Some Note.md]]\n\n", notes: ["Some Note.md": "Body.\n"])
        try waitForContent("Body.")
        for _ in 0..<5 { _ = try js("window.loreEditor.insertAtEnd('x')") }
        XCTAssertEqual(
            bridge.requests, ["Some Note.md"],
            "one request, however many redraws")
    }

    /// THE reason this is a nested editor and not a second renderer: an
    /// embedded heading has to look like a heading, and an embedded wikilink
    /// has to look like a link.
    @MainActor
    func test_embeddedContentIsRenderedNotShownAsSource() throws {
        try boot(
            "![[Some Note.md]]\n\n",
            notes: [
                "Some Note.md": "## A heading\n\nWith **bold** and a [[link]].\n\n- one\n"
            ])
        try waitForContent("A heading")
        let inner = try text(of: 0)
        XCTAssertFalse(inner.contains("##"), "the heading marker must be hidden: \(inner)")
        XCTAssertFalse(inner.contains("**"), "the emphasis marker must be hidden: \(inner)")
        XCTAssertFalse(inner.contains("[["), "the link brackets must be hidden: \(inner)")
        XCTAssertTrue(inner.contains("•"), "a bullet must be drawn: \(inner)")
    }

    /// The nested editor has a selection whether or not anyone put one there —
    /// it defaults to offset 0 — so an embedded note showed `## Heading` on its
    /// FIRST line while every other line rendered. There is no caret in
    /// somebody else's text.
    @MainActor
    func test_theFirstLineOfAnEmbedIsRenderedLikeEveryOther() throws {
        try boot("![[Some Note.md]]\n\n", notes: ["Some Note.md": "## First line\n\nBody.\n"])
        try waitForContent("First line")
        let inner = try text(of: 0)
        XCTAssertFalse(inner.contains("##"), "got \(inner)")
    }

    /// One flat slice, as the native renderer draws. This is what makes a cycle
    /// impossible rather than merely capped.
    @MainActor
    func test_anEmbedInsideAnEmbedIsNotExpanded() throws {
        try boot(
            "![[Outer.md]]\n\n",
            notes: [
                "Outer.md": "Outer body, embedding ![[Inner.md]] here.\n",
                "Inner.md": "INNER CONTENT\n",
            ])
        try waitForContent("Outer body")
        let inner = try text(of: 0)
        XCTAssertTrue(
            inner.contains("![[Inner.md]]"),
            "a nested embed stays source: \(inner)")
        XCTAssertFalse(inner.contains("INNER CONTENT"), "got \(inner)")
        XCTAssertEqual(bridge.requests, ["Outer.md"], "and is never even asked for")
    }

    /// A note embedding itself must not recurse, and must not need a depth cap
    /// to stop.
    @MainActor
    func test_aNoteThatEmbedsItselfDrawsOnce() throws {
        try boot("![[Self.md]]\n\n", notes: ["Self.md": "I embed ![[Self.md]].\n"])
        try waitForContent("I embed")
        XCTAssertEqual(
            try js("window.loreEditor.transclusionTargets()") as? [String],
            ["Self.md"])
        XCTAssertEqual(bridge.requests, ["Self.md"])
    }

    // MARK: - the states that are not content

    @MainActor
    func test_anUnresolvedEmbedSaysSo() throws {
        try boot("![[Nope.md]]\n\n", notes: [:])
        try waitForContent("Could not resolve")
    }

    @MainActor
    func test_thereIsAPlaceholderBeforeTheAnswerArrives() throws {
        try boot("![[Slow.md]]\n\n", notes: ["Slow.md": "Body.\n"], answering: false)
        try waitFor("the box to be drawn") {
            ((try? self.js("window.loreEditor.transclusionTargets()")) as? [String])?
                .isEmpty == false
        }
        // Drawn, asked for, and not yet answered: the box exists and holds no
        // content. It must not be empty of the target's NAME, or an embed that
        // never resolves is an unexplained blank.
        let box = try text(of: 0)
        XCTAssertTrue(box.contains("Slow.md"), "got \(box)")
        XCTAssertEqual(bridge.requests, ["Slow.md"])
    }

    // MARK: - the invariant

    @MainActor
    func test_renderingChangesNoByteOfTheDocument() throws {
        let source = "Before.\n\n![[Some Note.md]]\n\n![[Nope.md]]\n\nAfter.\n"
        try boot(source, notes: ["Some Note.md": "Body.\n"])
        try waitForContent("Body.")
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
    }

    /// The caret's own line still shows the source, as it does for every other
    /// construct — that is how the embed is edited.
    @MainActor
    func test_theCaretsOwnLineShowsTheSource() throws {
        try boot("![[Some Note.md]]\n\nAfter.\n\n", notes: ["Some Note.md": "Body.\n"])
        try waitForContent("Body.")
        _ = try js("window.loreEditor.selectAt(2)")
        XCTAssertEqual(try js("window.loreEditor.transclusionTargets()") as? [String], [])
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertTrue(shown.contains("![[Some Note.md]]"), "got \(shown)")
    }
}
