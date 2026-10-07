import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import LoreFeature

/// E1T2: Swift owns the document, and the editor never changes it behind our
/// back.
///
/// This is the task where a mistake corrupts notes rather than looking wrong,
/// so the assertions are about EXACT equality of text, not about appearance.
final class CM6DocumentContractTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    private var coordinator: CM6EditorView.Coordinator!
    private var stored = ""
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - harness

    @MainActor
    private func boot(_ text: String) throws {
        stored = text
        let binding = Binding<String>(get: { self.stored }, set: { self.stored = $0 })
        coordinator = CM6EditorView.Coordinator(text: binding)

        let config = WKWebViewConfiguration()
        config.userContentController.add(
            coordinator,
            name: CM6EditorView.Coordinator.bridgeName)
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        coordinator.pendingDocument = text

        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)

        let index = try XCTUnwrap(
            CM6EditorView.Coordinator.bundledIndexURL,
            "Editor/dist must be a resource of this bundle")
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("the editor to hold the document") {
            (try? self.js("window.loreEditor?.text?.().length") as? Int) ?? -1 >= 0
        }
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

    /// What the editor holds, translated back to the document's own line
    /// ending — which is the thing the contract is actually about. Reading the
    /// raw LF text would assert CodeMirror's internal representation instead.
    @MainActor
    private func editorText() throws -> String {
        let raw = try js("window.loreEditor.text()") as? String ?? "<none>"
        return CM6LineEndings.from(raw, to: CM6LineEndings.dominant(in: stored))
    }

    /// Let the bridge deliver. `postMessage` is asynchronous, so an assertion
    /// made immediately after a keystroke reads the previous state.
    @MainActor
    private func drain() throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - the contract

    /// Line endings survive a document with CONSISTENT endings, and mixed
    /// endings are normalised — the declared trade in `CM6LineEndings`.
    ///
    /// CodeMirror normalises `\r\n` and `\r` to `\n` in its document model and
    /// cannot be configured out of it (measured: every ending, including
    /// mixed). Handing it a CRLF note and taking it back would rewrite every
    /// line ending in the file — a whole-file diff on open, before the reader
    /// typed anything, and invisible because nothing LOOKS different.
    @MainActor
    func test_consistentLineEndingsRoundTripAndMixedAreNormalised() throws {
        for (name, doc) in [
            ("crlf", "one\r\ntwo\r\nthree\r\n"),
            ("cr", "one\rtwo\r"),
            ("lf", "one\ntwo\n"),
        ] {
            try boot(doc)
            XCTAssertEqual(try editorText(), doc, "\(name) must survive exactly")
        }

        // Mixed: normalised to the dominant ending.
        //
        // This is the surface's FALLBACK, not its policy. A mixed document does
        // not reach here at all — `MarkdownDocumentEditor.chooseSurface(for:)`
        // opens it in the native editor, where every byte survives. The
        // behaviour is still pinned, because a fallback nobody tests is a
        // fallback nobody knows the shape of, and because this is the exact
        // loss that justifies the routing rule.
        let mixed = "a\r\nb\r\nc\nd\r\n"
        XCTAssertFalse(CM6LineEndings.isConsistent(mixed))
        XCTAssertEqual(CM6LineEndings.dominant(in: mixed), .crlf)
        try boot(mixed)
        XCTAssertEqual(
            try editorText(), "a\r\nb\r\nc\r\nd\r\n",
            "mixed endings become the dominant one — which is why such a "
                + "document is routed to the native editor instead")
    }

    func test_lineEndingDetection() {
        XCTAssertEqual(CM6LineEndings.dominant(in: "a\r\nb\r\n"), .crlf)
        XCTAssertEqual(CM6LineEndings.dominant(in: "a\nb\n"), .lf)
        XCTAssertEqual(CM6LineEndings.dominant(in: "a\rb\r"), .cr)
        XCTAssertEqual(CM6LineEndings.dominant(in: ""), .lf, "a new note is LF")
        XCTAssertEqual(CM6LineEndings.dominant(in: "no endings at all"), .lf)
        // A tie goes to LF rather than to whichever was counted first.
        XCTAssertEqual(CM6LineEndings.dominant(in: "a\r\nb\n"), .lf)
        XCTAssertTrue(CM6LineEndings.isConsistent("a\r\nb\r\n"))
        XCTAssertFalse(CM6LineEndings.isConsistent("a\r\nb\n"))
        XCTAssertEqual(CM6LineEndings.toLF("a\r\nb\rc\n"), "a\nb\nc\n")
        XCTAssertEqual(CM6LineEndings.from("a\nb\n", to: .crlf), "a\r\nb\r\n")
    }

    @MainActor
    func test_theDocumentSurvivesTheHandoffExactly() throws {
        let doc = "# Title\n\nprose with `code`, **bold**, and a | table | too\n"
        try boot(doc)
        XCTAssertEqual(try editorText(), doc)
    }

    /// Every keystroke, not just the last one. A drift of one character that
    /// only appears after N edits is exactly what a single round-trip check
    /// misses.
    @MainActor
    func test_twoHundredKeystrokesKeepSwiftAndTheEditorIdentical()
        throws
    {
        try boot("start\n")
        for i in 0..<200 {
            _ = try js(
                """
                (() => { const v = window.loreEditor; v.insertAtEnd('\(i % 10)'); })()
                """)
            if i % 25 == 0 { try drain() }
        }
        try drain()
        let editor = try editorText()
        XCTAssertEqual(
            stored, editor,
            "Swift's copy and the editor's must be the same string")
        XCTAssertEqual(
            editor.filter(\.isNumber).count, 200,
            "every keystroke must be present exactly once")
    }

    /// The cases that break naive escaping and encoding, each verified byte for
    /// byte. Any of these silently mangled is a corrupted note.
    @MainActor
    func test_awkwardTextCrossesTheBridgeUnchanged() throws {
        let cases: [(String, String)] = [
            ("emoji", "a 👍🏽 b 👨‍👩‍👧‍👦 c\n"),
            ("arabic", "بسم الله الرحمن الرحيم\n"),
            ("rtl mixed", "start مرحبا end\n"),
            ("quotes and backslashes", #"he said "hi" \ and \\ and \" \n"#),
            ("crlf", "one\r\ntwo\r\nthree\r\n"),
            ("lone cr", "one\rtwo\r"),
            ("line separator U+2028", "before\u{2028}after\n"),
            ("null-ish and controls", "a\u{0001}b\u{001F}c\n"),
            ("combining marks", "e\u{0301}\u{0327} test\n"),
            ("tabs and trailing space", "a\tb   \n  indented\n"),
        ]
        for (name, doc) in cases {
            try boot(doc)
            XCTAssertEqual(try editorText(), doc, "\(name) did not survive the handoff")
        }
    }

    /// Rule 1: a change Swift asked for must NOT come back as user input.
    @MainActor
    func test_pushingADocumentDoesNotEchoBackAsAnEdit() throws {
        try boot("original\n")
        stored = "replaced by swift\n"
        coordinator.push(document: stored)
        try drain()
        XCTAssertEqual(try editorText(), "replaced by swift\n")
        XCTAssertEqual(
            stored, "replaced by swift\n",
            "the push must not be reported back and re-applied")
    }

    /// Rule 2: Swift must not push text the editor just reported, or every
    /// keystroke costs a document replacement and a caret reset.
    @MainActor
    func test_swiftDoesNotPushBackWhatTheEditorJustReported() throws {
        try boot("abc\n")
        _ = try js("window.loreEditor.insertAtEnd('X')")
        try drain()
        let afterEdit = try editorText()

        // Simulate SwiftUI calling updateNSView with the text it was just given.
        _ = try js("window.loreEditor.__setDocumentCalls = 0")
        coordinator.push(document: stored)
        try drain()
        let calls = try js("window.loreEditor.__setDocumentCalls ?? 0") as? Int ?? -1
        XCTAssertEqual(calls, 0, "an echo must be dropped before it reaches the editor")
        XCTAssertEqual(try editorText(), afterEdit)
    }

    /// The escaping helper, on its own, because it is the single place text
    /// crosses into JavaScript.
    func test_jsStringEscapesRatherThanConcatenates() {
        let quoted = CM6EditorView.Coordinator.jsString(#"a "b" \c"#)
        XCTAssertTrue(quoted.hasPrefix("\"") && quoted.hasSuffix("\""))
        XCTAssertFalse(quoted.contains(#"a "b""#), "quotes must be escaped, not passed through")
        XCTAssertEqual(CM6EditorView.Coordinator.jsString("a\nb"), #""a\nb""#)
    }
}
