import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Task 10, Part 1: the single-block edit path must be INVISIBLE.
///
/// Speed is the point of `renderStylesForEdit`, but speed is not what can go
/// wrong with it. What can go wrong is showing the user attributes that differ
/// from what a full render would have produced — so the test that matters here
/// is not a timing but an equivalence: for a realistic edit, the storage after
/// the fast path must be byte-identical to the storage after `renderStyles()`.
///
/// Both are driven on two editors holding the same text, edited identically,
/// so the comparison is between two real renders of the same document rather
/// than between a render and a hand-written expectation.
@MainActor
final class MarkdownEditFastPathTests: XCTestCase {

    /// Windows are retained for the length of each test — a released window
    /// takes its first responder with it, and the whole point here is that the
    /// text view stays focused.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// A REAL window, and the text view made first responder.
    ///
    /// The benchmarks use a detached `NSTextView`, and it cannot be used here:
    /// a text view with no window posts `textDidBeginEditing`/
    /// `textDidEndEditing` around EVERY `insertText`, and `textDidEndEditing`
    /// re-renders the whole document with `forcedFocus: false`, collapsing
    /// every marker. That lands AFTER the edit path has run, so it silently
    /// overwrites whatever is being compared — the first version of this test
    /// "failed" on exactly that and the fast path was not at fault. With a
    /// window and real first-responder state, editing begins and ends once,
    /// which is also what happens in the app.
    private func makeEditor(_ text: String) -> (MarkdownEditor.Coordinator, NSTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        XCTAssertTrue(window.firstResponder === tv, "the editor must actually be focused")
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        settle()
        return (coordinator, tv)
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        let landed = expectation(description: "off-actor parse landed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { landed.fulfill() }
        wait(for: [landed], timeout: seconds + 2)
    }

    /// Every attribute run in the storage, rendered to comparable VALUES.
    ///
    /// Deliberately not `String(describing:)` of the attribute dictionary:
    /// `NSFont`'s description embeds the font object's ADDRESS, so two editors
    /// rendering identical text would never compare equal and the test would
    /// fail for a reason that has nothing to do with what the user sees. Each
    /// attribute the renderer actually writes is therefore projected onto the
    /// properties that determine appearance, and any attribute NOT projected
    /// here fails the `unknown` case loudly rather than being silently ignored
    /// — a new attribute must be added to this dump, not slip past it.
    private func attributeDump(_ storage: NSTextStorage) -> [String] {
        var out: [String] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) {
            attributes, range, _ in
            let rendered = attributes.map { key, value -> String in
                switch key {
                case .font:
                    guard let font = value as? NSFont else { return "font=?" }
                    return "font=\(font.fontName)@\(font.pointSize)"
                        + "/\(font.fontDescriptor.symbolicTraits.rawValue)"
                case .foregroundColor, .backgroundColor:
                    guard let color = (value as? NSColor)?
                        .usingColorSpace(.sRGB) else { return "\(key.rawValue)=?" }
                    return "\(key.rawValue)=\(color.redComponent),\(color.greenComponent),"
                        + "\(color.blueComponent),\(color.alphaComponent)"
                case .paragraphStyle:
                    guard let style = value as? NSParagraphStyle else { return "para=?" }
                    return "para=\(style.firstLineHeadIndent)/\(style.headIndent)"
                        + "/\(style.lineHeightMultiple)/\(style.paragraphSpacing)"
                        + "/\(style.paragraphSpacingBefore)/\(style.alignment.rawValue)"
                case .kern, .underlineStyle, .baselineOffset:
                    return "\(key.rawValue)=\(value)"
                default:
                    return "UNPROJECTED-\(key.rawValue)=\(value)"
                }
            }.sorted().joined(separator: ",")
            out.append("\(range.location)..<\(NSMaxRange(range)) \(rendered)")
        }
        return out
    }

    /// A document with everything the renderer treats specially, and enough
    /// blocks that a whole-document render and a one-block one could not
    /// possibly coincide by accident.
    private static func fixture() -> String {
        (0..<40).map { index in
            """
            ## Section \(index)

            Some **bold** and _italic_ prose with a [[Link \(index)]] and \
            `inline code` in it.

            - a list item with [[Another \(index)]]
            - a second item

            > a quoted line

            ```swift
            let x\(index) = \(index)
            ```

            """
        }.joined()
    }

    /// Applies `edit` to a fresh editor via the real delegate path, then
    /// returns its attribute dump — once with the fast path allowed to run,
    /// once forced through the full render, so the two can be compared.
    private func dumpAfterEdit(insert: String, at location: Int,
                               deleting length: Int,
                               forceFullRender: Bool) throws -> (dump: [String], usedFast: Bool) {
        let (coordinator, tv) = makeEditor(Self.fixture())
        return try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            tv.setSelectedRange(NSRange(location: location, length: length))
            let before = coordinator.revealIndexBuilds
            tv.insertText(insert, replacementRange: NSRange(location: location, length: length))
            // One `renderStyles` either way; what differs is whether it was
            // the whole document or one block.
            let usedFast = coordinator.lastEditTookFastPath
            if forceFullRender { coordinator.renderStyles() }
            XCTAssertGreaterThan(coordinator.revealIndexBuilds, before,
                                 "the edit must have re-rendered something")
            return (attributeDump(storage), usedFast)
        }
    }

    /// Compares two dumps and reports the FIRST difference rather than both
    /// dumps in full — a 40-section fixture produces hundreds of runs, and an
    /// `XCTAssertEqual` on the arrays prints all of them truncated, which says
    /// nothing about what actually differs.
    private func assertSameAttributes(_ fast: [String], _ full: [String],
                                      site: String, file: StaticString = #filePath,
                                      line: UInt = #line) {
        for index in 0..<min(fast.count, full.count) where fast[index] != full[index] {
            XCTFail("""
                typing inside "\(site)" produced different attributes at run \(index):
                  fast: \(fast[index])
                  full: \(full[index])
                """, file: file, line: line)
            return
        }
        XCTAssertEqual(fast.count, full.count,
                       "typing inside \"\(site)\" produced a different number of "
                       + "attribute runs", file: file, line: line)
    }

    /// THE test. A realistic single-character edit inside a block must leave
    /// the storage byte-identical to what a full render produces.
    func test_theFastPathProducesIdenticalAttributesToAFullRender() throws {
        let text = Self.fixture() as NSString
        // Deliberately varied landing sites, found in the fixture rather than
        // guessed at: inside prose, inside a bold run, inside a wikilink,
        // inside a list item, inside a heading, inside a quote.
        let sites = ["prose with", "**bold**", "[[Link 5]]", "- a second item",
                     "## Section 7", "> a quoted line", "let x3 = 3"]
        for site in sites {
            let found = text.range(of: site)
            XCTAssertNotEqual(found.location, NSNotFound, "fixture must contain \(site)")
            let caret = found.location + found.length / 2

            let fast = try dumpAfterEdit(insert: "x", at: caret, deleting: 0,
                                         forceFullRender: false)
            let full = try dumpAfterEdit(insert: "x", at: caret, deleting: 0,
                                         forceFullRender: true)
            XCTAssertTrue(fast.usedFast,
                          "typing inside \"\(site)\" must take the fast path")
            assertSameAttributes(fast.dump, full.dump, site: site)
        }
    }

    /// The same, for a DELETION — the direction that can collapse a span, and
    /// so the one `shift`'s `compactMap` can drop entries in.
    func test_aDeletionAlsoProducesIdenticalAttributes() throws {
        let text = Self.fixture() as NSString
        let found = text.range(of: "prose with")
        XCTAssertNotEqual(found.location, NSNotFound)

        let fast = try dumpAfterEdit(insert: "", at: found.location, deleting: 5,
                                     forceFullRender: false)
        let full = try dumpAfterEdit(insert: "", at: found.location, deleting: 5,
                                     forceFullRender: true)
        assertSameAttributes(fast.dump, full.dump, site: "a deletion")
    }

    /// The `toRestyle` symmetric-difference branch, which every other
    /// equivalence test above leaves unexecuted.
    ///
    /// Typing mid-block leaves the revealed range unchanged, so `toRestyle`
    /// collapses to `{block}` and the set arithmetic never does anything. It is
    /// reachable, though: a caret resting exactly on a block's `lowerBound`
    /// belongs to BOTH adjacent blocks — `revealedBlockIndices` widens one step
    /// at a boundary — and inserting a character there moves the caret off the
    /// boundary, so the revealed range narrows from two blocks to one and the
    /// block that just LOST reveal has to be re-collapsed.
    ///
    /// This is the exact area the one real defect in this task came from
    /// (reveal read against the pre-edit block list), so it is asserted rather
    /// than argued — and asserted the way that matters, by comparing the whole
    /// document's attributes against a full render, not by timing it.
    func test_anEditOnABlockBoundaryRestylesTheBlockThatLostReveal() throws {
        // A block that starts with prose (safe to type in) and is not the
        // first, since the widening rule needs a predecessor.
        let text = Self.fixture()
        let (probe, _) = makeEditor(text)
        let boundary = try XCTUnwrap(
            probe.revealIndex.blocks.dropFirst().first(where: { block in
                (text as NSString).substring(with: NSRange(location: block.lowerBound,
                                                           length: min(5, block.count)))
                    .hasPrefix("Some ")
            })?.lowerBound,
            "the fixture must contain a prose block that is not the first")

        // FAST: place the caret exactly on the boundary, then type.
        //
        // This used to assert that the caret revealed BOTH adjacent blocks and
        // then narrowed to one. That widening rule belonged to block-scoped
        // reveal and is gone: the unit is now the LINE, and a caret at a block
        // boundary sits on exactly one of them. What the test is really for
        // survives unchanged — an edit at a boundary must leave the same
        // attributes as a full render — and the branch it exercises is still
        // exercised, because the revealed range moves across the edit and the
        // block it left has to be re-collapsed.
        let (fast, fastView) = makeEditor(text)
        let fastStorage = try XCTUnwrap(fastView.textStorage)
        fastView.setSelectedRange(NSRange(location: boundary, length: 0))
        let was = fast.revealedRange
        XCTAssertNotNil(was, "a focused editor with a caret must reveal something")
        fastView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        XCTAssertTrue(fast.lastEditTookFastPath)
        XCTAssertNotEqual(fast.revealedRange, was,
                          "typing at a boundary must move the revealed range")

        // FULL: the same edit, then a whole-document render on top.
        let (full, fullView) = makeEditor(text)
        let fullStorage = try XCTUnwrap(fullView.textStorage)
        fullView.setSelectedRange(NSRange(location: boundary, length: 0))
        fullView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        full.renderStyles()

        assertSameAttributes(attributeDump(fastStorage), attributeDump(fullStorage),
                             site: "a block boundary")
    }

    /// Whole-branch review, MINOR 6: AppKit posts `textViewDidChangeSelection`
    /// BETWEEN the storage mutation and `textDidChange`, so
    /// `revealForSelectionChange` can run once against `revealIndex.blocks`
    /// that still describe the PRE-edit string laid over the ALREADY-edited
    /// one. The suspected gap is an insertion at the exact last offset of a
    /// block (`blockRange.upperBound`, immediately before the boundary) —
    /// unlike a boundary-crossing insertion, the caret does not move onto or
    /// off a widened boundary, so the stale pass and the fresh pass could in
    /// principle disagree about what is revealed. Asserted immediately after
    /// `textDidChange`, with the 150 ms debounce given no chance to run and
    /// paper over a wrong frame — if this fails, the fast path can leave
    /// wrong text on screen for that whole debounce window.
    func test_anInsertionAtTheExactLastOffsetOfABlockMatchesAFullRenderImmediately() throws {
        let text = Self.fixture()
        let (probe, _) = makeEditor(text)
        let boundary = try XCTUnwrap(
            probe.revealIndex.blocks.first(where: { block in
                (text as NSString).substring(with: NSRange(location: block.lowerBound,
                                                           length: min(5, block.count)))
                    .hasPrefix("## Se")
            })?.upperBound,
            "the fixture must contain a heading block to find the end of")

        // FAST: caret at the block's exact last offset, no settle afterward.
        let (fast, fastView) = makeEditor(text)
        let fastStorage = try XCTUnwrap(fastView.textStorage)
        fastView.setSelectedRange(NSRange(location: boundary, length: 0))
        fastView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        XCTAssertTrue(fast.lastEditTookFastPath,
                      "an insertion at a block's last offset should still be a single-block edit")

        // FULL: the same edit, then a whole-document render on top — also
        // with no settle, so both sides are compared at the same instant.
        let (full, fullView) = makeEditor(text)
        let fullStorage = try XCTUnwrap(fullView.textStorage)
        fullView.setSelectedRange(NSRange(location: boundary, length: 0))
        fullView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        full.renderStyles()

        assertSameAttributes(attributeDump(fastStorage), attributeDump(fullStorage),
                             site: "a block's exact last offset")
    }

    // MARK: - The bail-outs

    /// Each listed case must fall back to the full render rather than take the
    /// fast path. Asserted on the flag, not inferred from timing.
    private func assertBails(insert: String, at site: String, deleting: Int = 0,
                             _ why: String) throws {
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
        try assertBails(insert: "\n", at: "prose with",
                        "a newline moves block boundaries")
    }

    func test_bails_whenTheEditContainsAFenceCharacter() throws {
        try assertBails(insert: "`", at: "prose with",
                        "a backtick can open or close a fence")
    }

    func test_bails_whenTheEditContainsATilde() throws {
        try assertBails(insert: "~", at: "prose with",
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
            XCTAssertFalse(coordinator.lastEditTookFastPath,
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
            XCTAssertFalse(coordinator.lastEditTookFastPath,
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
            XCTAssertFalse(coordinator.lastEditTookFastPath,
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
            XCTAssertFalse(coordinator.lastEditTookFastPath,
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
            XCTAssertEqual(MarkdownParseCounter.count, typed.count,
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
        let large = parsesForTyping(in: Self.fixture() + Self.fixture() + Self.fixture(),
                                    at: "prose with")
        XCTAssertEqual(small, large,
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
            let font = try XCTUnwrap(storage.attribute(.font, at: word.location,
                                                       effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold),
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
            let bodySize = try XCTUnwrap(storage.attribute(.font, at: line.location,
                                                           effectiveRange: nil) as? NSFont)
                .pointSize
            tv.setSelectedRange(NSRange(location: line.location, length: 0))
            for character in "## " {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            let heading = (tv.string as NSString).range(of: "plain line")
            let font = try XCTUnwrap(storage.attribute(.font, at: heading.location,
                                                       effectiveRange: nil) as? NSFont)
            XCTAssertGreaterThan(font.pointSize, bodySize,
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
            tv.insertText("", replacementRange: NSRange(location: NSMaxRange(opener) - 1,
                                                        length: 1))
            XCTAssertTrue(coordinator.lastEditTookFastPath)
            let word = (tv.string as NSString).range(of: "slanted")
            let font = try XCTUnwrap(storage.attribute(.font, at: word.location,
                                                       effectiveRange: nil) as? NSFont)
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.italic),
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
            tv.insertText("x", replacementRange: NSRange(location: found.location + 2,
                                                        length: 0))
            XCTAssertFalse(coordinator.lastEditTookFastPath,
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
            tv.insertText("x", replacementRange: NSRange(location: found.location + 2,
                                                        length: 0))
            XCTAssertTrue(coordinator.lastEditTookFastPath,
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
            XCTAssertTrue(coordinator.styleCache.describes(tv.string),
                          "the debounced parse must have refreshed the cache")
            XCTAssertEqual(attributeDump(storage).isEmpty, false)
        }
    }
}
