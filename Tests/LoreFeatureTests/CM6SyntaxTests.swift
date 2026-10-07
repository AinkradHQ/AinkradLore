import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T2, E2T3, E2T4: tags, callouts and task checkboxes on the CM6 surface.
///
/// Each construct is asserted against WHAT THE READER SEES, not against the
/// scanner that feeds it. Every one of these three shipped a working scanner
/// and a broken rendering: `[x]` and `[!note]` both look like the start of a
/// link, so lezer's `LinkMark` claimed their brackets, the builder's overlap
/// guard kept whichever decoration came first, and the widget was discarded in
/// silence. A test on the scanner would have passed.
final class CM6SyntaxTests: XCTestCase {

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
    private func captureBridge() throws {
        _ = try js(
            """
            (() => {
              window.__posted = [];
              window.webkit = { messageHandlers: { lore: {
                postMessage: m => window.__posted.push(m) } } };
            })()
            """)
    }

    // MARK: - E2T2, tags

    /// The `#` stays. Obsidian keeps it, and a chip without it is
    /// indistinguishable from a link chip.
    @MainActor
    func test_aTagRendersAsAChipKeepingItsHash() throws {
        try boot("Tagged #project/ainkrad here.\n\n")
        XCTAssertEqual(
            try js("window.loreEditor.tagNames()") as? [String],
            ["project/ainkrad"])
        XCTAssertEqual(
            try js("window.loreEditor.tagTexts()") as? [String],
            ["#project/ainkrad"])
    }

    /// The disqualification list, transcribed from `MarkdownExtensions.scanTags`.
    /// A tag rendered here that the sidebar does not list is a tag the reader
    /// cannot click through to anything.
    @MainActor
    func test_everyThingThatLooksLikeATagAndIsNot() throws {
        try boot(
            """
            # A heading is not a tag

            Not #1234 an issue reference.

            Not `#incode` and not [a link](https://x.test/p#anchor).

            Not [[Note#Heading]] either.

            But #real is.

            """)
        XCTAssertEqual(try js("window.loreEditor.tagNames()") as? [String], ["real"])
    }

    @MainActor
    func test_clickingATagAsksTheShellToFilterByIt() throws {
        try boot("Tagged #editor here.\n\n")
        try captureBridge()
        XCTAssertEqual(try js("window.loreEditor.clickTag(0)") as? Bool, true)
        XCTAssertEqual(try js("window.__posted[0].kind") as? String, "openTag")
        XCTAssertEqual(try js("window.__posted[0].tag") as? String, "editor")
    }

    /// `EditorSettings.renderTagsAsChips`, which the native editor already
    /// lets be turned off — and which must take effect on the open document,
    /// not merely the next one.
    @MainActor
    func test_chipsCanBeTurnedOffAndTakeEffectImmediately() throws {
        try boot("Tagged #editor here.\n\n")
        XCTAssertEqual(try js("window.loreEditor.tagNames().length") as? Int, 1)
        _ = try js("window.loreEditor.setTagsAsChips(false)")
        XCTAssertEqual(try js("window.loreEditor.tagNames().length") as? Int, 0)
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertTrue(shown.contains("#editor"), "the tag must still be readable: \(shown)")
    }

    // MARK: - E2T3, callouts

    @MainActor
    func test_aCalloutDrawsItsKindAndTheAuthorsTitle() throws {
        try boot("> [!danger] Do not do this\n> It breaks.\n\n")
        XCTAssertEqual(try js("window.loreEditor.calloutKinds()") as? [String], ["danger"])
        let title = try js("window.loreEditor.calloutTitles()") as? [String] ?? []
        XCTAssertEqual(title.count, 1)
        XCTAssertTrue(title[0].contains("Do not do this"), "got \(title)")
        XCTAssertFalse(
            title[0].contains("[!danger]"),
            "the notation must not be on screen: \(title)")
    }

    /// Obsidian always shows a heading, so `> [!note]` alone renders as "Note".
    /// DRAWN, never inserted: putting it in the text would change the document.
    @MainActor
    func test_aCalloutWithNoTitleDrawsTheKindsOwnName() throws {
        let source = "> [!warning]\n> Careful.\n\n"
        try boot(source)
        let title = try js("window.loreEditor.calloutTitles()") as? [String] ?? []
        XCTAssertTrue(title.first?.contains("Warning") == true, "got \(title)")
        XCTAssertEqual(
            try js("window.loreEditor.text()") as? String, source,
            "the drawn title must not have entered the document")
    }

    /// Every spelling a vault written against Obsidian will actually contain.
    @MainActor
    func test_theAliasesObsidianAcceptsAllResolve() throws {
        try boot(
            """
            > [!tldr] a

            > [!caution] b

            > [!hint] c

            > [!error] d

            > [!cite] e

            """)
        XCTAssertEqual(
            try js("window.loreEditor.calloutKinds()") as? [String],
            ["abstract", "warning", "tip", "danger", "quote"])
    }

    /// An unrecognised type is a plain quote, not stray punctuation.
    @MainActor
    func test_anUnknownCalloutTypeStaysAPlainQuote() throws {
        try boot("> [!nonsense] Title\n> Body.\n\n")
        XCTAssertEqual(try js("window.loreEditor.calloutLineCount()") as? Int, 0)
    }

    // MARK: - E2T4, task checkboxes

    @MainActor
    func test_aTaskRendersARealCheckboxWithNoBulletBesideIt() throws {
        try boot("- [ ] open\n- [x] done\n\n")
        XCTAssertEqual(try js("window.loreEditor.checkboxStates()") as? [Bool], [false, true])
        // A task item shows its checkbox, not a bullet AND a checkbox.
        XCTAssertEqual(try js("document.querySelectorAll('.cm-lore-bullet').length") as? Int, 0)
        // The done one is struck through; the open one is not.
        XCTAssertEqual(try js("window.loreEditor.doneLineCount()") as? Int, 1)
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertFalse(shown.contains("[x]"), "the notation must be gone: \(shown)")
        XCTAssertFalse(shown.contains("[ ]"), "the notation must be gone: \(shown)")
    }

    /// The thing the native renderer could not do: the checkbox IS an input,
    /// and toggling it edits one character of the document.
    @MainActor
    func test_clickingACheckboxTogglesOneCharacterOfTheDocument() throws {
        try boot("- [ ] open\n\n")
        XCTAssertEqual(try js("window.loreEditor.clickCheckbox(0)") as? Bool, true)
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, "- [x] open\n\n")
        _ = try js("window.loreEditor.clickCheckbox(0)")
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, "- [ ] open\n\n")
    }

    /// A read-only session can never persist this, so it must not offer to.
    @MainActor
    func test_aReadOnlySessionOffersNoToggle() throws {
        try boot("- [ ] open\n\n")
        _ = try js("window.loreEditor.setTasksToggleable(false)")
        XCTAssertEqual(try js("window.loreEditor.checkboxDisabled()") as? [Bool], [true])
        _ = try js("window.loreEditor.clickCheckbox(0)")
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, "- [ ] open\n\n")
    }

    // MARK: - the invariant every E2 task shares

    @MainActor
    func test_renderingChangesNoByteOfTheDocument() throws {
        let source = """
            Tagged #project/ainkrad and #editor.

            - [ ] open
            - [x] done

            > [!warning] Careful
            > Body.

            A [link](https://x.test/p) and a #1234 reference.

            """
        try boot(source)
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
        for needle in ["#project/ainkrad", "open", "done", "Careful", "link"] {
            _ = try js(
                """
                window.loreEditor.selectAt(
                  window.loreEditor.text().indexOf(\(CM6EditorView.Coordinator.jsString(needle))))
                """)
        }
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
    }

    /// A markdown link's target is notation too. Without this, `[a
    /// link](https://x.test/p)` rendered as `a linkhttps://x.test/p` — the
    /// brackets hidden and the URL left against the label.
    @MainActor
    func test_aMarkdownLinksTargetIsNotOnScreen() throws {
        try boot("See [a link](https://x.test/p) here.\n\n")
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertTrue(shown.contains("a link"))
        XCTAssertFalse(shown.contains("x.test"), "the target must be hidden: \(shown)")
    }
}
