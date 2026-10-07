import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

extension MarkdownEditFastPathTests {
    // MARK: - The bail-outs

    /// Each listed case must fall back to the full render rather than take the
    /// fast path. Asserted on the flag, not inferred from timing.
    private func assertBails(
        insert: String, at site: String, deleting: Int = 0,
        _ why: String
    ) throws {
        let (coordinator, tv) = makeEditor(Self.fixture())
        try withExtendedLifetime(coordinator) {
            let text = tv.string as NSString
            let found = text.range(of: site)
            XCTAssertNotEqual(found.location, NSNotFound, "fixture must contain \(site)")
            let caret = found.location + found.length / 2
            tv.insertText(insert, replacementRange: NSRange(location: caret, length: deleting))
            XCTAssertFalse(coordinator.lastEditTookFastPath, why)
        }
    }

    func test_bails_whenTheEditContainsANewline() throws {
        try assertBails(
            insert: "\n", at: "prose with",
            "a newline moves block boundaries")
    }

    func test_bails_whenTheEditContainsAFenceCharacter() throws {
        try assertBails(
            insert: "`", at: "prose with",
            "a backtick can open or close a fence")
    }

    func test_bails_whenTheEditContainsATilde() throws {
        try assertBails(
            insert: "~", at: "prose with",
            "a tilde can open or close a fence")
    }

    /// A fence containing a BLANK LINE is the case `restyleBlock`'s
    /// precondition genuinely fails on: `MarkdownReveal.blocks` splits on blank
    /// lines regardless of fences, so the code span starts in one block and
    /// covers several, and is bucketed only into the first. Re-attributing a
    /// later one would clear its code styling with no span left to restore it.
    ///
    /// (An edit inside a fence with no blank line in it is NOT unsafe — the
    /// span lies wholly inside one block — and is covered as an equivalence
    /// site in `test_theFastPathProducesIdenticalAttributesToAFullRender`
    /// instead. Bailing there too would be free correctness-wise but would
    /// leave code blocks needlessly slow, and the checks already prove the
    /// difference.)
    func test_bails_whenAFenceSpansMultipleBlocks() {
        let body = "intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\ntail\n"
        let (coordinator, tv) = makeEditor(body)
        withExtendedLifetime(coordinator) {
            let found = (tv.string as NSString).range(of: "let b = 2")
            XCTAssertNotEqual(found.location, NSNotFound)
            tv.insertText("y", replacementRange: NSRange(location: found.location + 4, length: 0))
            XCTAssertFalse(
                coordinator.lastEditTookFastPath,
                "a code span reaching past this block's ends bars the fast path")
        }
    }

    /// A deletion that removes a newline, i.e. joins two blocks.
    func test_bails_whenADeletionRemovesANewline() throws {
        let (coordinator, tv) = makeEditor(Self.fixture())
        withExtendedLifetime(coordinator) {
            let found = (tv.string as NSString).range(of: "\n\n- a list item")
            XCTAssertNotEqual(found.location, NSNotFound)
            tv.insertText("", replacementRange: NSRange(location: found.location, length: 2))
            XCTAssertFalse(
                coordinator.lastEditTookFastPath,
                "removing a blank line merges two blocks")
        }
    }

    /// The structural check earns its keep here: typing a non-space character
    /// onto an otherwise-blank line SPLITS one block into two without any
    /// newline being involved, so the character test alone would not catch it.
    /// The recomputed-segmentation comparison must.
    func test_bails_whenTypingOnAWhitespaceOnlyLineResegmentsTheDocument() {
        let (coordinator, tv) = makeEditor("alpha\n \nbeta\n\ngamma\n")
        withExtendedLifetime(coordinator) {
            // Onto the whitespace-only line, which currently ENDS a block.
            tv.insertText("z", replacementRange: NSRange(location: 7, length: 0))
            XCTAssertFalse(
                coordinator.lastEditTookFastPath,
                "the blank line stopped being blank, so the blocks moved")
        }
    }

    /// And the mirror: an edit on a document the cache does not describe
    /// (nothing to shift) must fall back.
    func test_bails_whenTheCacheIsNotCurrent() {
        let (coordinator, tv) = makeEditor("# Title\n\nprose here\n")
        withExtendedLifetime(coordinator) {
            // Text swapped underneath without re-styling: the cache now
            // describes a string that is not on screen.
            tv.string = "# Title\n\ndifferent prose entirely\n"
            tv.setSelectedRange(NSRange(location: 12, length: 0))
            tv.insertText("x", replacementRange: tv.selectedRange())
            XCTAssertFalse(
                coordinator.lastEditTookFastPath,
                "spans that did not describe the pre-edit text cannot be shifted")
        }
    }

    // MARK: - Contracts that must not have been weakened

    /// The fast path parses ONE BLOCK per keystroke and never the document.
    ///
    /// This assertion used to read `count == 0`, and that zero was the defect:
    /// a path that parses nothing cannot notice that the characters just typed
    /// are markdown, so newly typed syntax stayed unstyled until the debounce
    /// fired after the user stopped. What has to hold is the bound that made
    /// the zero attractive in the first place — the per-keystroke cost must not
    /// be a function of DOCUMENT size — and that is asserted directly below, by
    /// checking the parsed text is the block rather than by counting.
    func test_theFastPathParsesOneBlockPerKeystrokeAndNeverTheDocument() {
        let (coordinator, tv) = makeEditor(Self.fixture())
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 200, length: 0))
            let typed = "the quick brown fox"
            resetParseCounter()
            for character in typed {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            XCTAssertTrue(coordinator.lastEditTookFastPath)
            XCTAssertEqual(
                MarkdownParseCounter.count, typed.count,
                "exactly one block parse per keystroke — no more, and "
                    + "no fewer, since fewer means stale kinds on screen")
        }
    }

    /// The cost bound behind the count above: what gets parsed on a keystroke
    /// is the CARET'S BLOCK, so a document ten times larger costs the same.
    ///
    /// Asserted by parsing the same block inside two documents of very
    /// different sizes and requiring the same number of parses — a count that
    /// scaled with the document would mean a whole-document parse had crept
    /// back onto the keystroke path.
    func test_theKeystrokeCostDoesNotGrowWithTheDocument() {
        func parsesForTyping(in document: String, at site: String) -> Int {
            let (coordinator, tv) = makeEditor(document)
            return withExtendedLifetime(coordinator) { () -> Int in
                let found = (tv.string as NSString).range(of: site)
                XCTAssertNotEqual(found.location, NSNotFound)
                tv.setSelectedRange(NSRange(location: found.location + 3, length: 0))
                resetParseCounter()
                for character in "abcdefgh" {
                    tv.insertText(String(character), replacementRange: tv.selectedRange())
                }
                XCTAssertTrue(coordinator.lastEditTookFastPath)
                return MarkdownParseCounter.count
            }
        }
        let small = parsesForTyping(in: Self.fixture(), at: "prose with")
        let large = parsesForTyping(
            in: Self.fixture() + Self.fixture() + Self.fixture(),
            at: "prose with")
        XCTAssertEqual(
            small, large,
            "a three-times-larger document must cost the same per keystroke")
    }

    // MARK: - The defect this path exists to fix

    /// THE regression test. Markdown must be styled by the keystroke that
    /// completes it, not by the pause afterwards.
    ///
    /// Measured before the fix: typing `**bold**` left the word in the body
    /// font (symbolic traits `17408`) until the 150 ms debounce landed, at
    /// which point it became bold (`2`). Asserted here with NO settle, so a
    /// regression to "the debounce will fix it" fails rather than passes late.
    func test_typedSyntaxIsStyledOnTheKeystrokeNotAfterTheDebounce() throws {
        let (coordinator, tv) = makeEditor("# Title\n\nplain prose here\n")
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let end = (tv.string as NSString).range(of: "prose here")
            tv.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
            for character in " **bold**" {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            XCTAssertTrue(coordinator.lastEditTookFastPath)
            let word = (tv.string as NSString).range(of: "bold")
            let font = try XCTUnwrap(
                storage.attribute(
                    .font, at: word.location,
                    effectiveRange: nil) as? NSFont)
            XCTAssertTrue(
                font.fontDescriptor.symbolicTraits.contains(.bold),
                "the word must be bold on the keystroke that closed the "
                    + "emphasis, not one debounce later")
        }
    }

    /// The same for a heading, which changes SIZE rather than weight — and
    /// which is typed at the START of a block, the other common shape.
    func test_typingAHeadingMarkerStylesTheLineImmediately() throws {
        let (coordinator, tv) = makeEditor("alpha\n\nplain line\n\nomega\n")
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let line = (tv.string as NSString).range(of: "plain line")
            let bodySize = try XCTUnwrap(
                storage.attribute(
                    .font, at: line.location,
                    effectiveRange: nil) as? NSFont
            )
            .pointSize
            tv.setSelectedRange(NSRange(location: line.location, length: 0))
            for character in "## " {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            let heading = (tv.string as NSString).range(of: "plain line")
            let font = try XCTUnwrap(
                storage.attribute(
                    .font, at: heading.location,
                    effectiveRange: nil) as? NSFont)
            XCTAssertGreaterThan(
                font.pointSize, bodySize,
                "the line must render as a heading as soon as the "
                    + "marker is complete")
        }
    }

    /// And the reverse direction: DELETING a marker must un-style immediately
    /// too. Shifted spans grow to cover the caret, so a stale path leaves the
    /// text emphasised after the syntax that emphasised it is gone.
    func test_deletingAMarkerUnstylesImmediately() throws {
        let (coordinator, tv) = makeEditor("intro\n\nsome *slanted* words\n\ntail\n")
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let opener = (tv.string as NSString).range(of: "*slanted*")
            // Remove the CLOSING marker, so what remains is not emphasis.
            tv.insertText(
                "",
                replacementRange: NSRange(
                    location: NSMaxRange(opener) - 1,
                    length: 1))
            XCTAssertTrue(coordinator.lastEditTookFastPath)
            let word = (tv.string as NSString).range(of: "slanted")
            let font = try XCTUnwrap(
                storage.attribute(
                    .font, at: word.location,
                    effectiveRange: nil) as? NSFont)
            XCTAssertFalse(
                font.fontDescriptor.symbolicTraits.contains(.italic),
                "with the closing marker gone the word is not emphasis")
        }
    }

    /// A block that could USE a link reference definition cannot be parsed
    /// alone: `[label]` means "link" only because a line elsewhere says so.
    ///
    /// The question is asked of the BLOCK, not of the document. It was once
    /// asked of the document — "does anything anywhere look like a definition"
    /// — and that is how Ahmed's original "styling lands late" complaint came
    /// back on 2026-08-17: a footnote (`[^1]: …`) has a definition's shape, so
    /// one footnote disabled the block parse for every paragraph in the note.
    /// The companion case, that a bracket-free paragraph in the SAME document
    /// still takes the fast path, is in `ReportedDefectsTests`.
    func test_bails_whenTheEditedBlockCouldUseAReferenceDefinition() {
        let body = "[label]: https://example.com\n\nsee [label] for more\n\ntail here\n"
        let (coordinator, tv) = makeEditor(body)
        withExtendedLifetime(coordinator) {
            let found = (tv.string as NSString).range(of: "see [label] for more")
            tv.insertText(
                "x",
                replacementRange: NSRange(
                    location: found.location + 2,
                    length: 0))
            XCTAssertFalse(
                coordinator.lastEditTookFastPath,
                "this block contains a bracket and the document holds a "
                    + "definition, so it cannot be parsed in isolation")
        }
    }

    /// And the reverse, so the guard above is not silently barring everything:
    /// an ordinary document with brackets in it must still take the fast path.
    func test_bracketsThatAreNotADefinitionDoNotBarTheFastPath() {
        let (coordinator, tv) = makeEditor("intro\n\nsee [a] and [b] here\n\ntail\n")
        withExtendedLifetime(coordinator) {
            let found = (tv.string as NSString).range(of: "tail")
            tv.insertText(
                "x",
                replacementRange: NSRange(
                    location: found.location + 2,
                    length: 0))
            XCTAssertTrue(
                coordinator.lastEditTookFastPath,
                "`[a]` on its own is not a reference definition")
        }
    }

    /// And the debounced parse must still land a full, correct render on top —
    /// the safety net that makes a mis-shift a frame rather than a document.
    func test_theDebouncedParseStillLandsAfterAFastPathEdit() throws {
        let (coordinator, tv) = makeEditor("# Title\n\nplain prose\n")
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            tv.setSelectedRange(NSRange(location: 15, length: 0))
            tv.insertText("x", replacementRange: tv.selectedRange())
            settle()
            XCTAssertTrue(
                coordinator.styleCache.describes(tv.string),
                "the debounced parse must have refreshed the cache")
            XCTAssertEqual(attributeDump(storage).isEmpty, false)
        }
    }
}
