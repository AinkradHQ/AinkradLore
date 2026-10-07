import AppKit
import SwiftUI
import XCTest

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
    func makeEditor(_ text: String) -> (MarkdownEditor.Coordinator, NSTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = coordinator
        let window = NSWindow(
            contentRect: tv.frame, styleMask: [.titled],
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

    func settle(_ seconds: TimeInterval = 0.6) {
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
    func attributeDump(_ storage: NSTextStorage) -> [String] {
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
                    guard
                        let color = (value as? NSColor)?
                            .usingColorSpace(.sRGB)
                    else { return "\(key.rawValue)=?" }
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
    static func fixture() -> String {
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
    private func dumpAfterEdit(
        insert: String, at location: Int,
        deleting length: Int,
        forceFullRender: Bool
    ) throws -> (dump: [String], usedFast: Bool) {
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
            XCTAssertGreaterThan(
                coordinator.revealIndexBuilds, before,
                "the edit must have re-rendered something")
            return (attributeDump(storage), usedFast)
        }
    }

    /// Compares two dumps and reports the FIRST difference rather than both
    /// dumps in full — a 40-section fixture produces hundreds of runs, and an
    /// `XCTAssertEqual` on the arrays prints all of them truncated, which says
    /// nothing about what actually differs.
    private func assertSameAttributes(
        _ fast: [String], _ full: [String],
        site: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0..<min(fast.count, full.count) where fast[index] != full[index] {
            XCTFail(
                """
                typing inside "\(site)" produced different attributes at run \(index):
                  fast: \(fast[index])
                  full: \(full[index])
                """, file: file, line: line)
            return
        }
        XCTAssertEqual(
            fast.count, full.count,
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
        let sites = [
            "prose with", "**bold**", "[[Link 5]]", "- a second item",
            "## Section 7", "> a quoted line", "let x3 = 3",
        ]
        for site in sites {
            let found = text.range(of: site)
            XCTAssertNotEqual(found.location, NSNotFound, "fixture must contain \(site)")
            let caret = found.location + found.length / 2

            let fast = try dumpAfterEdit(
                insert: "x", at: caret, deleting: 0,
                forceFullRender: false)
            let full = try dumpAfterEdit(
                insert: "x", at: caret, deleting: 0,
                forceFullRender: true)
            XCTAssertTrue(
                fast.usedFast,
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

        let fast = try dumpAfterEdit(
            insert: "", at: found.location, deleting: 5,
            forceFullRender: false)
        let full = try dumpAfterEdit(
            insert: "", at: found.location, deleting: 5,
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
                (text as NSString).substring(
                    with: NSRange(
                        location: block.lowerBound,
                        length: min(5, block.count))
                )
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
        XCTAssertNotEqual(
            fast.revealedRange, was,
            "typing at a boundary must move the revealed range")

        // FULL: the same edit, then a whole-document render on top.
        let (full, fullView) = makeEditor(text)
        let fullStorage = try XCTUnwrap(fullView.textStorage)
        fullView.setSelectedRange(NSRange(location: boundary, length: 0))
        fullView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        full.renderStyles()

        assertSameAttributes(
            attributeDump(fastStorage), attributeDump(fullStorage),
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
                (text as NSString).substring(
                    with: NSRange(
                        location: block.lowerBound,
                        length: min(5, block.count))
                )
                .hasPrefix("## Se")
            })?.upperBound,
            "the fixture must contain a heading block to find the end of")

        // FAST: caret at the block's exact last offset, no settle afterward.
        let (fast, fastView) = makeEditor(text)
        let fastStorage = try XCTUnwrap(fastView.textStorage)
        fastView.setSelectedRange(NSRange(location: boundary, length: 0))
        fastView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        XCTAssertTrue(
            fast.lastEditTookFastPath,
            "an insertion at a block's last offset should still be a single-block edit")

        // FULL: the same edit, then a whole-document render on top — also
        // with no settle, so both sides are compared at the same instant.
        let (full, fullView) = makeEditor(text)
        let fullStorage = try XCTUnwrap(fullView.textStorage)
        fullView.setSelectedRange(NSRange(location: boundary, length: 0))
        fullView.insertText("x", replacementRange: NSRange(location: boundary, length: 0))
        full.renderStyles()

        assertSameAttributes(
            attributeDump(fastStorage), attributeDump(fullStorage),
            site: "a block's exact last offset")
    }
}
