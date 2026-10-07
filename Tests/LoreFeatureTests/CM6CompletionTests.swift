import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// `[[` and `#` completion on the CodeMirror surface, rendered in the page.
///
/// The design doc recommended a native popup; this overrides that with the
/// owner's word. The reasons are properties of the arrangement, not preferences:
/// a native panel must be anchored in screen coordinates reported per keystroke
/// (any lag and it points where the caret used to be), and the arrow keys belong
/// to whoever has focus, which is the web view.
///
/// What did NOT move into JavaScript is every decision that matters — which is
/// what these tests are mostly about. `CM6Completion` reuses the native
/// `LinkCompletionContext` scanner and `MarkdownEditing.linkInsertionRange`, so
/// the two surfaces cannot come to disagree about what is being completed or
/// what an accepted row replaces.
final class CM6CompletionTests: XCTestCase {

    // MARK: - the decisions, without a web view

    func test_theCaretsTriggerIsTheNativeScannersAnswer() {
        // Delegated, not reimplemented: asserting it here is asserting that the
        // delegation is wired, and the scanner's own rules are already covered
        // by the native tests.
        let text = "See [[desi"
        let trigger = LinkCompletionContext.trigger(in: text, at: text.count)
        XCTAssertEqual(trigger?.kind, .wikilink)
        XCTAssertEqual(trigger?.query, "desi")
    }

    /// CodeMirror positions are UTF-16 offsets; `LinkCompletionContext` works in
    /// CHARACTER offsets. Past an emoji the two differ, and getting it wrong
    /// replaces the wrong range on accept — not a cosmetic bug.
    func test_theCaretIsTranslatedFromUTF16ToCharacters() {
        // Measured, not assumed: 🌍 is ONE character and TWO UTF-16 units, so
        // the caret at the end of this string is 9 to CodeMirror and 8 to
        // `LinkCompletionContext`. The first version of this test asserted 10
        // and 9 — off by one in both, from counting the emoji as two characters
        // rather than as two units of one.
        let text = "🌍 [[desi"
        XCTAssertEqual(text.utf16.count, 9)
        XCTAssertEqual(text.count, 8)
        XCTAssertEqual(CM6Completion.characterOffset(ofUTF16: 9, in: text), 8)
        XCTAssertEqual(CM6Completion.characterOffset(ofUTF16: 0, in: text), 0)
        // Past the emoji, the two numbering systems have diverged by one.
        XCTAssertEqual(CM6Completion.characterOffset(ofUTF16: 2, in: text), 1)
        // The middle of a surrogate pair is refused rather than guessed.
        XCTAssertNil(CM6Completion.characterOffset(ofUTF16: 1, in: text))
        XCTAssertNil(CM6Completion.characterOffset(ofUTF16: 999, in: text))
    }

    @MainActor
    func test_theQueryOffersDocumentsAndACreateRowLast() throws {
        let rows = [Self.row("Design Doc"), Self.row("Design Review")]
        let query = try XCTUnwrap(
            CM6Completion.query(
                text: "See [[desi", utf16Caret: 10,
                documents: { _ in rows },
                headings: { _, _ in nil },
                tags: { _ in [] },
                linkTarget: { $0.title },
                canCreate: true))
        XCTAssertEqual(
            query.items.map(\.label),
            ["Design Doc", "Design Review", "Create \u{201C}desi\u{201D}"])
        // LAST, never first: a create row at the top is one stray Return away
        // from a duplicate note.
        XCTAssertEqual(query.items.last?.createsNote, "desi")
        // The replaced range is the typed prefix, and the insert closes the link.
        XCTAssertEqual(query.from, 6)
        XCTAssertEqual(query.to, 10)
        XCTAssertEqual(query.items.first?.insert, "Design Doc]]")
    }

    /// `[` auto-pairs, so typing `[[` leaves `[[]]` with the caret in the
    /// middle. The already-typed closer must be absorbed, or an accepted
    /// completion reads `[[Target]]]]`.
    @MainActor
    func test_anAlreadyTypedCloserIsAbsorbed() throws {
        let text = "See [[desi]]"
        let query = try XCTUnwrap(
            CM6Completion.query(
                text: text, utf16Caret: 10,
                documents: { _ in [Self.row("Design Doc")] },
                headings: { _, _ in nil }, tags: { _ in [] },
                linkTarget: { $0.title }, canCreate: false))
        XCTAssertEqual(query.to, 12, "the `]]` must be inside the replaced range")
        let result = (text as NSString).replacingCharacters(
            in: NSRange(location: query.from, length: query.to - query.from),
            with: query.items[0].insert)
        XCTAssertEqual(result, "See [[Design Doc]]")
    }

    /// A heading query stops offering documents and offers headings — and it
    /// inserts the RESOLVER-VERIFIED target, not what was typed, so the
    /// finished link cannot land on a namesake in another folder.
    @MainActor
    func test_aHeadingQueryInsertsTheVerifiedTarget() throws {
        let query = try XCTUnwrap(
            CM6Completion.query(
                text: "See [[Design#Over", utf16Caret: 17,
                documents: { _ in [Self.row("WRONG")] },
                headings: { _, _ in
                    HeadingCompletions(
                        insertTarget: "Projects/Design",
                        headings: ["Overview"])
                },
                tags: { _ in [] }, linkTarget: { $0.title }, canCreate: true))
        XCTAssertEqual(query.items.map(\.label), ["Overview"])
        XCTAssertEqual(query.items[0].insert, "Projects/Design#Overview]]")
    }

    @MainActor
    func test_aTagQueryReplacesTheHashThroughTheCaret() throws {
        let query = try XCTUnwrap(
            CM6Completion.query(
                text: "Tagged #proj", utf16Caret: 12,
                documents: { _ in [] }, headings: { _, _ in nil },
                tags: { _ in ["project/ainkrad"] },
                linkTarget: { $0.title }, canCreate: false))
        XCTAssertEqual(query.from, 7, "the `#` itself is replaced")
        XCTAssertEqual(query.to, 12)
        XCTAssertEqual(query.items[0].insert, "#project/ainkrad")
    }

    @MainActor
    func test_nothingIsOfferedWhenNothingIsBeingCompleted() {
        XCTAssertNil(
            CM6Completion.query(
                text: "Just prose.", utf16Caret: 11,
                documents: { _ in [Self.row("Design Doc")] },
                headings: { _, _ in nil }, tags: { _ in [] },
                linkTarget: { $0.title }, canCreate: true))
    }

    // MARK: - the list, in the page

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
    }

    /// Hand the page a query, exactly as the coordinator does.
    @MainActor
    private func show(_ query: CM6Completion.Query?) throws {
        _ = try js("window.loreEditor.showCompletions(\(CM6Completion.json(query)))")
    }

    @MainActor
    private func labels() throws -> [String] {
        (try js("window.loreEditor.completionLabels()") as? [String]) ?? []
    }

    @MainActor
    private func selected() throws -> Int {
        (try js("window.loreEditor.completionSelectedIndex()") as? Int) ?? -99
    }

    @MainActor
    private func documentText() throws -> String {
        (try js("window.loreEditor.text()") as? String) ?? ""
    }

    @MainActor
    func test_theListDrawsTheRowsAndSelectsTheFirst() throws {
        try boot("See [[desi\n")
        try show(Self.sampleQuery())
        XCTAssertEqual(try labels(), ["Design Doc", "Design Review"])
        XCTAssertEqual(try selected(), 0)
        XCTAssertEqual(try js("window.loreEditor.completionIsOpen()") as? Bool, true)
    }

    /// The arrow keys go through CodeMirror's own keymap. That is the assertion:
    /// `Prec.highest` has to beat the default keymap, or Return inserts a
    /// newline and the list is left open under a caret that has moved.
    @MainActor
    func test_theArrowKeysMoveTheSelectionAndWrap() throws {
        try boot("See [[desi\n")
        try show(Self.sampleQuery())
        _ = try js("window.loreEditor.completionKey('ArrowDown')")
        XCTAssertEqual(try selected(), 1)
        _ = try js("window.loreEditor.completionKey('ArrowDown')")
        XCTAssertEqual(try selected(), 0, "the selection wraps")
        _ = try js("window.loreEditor.completionKey('ArrowUp')")
        XCTAssertEqual(try selected(), 1, "and wraps backwards")
    }

    @MainActor
    func test_returnAcceptsTheSelectedRowAndClosesTheList() throws {
        try boot("See [[desi\n")
        try show(Self.sampleQuery())
        _ = try js("window.loreEditor.completionKey('ArrowDown')")
        XCTAssertEqual(try js("window.loreEditor.completionKey('Enter')") as? Bool, true)
        XCTAssertEqual(try documentText(), "See [[Design Review]]\n")
        XCTAssertEqual(try js("window.loreEditor.completionIsOpen()") as? Bool, false)
        XCTAssertEqual(try labels(), [], "the list must be gone from the DOM")
    }

    @MainActor
    func test_escapeDismissesWithoutTouchingTheDocument() throws {
        try boot("See [[desi\n")
        try show(Self.sampleQuery())
        XCTAssertEqual(try js("window.loreEditor.completionKey('Escape')") as? Bool, true)
        XCTAssertEqual(try documentText(), "See [[desi\n")
        XCTAssertEqual(try js("window.loreEditor.completionIsOpen()") as? Bool, false)
    }

    /// With no list open, these keys must NOT be swallowed — Return has to
    /// insert a newline like any other time.
    @MainActor
    func test_theKeysAreNotSwallowedWhenNoListIsOpen() throws {
        try boot("plain\n")
        XCTAssertEqual(try js("window.loreEditor.completionKey('Enter')") as? Bool, false)
        XCTAssertEqual(try js("window.loreEditor.completionKey('ArrowDown')") as? Bool, false)
        XCTAssertEqual(try js("window.loreEditor.completionKey('Escape')") as? Bool, false)
        XCTAssertEqual(try documentText(), "plain\n")
    }

    /// An empty answer closes the list. This is how Swift says "nothing is being
    /// completed any more" — there is no second message for it.
    @MainActor
    func test_anEmptyAnswerClosesTheList() throws {
        try boot("See [[desi\n")
        try show(Self.sampleQuery())
        XCTAssertEqual(try js("window.loreEditor.completionIsOpen()") as? Bool, true)
        try show(nil)
        XCTAssertEqual(try js("window.loreEditor.completionIsOpen()") as? Bool, false)
    }

    /// A create row does NOT edit the document from the page: it asks Swift,
    /// which makes the note and only then calls back. A refused create must
    /// leave the text untouched.
    @MainActor
    func test_aCreateRowAsksSwiftAndDoesNotEditOnItsOwn() throws {
        try boot("See [[newnote\n")
        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
        let query = CM6Completion.Query(
            from: 6, to: 13,
            items: [
                CM6Completion.Item(
                    label: "Create “newnote”", detail: "new note",
                    insert: "newnote]]", createsNote: "newnote")
            ])
        try show(query)
        _ = try js("window.loreEditor.completionKey('Enter')")
        XCTAssertEqual(
            try documentText(), "See [[newnote\n",
            "the page must not write a link to a note that may not exist")
        let posted = try js("window.__posted.filter(m => m.kind === 'completionCreate').length")
        XCTAssertEqual(posted as? Int, 1)
        // And once Swift confirms, the text lands.
        _ = try js("window.loreEditor.applyCompletion(6, 13, 'newnote]]')")
        XCTAssertEqual(try documentText(), "See [[newnote]]\n")
    }

    // MARK: - plumbing

    private static func row(_ title: String) -> IndexRow {
        IndexRow(
            path: URL(fileURLWithPath: "/vault/Projects/\(title).md"),
            id: title, title: title, tags: [], aliases: [], updated: Date(),
            type: MarkdownEngine.identifier, properties: [])
    }

    private static func sampleQuery() -> CM6Completion.Query {
        CM6Completion.Query(
            from: 6, to: 10,
            items: [
                CM6Completion.Item(
                    label: "Design Doc", detail: "Projects",
                    insert: "Design Doc]]", createsNote: nil),
                CM6Completion.Item(
                    label: "Design Review", detail: "Projects",
                    insert: "Design Review]]", createsNote: nil),
            ])
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
}
