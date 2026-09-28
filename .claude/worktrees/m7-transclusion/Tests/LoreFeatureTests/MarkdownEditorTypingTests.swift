import XCTest
import AppKit
@testable import LoreFeature

/// The AppKit half of the typing affordances: applying a pure `EditResult` to a
/// live text view, and the `doCommandBy` routing that decides when to.
@MainActor
final class MarkdownEditorTypingTests: XCTestCase {

    /// A detached `NSTextView` has no window, and so no undo manager of its
    /// own — the real editor gets one from its window. This supplies one the
    /// same way AppKit would, so the undo assertions test the real mechanism.
    @MainActor private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    private var hosts: [UndoHost] = []

    private func textView(_ string: String, caret: Int, length: Int = 0) -> NSTextView {
        let tv = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        let host = UndoHost()
        hosts.append(host)
        tv.delegate = host
        tv.string = string
        tv.allowsUndo = true
        tv.setSelectedRange(NSRange(location: caret, length: length))
        return tv
    }

    /// ONE undo step per affordance. Multi-step undo on auto-continue is how
    /// these features become infuriating: a user presses Cmd-Z expecting the
    /// bullet gone and gets half of it.
    func test_applyingAnEditResultIsASingleUndoStep() throws {
        let tv = textView("- first", caret: 7)
        let result = try XCTUnwrap(
            MarkdownEditing.continueList(text: tv.string, selection: tv.selectedRange()))
        _ = MarkdownEditorTyping.apply(result, to: tv)
        XCTAssertEqual(tv.string, "- first\n- ")

        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "- first", "one undo must restore the original exactly")
    }

    func test_applyMovesTheCaretToTheResultSelection() throws {
        let tv = textView("- first", caret: 7)
        let result = try XCTUnwrap(
            MarkdownEditing.continueList(text: tv.string, selection: tv.selectedRange()))
        XCTAssertTrue(MarkdownEditorTyping.apply(result, to: tv))
        XCTAssertEqual(tv.selectedRange(), result.selection)
    }

    /// Outdenting at column zero returns the text UNCHANGED. Applying that must
    /// not push a do-nothing entry onto the undo stack — the next Cmd-Z would
    /// then appear to do nothing at all.
    func test_applyingAnUnchangedResultRegistersNoUndoStep() throws {
        let tv = textView("- first", caret: 7)
        tv.undoManager?.removeAllActions()
        // Driven through the REAL transform, so this also pins that outdenting
        // at column zero still returns the text unchanged rather than nil.
        let unchanged = try XCTUnwrap(
            MarkdownEditing.indent(text: tv.string, selection: tv.selectedRange(), by: -1))
        XCTAssertEqual(unchanged.text, tv.string)
        XCTAssertTrue(MarkdownEditorTyping.apply(unchanged, to: tv))
        XCTAssertEqual(tv.string, "- first")
        XCTAssertEqual(tv.selectedRange(), unchanged.selection)
        XCTAssertFalse(tv.undoManager?.canUndo ?? false)
    }

    // MARK: - The minimal edit (Task 11)

    /// `changedRange` is the whole safety argument for narrowing the edit: it
    /// must reconstruct the new text EXACTLY. Asserted as the round trip
    /// rather than as specific offsets, because the offsets are an
    /// implementation detail and the round trip is the contract.
    private func assertRoundTrip(_ old: String, _ new: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let oldNS = old as NSString
        let (range, replacement) = MarkdownEditorTyping.changedRange(from: oldNS,
                                                                    to: new as NSString)
        let rebuilt = oldNS.replacingCharacters(in: range, with: replacement)
        XCTAssertEqual(rebuilt, new, "round trip must be exact", file: file, line: line)
        XCTAssertLessThanOrEqual(NSMaxRange(range), oldNS.length,
                                 "the range must be inside the old string",
                                 file: file, line: line)
    }

    func test_changedRangeRoundTripsForEveryEditShape() {
        assertRoundTrip("- first", "- first\n- ")            // insertion at the end
        assertRoundTrip("- first\n- second", "- first\n- \n- second")  // in the middle
        assertRoundTrip("    - a", "- a")                    // deletion at the start
        assertRoundTrip("abc", "abc")                        // no change at all
        assertRoundTrip("", "x")                             // from empty
        assertRoundTrip("x", "")                             // to empty
        assertRoundTrip("aaa", "aaaa")                       // ambiguous repetition
        assertRoundTrip("- a\n- b\n- c", "  - a\n  - b\n  - c")  // multi-line indent
    }

    /// A surrogate pair must never be split: the prefix scan can legitimately
    /// stop between an emoji's two UTF-16 units, and handing AppKit that range
    /// replaces half a character.
    func test_changedRangeNeverSplitsACharacter() {
        let old = "- 👍👍 tail"
        let new = "- 👍👍 tail\n- "
        assertRoundTrip(old, new)
        assertRoundTrip("a👍b", "a👍👍b")
        assertRoundTrip("e\u{0301}x", "e\u{0301}yx")   // combining acute

        // And the range's own bounds sit on composed-sequence boundaries.
        let ns = "a👍b" as NSString
        let (range, _) = MarkdownEditorTyping.changedRange(from: ns, to: "a👍👍b" as NSString)
        XCTAssertEqual(ns.rangeOfComposedCharacterSequence(at: range.location).location,
                       range.location)
    }

    /// The point of the whole exercise: pressing Enter in a long list must not
    /// announce an edit covering the document.
    func test_theAnnouncedEditIsProportionalToTheChangeNotTheDocument() {
        let long = String(repeating: "- item\n", count: 1_000)
        let (range, replacement) =
            MarkdownEditorTyping.changedRange(from: long as NSString,
                                              to: ("- item\n- \n" + String(repeating: "- item\n",
                                                                          count: 999)) as NSString)
        XCTAssertLessThan(range.length, 16)
        XCTAssertLessThan(replacement.count, 16)
    }

    // MARK: - doCommandBy routing

    func test_enterInAListIsHandled() {
        let tv = textView("- first", caret: 7)
        XCTAssertTrue(MarkdownEditorTyping.handle(#selector(NSResponder.insertNewline(_:)), in: tv))
        XCTAssertEqual(tv.string, "- first\n- ")
    }

    /// nil from the transform means "not a list" — AppKit must insert the
    /// newline itself, so the handler has to decline rather than swallow it.
    func test_enterOutsideAListIsNotHandled() {
        let tv = textView("plain", caret: 5)
        XCTAssertFalse(MarkdownEditorTyping.handle(#selector(NSResponder.insertNewline(_:)), in: tv))
        XCTAssertEqual(tv.string, "plain")
    }

    func test_tabIndentsAListItemAndBacktabOutdentsIt() {
        let tv = textView("- first", caret: 7)
        XCTAssertTrue(MarkdownEditorTyping.handle(#selector(NSResponder.insertTab(_:)), in: tv))
        XCTAssertEqual(tv.string, "  - first")
        XCTAssertTrue(MarkdownEditorTyping.handle(#selector(NSResponder.insertBacktab(_:)), in: tv))
        XCTAssertEqual(tv.string, "- first")
    }

    func test_tabOutsideAListIsNotHandled() {
        let tv = textView("plain", caret: 5)
        XCTAssertFalse(MarkdownEditorTyping.handle(#selector(NSResponder.insertTab(_:)), in: tv))
        XCTAssertFalse(MarkdownEditorTyping.handle(#selector(NSResponder.insertBacktab(_:)), in: tv))
        XCTAssertEqual(tv.string, "plain")
    }

    func test_unrelatedSelectorsAreNotHandled() {
        let tv = textView("- first", caret: 7)
        XCTAssertFalse(MarkdownEditorTyping.handle(#selector(NSResponder.moveDown(_:)), in: tv))
    }

    // MARK: - Typing and Cmd-B

    func test_typingAnOpenerAutoPairsAsOneUndoStep() {
        let tv = textView("", caret: 0)
        XCTAssertTrue(MarkdownEditorTyping.typed("[", in: tv))
        XCTAssertEqual(tv.string, "[]")
        XCTAssertEqual(tv.selectedRange().location, 1)
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "")
    }

    func test_typingAnOrdinaryCharacterIsLeftToAppKit() {
        let tv = textView("", caret: 0)
        XCTAssertFalse(MarkdownEditorTyping.typed("z", in: tv))
        XCTAssertEqual(tv.string, "")
    }

    /// Multi-character input — a paste, or an IME committing a phrase — is not
    /// a pair opener and must never be reinterpreted as one.
    func test_multiCharacterInputIsLeftToAppKit() {
        let tv = textView("", caret: 0)
        XCTAssertFalse(MarkdownEditorTyping.typed("[[", in: tv))
        XCTAssertEqual(tv.string, "")
    }

    // MARK: - The live view and the coordinator

    /// The GUI path, driven offscreen: the real `LinkTextView` override, not
    /// just the helper it calls.
    func test_theLiveTextViewAutoPairsATypedBracket() {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = ""
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("[", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(tv.string, "[]")
        tv.insertText("z", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "[z]", "ordinary characters still type normally")
    }

    /// An IME committing a single pair character mid-composition must not be
    /// auto-paired: `typed` rebuilds the string around the SELECTION and would
    /// replace the marked range without unmarking it.
    func test_typedTextIsNotAutoPairedWhileComposing() {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = ""
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tv.hasMarkedText())
        tv.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(tv.string.contains("[]"), "composition was auto-paired: \(tv.string)")
    }

    /// Autocorrect, dictation and text substitution target a range that is not
    /// the selection. Pairing there would insert the pair in the wrong place.
    func test_anExplicitReplacementRangeIsLeftToAppKit() {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        tv.insertText("\"", replacementRange: NSRange(location: 0, length: 5))
        XCTAssertEqual(tv.string, "\" world", "the replacement range must be honoured, unpaired")
    }

    /// The redundant spelling of ordinary typing — range EQUAL to the selection
    /// — still pairs, or auto-pairing would silently stop working wherever
    /// AppKit chooses to name the range.
    func test_aReplacementRangeEqualToTheSelectionStillPairs() {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = ""
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("[", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(tv.string, "[]")
    }

    /// Enter continues a list only when the `[[` completion panel is closed —
    /// while it is open, Enter belongs to the panel.
    func test_coordinatorRoutesEnterToListContinuationWhenNoPanelIsShowing() {
        let coordinator = MarkdownEditor.Coordinator(text: .constant("- first"),
                                                     tokens: TestTokens.make())
        let tv = textView("- first", caret: 7)
        XCTAssertFalse(coordinator.completionPanel.isVisible)
        XCTAssertTrue(coordinator.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(tv.string, "- first\n- ")
    }

    func test_toggleBoldWrapsThenUnwrapsTheSameSelection() {
        let tv = textView("make bold now", caret: 5, length: 4)
        MarkdownEditorTyping.toggleWrap(in: tv, with: "**")
        XCTAssertEqual(tv.string, "make **bold** now")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 7, length: 4))
        MarkdownEditorTyping.toggleWrap(in: tv, with: "**")
        XCTAssertEqual(tv.string, "make bold now", "a second Cmd-B must unwrap, not double-wrap")
    }
}
