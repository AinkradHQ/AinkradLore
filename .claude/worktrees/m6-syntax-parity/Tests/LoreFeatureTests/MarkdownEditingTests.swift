import XCTest
@testable import LoreFeature

/// Typing affordances as PURE transforms, so every rule is asserted without an
/// AppKit text view.
final class MarkdownEditingTests: XCTestCase {

    private func enter(_ text: String, at location: Int) -> EditResult? {
        MarkdownEditing.continueList(text: text, selection: NSRange(location: location, length: 0))
    }

    func test_enterContinuesABulletList() {
        let r = enter("- first", at: 7)
        XCTAssertEqual(r?.text, "- first\n- ")
        XCTAssertEqual(r?.selection.location, 10)
    }

    func test_enterIncrementsAnOrderedList() {
        XCTAssertEqual(enter("1. first", at: 8)?.text, "1. first\n2. ")
    }

    func test_enterContinuesATaskAsUnchecked() {
        // A continued task starts unchecked — copying `[x]` would assert the
        // new item is already done.
        XCTAssertEqual(enter("- [x] done", at: 10)?.text, "- [x] done\n- [ ] ")
    }

    func test_enterPreservesIndentation() {
        XCTAssertEqual(enter("  - nested", at: 10)?.text, "  - nested\n  - ")
    }

    /// The rule that makes auto-continue a help rather than a nuisance:
    /// Enter on an EMPTY item ends the list instead of adding another.
    func test_enterOnAnEmptyItemEndsTheList() {
        let r = enter("- first\n- ", at: 10)
        XCTAssertEqual(r?.text, "- first\n")
        XCTAssertEqual(r?.selection.location, 8)
    }

    /// Not a list: return nil so AppKit inserts a plain newline and undo,
    /// autocorrect and everything else behave normally.
    func test_enterInProseIsNotHandled() {
        XCTAssertNil(enter("just prose", at: 10))
    }

    /// A CRLF document must continue correctly — "\r\n" is two UTF-16 units.
    func test_enterContinuesAListInACRLFDocument() {
        XCTAssertEqual(enter("- a\r\n- b", at: 8)?.text, "- a\r\n- b\n- ")
    }
}

extension MarkdownEditingTests {
    private func indent(_ text: String, at location: Int, by delta: Int) -> EditResult? {
        MarkdownEditing.indent(text: text,
                               selection: NSRange(location: location, length: 0), by: delta)
    }

    func test_tabIndentsTheItemUnderTheCaret() {
        XCTAssertEqual(indent("- item", at: 3, by: 1)?.text, "  - item")
    }

    func test_shiftTabOutdents() {
        XCTAssertEqual(indent("  - item", at: 5, by: -1)?.text, "- item")
    }

    func test_outdentAtColumnZeroIsANoOpRatherThanADeletion() {
        XCTAssertEqual(indent("- item", at: 3, by: -1)?.text, "- item")
    }

    /// Renumbering: an ordered item that moves must not keep a number from its
    /// old level.
    func test_indentingAnOrderedItemRestartsItsNumbering() {
        XCTAssertEqual(indent("1. a\n2. b", at: 7, by: 1)?.text, "1. a\n  1. b")
    }

    /// Tab outside a list must not be swallowed — it should insert a tab.
    func test_tabInProseIsNotHandled() {
        XCTAssertNil(indent("prose", at: 3, by: 1))
    }
}

extension MarkdownEditingTests {

    func test_cmdBWrapsTheSelection() {
        let r = MarkdownEditing.toggleWrap(text: "make bold now",
                                           selection: NSRange(location: 5, length: 4),
                                           with: "**")
        XCTAssertEqual(r.text, "make **bold** now")
    }

    /// The same keystroke unwraps — a toggle, not an "add more asterisks".
    /// Selection sits strictly INSIDE the delimiters: "make **|bold|** now".
    func test_cmdBOnAlreadyBoldTextUnwrapsIt() {
        let r = MarkdownEditing.toggleWrap(text: "make **bold** now",
                                           selection: NSRange(location: 7, length: 4),
                                           with: "**")
        XCTAssertEqual(r.text, "make bold now")
    }

    /// Selection INCLUDES the delimiters: "make |**bold**| now" — the shape a
    /// drag-select or triple-click across a bolded span produces. This must
    /// also unwrap, not re-wrap into "****bold****".
    func test_cmdBOnASelectionThatIncludesTheDelimitersUnwrapsIt() {
        let r = MarkdownEditing.toggleWrap(text: "make **bold** now",
                                           selection: NSRange(location: 5, length: 8),
                                           with: "**")
        XCTAssertEqual(r.text, "make bold now")
        XCTAssertEqual(r.selection, NSRange(location: 5, length: 4))
    }

    func test_cmdBWithNoSelectionInsertsAnEmptyPairWithTheCaretInside() {
        let r = MarkdownEditing.toggleWrap(text: "ab", selection: NSRange(location: 1, length: 0),
                                           with: "**")
        XCTAssertEqual(r.text, "a****b")
        XCTAssertEqual(r.selection.location, 3)
    }

    /// Losing a selection to a stray bracket is a small data loss, so
    /// auto-pair SURROUNDS a selection rather than replacing it.
    func test_autoPairSurroundsASelectionInsteadOfReplacingIt() {
        let r = MarkdownEditing.autoPair(text: "keep me",
                                         selection: NSRange(location: 5, length: 2), typing: "[")
        XCTAssertEqual(r?.text, "keep [me]")
    }

    func test_autoPairInsertsTheClosingCharacter() {
        let r = MarkdownEditing.autoPair(text: "", selection: NSRange(location: 0, length: 0),
                                         typing: "[")
        XCTAssertEqual(r?.text, "[]")
        XCTAssertEqual(r?.selection.location, 1)
    }

    /// Typing the closing character when it is already there moves past it
    /// rather than doubling it.
    func test_typingAClosingCharacterOverATypedOneSkipsIt() {
        let r = MarkdownEditing.autoPair(text: "[]", selection: NSRange(location: 1, length: 0),
                                         typing: "]")
        XCTAssertEqual(r?.text, "[]")
        XCTAssertEqual(r?.selection.location, 2)
    }

    // MARK: - Auto-pairing COMPOSED with `[[` completion

    /// FINDING 1. Both halves passed their own tests and the composition was
    /// still broken: `[` auto-pairs, so typing `[[` leaves `[[]]` with the caret
    /// in the middle, and an insertion that appends its own `]]` produced
    /// `[[Target]]]]`. This test walks the real path — type, type, complete.
    func test_typingTwoBracketsThenAcceptingACompletionClosesTheLinkExactlyOnce() throws {
        var text = ""
        var caret = NSRange(location: 0, length: 0)
        for _ in 0..<2 {
            let step = try XCTUnwrap(MarkdownEditing.autoPair(text: text, selection: caret,
                                                              typing: "["))
            text = step.text
            caret = step.selection
        }
        XCTAssertEqual(text, "[[]]")
        XCTAssertEqual(caret.location, 2)

        // The panel opens on an empty prefix — this is what M1 detects.
        let prefix = try XCTUnwrap(LinkCompletionContext.activePrefix(in: text,
                                                                      caret: caret.location))
        XCTAssertEqual(prefix, "")

        let result = MarkdownEditing.linkInsertion(text: text, caret: caret.location,
                                                   prefixLength: prefix.utf16.count,
                                                   target: "Target")
        XCTAssertEqual(result.text, "[[Target]]", "the auto-paired closer must be absorbed")
        XCTAssertEqual(result.selection.location, 10, "the caret continues in prose")
    }

    /// The same acceptance where the brackets were NOT auto-paired — a pasted
    /// or hand-typed `[[Des` with nothing after it. The closer is added, not
    /// absorbed.
    func test_acceptingACompletionWithNoExistingCloserStillClosesTheLink() {
        let result = MarkdownEditing.linkInsertion(text: "see [[Des", caret: 9,
                                                   prefixLength: 3, target: "Design")
        XCTAssertEqual(result.text, "see [[Design]]")
        XCTAssertEqual(result.selection.location, 14)
    }

    /// Re-completing INSIDE an already-closed link must not leave the old `]]`
    /// stranded after the new one.
    func test_recompletingInsideAClosedLinkKeepsOnePairOfBrackets() {
        let result = MarkdownEditing.linkInsertion(text: "[[Des]] tail", caret: 5,
                                                   prefixLength: 3, target: "Design")
        XCTAssertEqual(result.text, "[[Design]] tail")
    }

    /// Only a real closer is absorbed. A lone `]` after the caret is one
    /// character of prose and half of it must not be eaten as the second
    /// bracket of a pair that is not there.
    func test_absorptionTakesAtMostTheTwoBracketsItNeeds() {
        let result = MarkdownEditing.linkInsertion(text: "[[Des]]]] more", caret: 5,
                                                   prefixLength: 3, target: "Design")
        XCTAssertEqual(result.text, "[[Design]]]] more",
                       "at most two brackets belong to this link")
    }

    /// Escaping the panel leaves the auto-paired brackets exactly as typing
    /// them produced — the user carries on inside a well-formed link.
    func test_dismissingThePanelLeavesAWellFormedEmptyLink() {
        // After the FIRST `[`, the text is already `[]` with the caret inside.
        let opened = MarkdownEditing.autoPair(text: "[]", selection: NSRange(location: 1, length: 0),
                                              typing: "[")
        XCTAssertEqual(opened?.text, "[[]]")
        XCTAssertEqual(opened?.selection.location, 2)
    }

    /// And a lone `[` in prose still pairs, which is the affordance Task 9 was
    /// for. Nothing about the fix reaches it.
    func test_aLoneBracketInProseStillPairs() {
        let r = MarkdownEditing.autoPair(text: "a b", selection: NSRange(location: 2, length: 0),
                                         typing: "[")
        XCTAssertEqual(r?.text, "a []b")
        XCTAssertEqual(r?.selection.location, 3)
    }

    func test_autoPairIgnoresUnpairedCharacters() {
        XCTAssertNil(MarkdownEditing.autoPair(text: "", selection: NSRange(location: 0, length: 0),
                                              typing: "z"))
    }
}
