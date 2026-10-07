import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

final class MarkdownRevealTests: XCTestCase {

    func hidden(
        _ body: String, selection: NSRange,
        isFocused: Bool = true
    ) -> [Range<Int>] {
        let model = MarkdownDocumentModel(body: body)
        return MarkdownReveal.hiddenMarkers(
            spans: model.styleSpans,
            selection: selection,
            text: body,
            isFocused: isFocused)
    }

    // MARK: - The reveal unit is the LINE

    /// THE test for this change. A list with no blank line between its items is
    /// ONE block, so a block-scoped reveal showed the `- ` marker on every item
    /// the moment the caret entered any of them. Obsidian — the bar Ahmed set —
    /// reveals only the line you are on.
    func test_aCaretInOneListItemRevealsOnlyThatItemsMarker() {
        let body = "- alpha\n- beta\n- gamma\n"
        // Precondition: this really is one block, or the test proves nothing.
        XCTAssertEqual(
            MarkdownReveal.blocks(in: body).count, 1,
            "a list with no blank lines must be a single block, "
                + "or this test is not exercising the defect it exists for")

        let caretInBeta = NSRange(location: body.utf16.count / 2, length: 0)
        let hiddenRanges = hidden(body, selection: caretInBeta)
        let ns = body as NSString
        let betaLine = ns.lineRange(for: caretInBeta)

        XCTAssertFalse(
            hiddenRanges.isEmpty,
            "the other two items' markers must still be hidden")
        for range in hiddenRanges {
            XCTAssertFalse(
                range.lowerBound >= betaLine.location
                    && range.upperBound <= NSMaxRange(betaLine),
                "no marker on the caret's own line may be hidden")
        }
    }

    /// The mirror: every OTHER line's markers stay hidden while one is revealed.
    /// Asserted on a paragraph of hard-wrapped prose, the other shape where a
    /// block holds several lines.
    func test_revealingOneLineLeavesTheRestOfTheParagraphRendered() {
        let body = "**one** here\n**two** here\n**three** here\n"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 1)

        let caretOnFirstLine = NSRange(location: 3, length: 0)
        let hiddenRanges = hidden(body, selection: caretOnFirstLine)
        // Two lines' worth of `**` pairs = four markers still collapsed.
        XCTAssertEqual(
            hiddenRanges.count, 4,
            "lines two and three keep both of their markers hidden")
        for range in hiddenRanges {
            XCTAssertGreaterThanOrEqual(
                range.lowerBound, 13,
                "nothing on the caret's line may be hidden")
        }
    }

    /// A fenced code block reveals WHOLE, because its markers are the fence
    /// lines: a line-scoped rule alone would leave the caret sitting inside a
    /// block whose delimiters it could neither see nor edit.
    func test_aCaretInsideAFenceRevealsTheFenceLines() {
        let body = "intro\n\n```swift\nlet x = 1\nlet y = 2\n```\n\ntail\n"
        let caretInsideTheCode = NSRange(
            location: (body as NSString).range(of: "let y").location,
            length: 0)
        let hiddenRanges = hidden(body, selection: caretInsideTheCode)
        let fenceStart = (body as NSString).range(of: "```swift").location
        for range in hiddenRanges {
            XCTAssertFalse(
                range.lowerBound >= fenceStart,
                "the fence's own markers must be revealed when the caret "
                    + "is anywhere inside the code block")
        }
    }

    /// And the deliberate NON-widening: a block quote spans lines too, but each
    /// line carries its own `>`, so revealing them all is exactly the defect.
    func test_aCaretInAQuoteRevealsOnlyItsOwnLinesMarker() {
        let body = "> first line\n> second line\n> third line\n"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 1)
        let caretOnSecond = NSRange(
            location: (body as NSString).range(of: "second").location,
            length: 0)
        XCTAssertFalse(
            hidden(body, selection: caretOnSecond).isEmpty,
            "the other quote lines' markers stay hidden")
    }

    /// An unfocused editor KEEPS its selection, so the block the caret was
    /// last in stayed revealed and its syntax stayed on screen. Reveal is a
    /// function of the selection AND of first-responder state: unfocused means
    /// no revealed block at all.
    func test_losingFocusHidesEveryMarker() {
        let body = "**bold**\n\nplain paragraph"
        let caretInsideTheSpan = NSRange(location: 3, length: 0)
        XCTAssertTrue(
            hidden(body, selection: caretInsideTheSpan).isEmpty,
            "focused: the caret's own block reveals")
        XCTAssertFalse(
            hidden(body, selection: caretInsideTheSpan, isFocused: false).isEmpty,
            "unfocused: nothing reveals")
    }

    /// The end-to-end regression for the resign-first-responder timing bug,
    /// driven through the REAL production wiring rather than a re-declared
    /// copy of it.
    ///
    /// A first version of this test built its own `LinkTextView` and assigned
    /// `onResignFirstResponder`/`onBecomeFirstResponder` closures by hand,
    /// hardcoding the `forcedFocus` argument inline. That proved the
    /// MECHANISM (`revealForSelectionChange(forcedFocus:)` does what it
    /// says) but not the actual bug, which was never in the mechanism — it
    /// was in what `MarkdownEditor.makeNSView` passes to it. That version
    /// would keep passing even if the production closure at
    /// `MarkdownEditor.swift`'s `tv.onResignFirstResponder` were reverted
    /// back to a bare `revealForSelectionChange()`, because the test's own
    /// hardcoded `false` would still be there doing the work. It only failed
    /// if `forcedFocus` were deleted outright — a compile error, not a
    /// regression.
    ///
    /// This version instead hosts the real `MarkdownEditor` SwiftUI view in
    /// an `NSHostingView` inside a REAL `NSWindow` — the same technique
    /// `RichTextEngineTests.hostedWindow` already uses in this target — which
    /// forces SwiftUI to actually run `MarkdownEditor.makeNSView` and
    /// produce the real `LinkTextView` with the real `onResignFirstResponder`/
    /// `onBecomeFirstResponder` closures attached, exactly as the app wires
    /// them. Reverting `MarkdownEditor.swift`'s resign/become closures back
    /// to unforced calls turns THIS test red — confirmed locally (see the
    /// fix report).
    @MainActor
    func test_resigningFirstResponderActuallyHidesTheMarkers() throws {
        let body = "**bold**\n\nplain paragraph"
        let hosting = NSHostingView(
            rootView: AnyView(
                MarkdownEditor(text: .constant(body), tokens: TestTokens.make())))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let tv = try XCTUnwrap(
            Self.findLinkTextView(in: hosting),
            "MarkdownEditor.makeNSView must have produced a LinkTextView by now")
        // A caret click, not a test-only shortcut: `setSelectedRange` is the
        // same call AppKit itself makes on a mouse click, and — because
        // `tv.delegate` is the real coordinator, wired by the real
        // `makeNSView` — it drives the real `textViewDidChangeSelection`.
        tv.setSelectedRange(NSRange(location: 3, length: 0))

        let storage = try XCTUnwrap(tv.textStorage)
        func markerSize() -> CGFloat {
            (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        }

        XCTAssertTrue(window.makeFirstResponder(tv))
        XCTAssertGreaterThan(markerSize(), 1, "focused: the caret's own block is revealed")

        // Resigns to the WINDOW itself — always a valid first responder, so
        // this exercises the real `resignFirstResponder` call without
        // needing a second view to hand focus to.
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertLessThan(markerSize(), 0.1, "resigning first responder must hide the markers")

        XCTAssertTrue(window.makeFirstResponder(tv))
        XCTAssertGreaterThan(markerSize(), 1, "regaining first responder must reveal them again")
    }

    /// Depth-first search of a REAL, SwiftUI-produced view hierarchy for the
    /// `LinkTextView` `MarkdownEditor.makeNSView` builds — it sits inside an
    /// `NSScrollView`'s `documentView`, several levels below the hosting view.
    private static func findLinkTextView(in view: NSView) -> LinkTextView? {
        if let tv = view as? LinkTextView { return tv }
        for subview in view.subviews {
            if let found = findLinkTextView(in: subview) { return found }
        }
        return nil
    }

    /// Unfocused hides EVERY marker, not merely the caret's block.
    func test_unfocusedHidesMarkersInEveryBlock() {
        let body = "**a**\n\n*b*\n\n`c`"
        let model = MarkdownDocumentModel(body: body)
        let markers = model.styleSpans.filter { if case .marker = $0.kind { return true } else { return false } }
        XCTAssertEqual(
            hidden(
                body, selection: NSRange(location: 2, length: 0),
                isFocused: false
            ).count,
            markers.count)
    }

    /// With the caret elsewhere, every marker is hidden — this is the clean
    /// reading state.
    func test_markersAreHiddenWhenTheSelectionIsInAnotherBlock() {
        let body = "**bold**\n\nplain paragraph"
        let caret = NSRange(location: (body as NSString).length - 1, length: 0)
        XCTAssertFalse(hidden(body, selection: caret).isEmpty)
    }

    /// Caret inside the block: that block's markers come back so the user can
    /// edit the syntax they are standing in.
    func test_markersRevealWhenTheSelectionIsInsideTheirBlock() {
        let body = "**bold**\n\nplain paragraph"
        XCTAssertTrue(hidden(body, selection: NSRange(location: 3, length: 0)).isEmpty)
    }

    /// A span delimited by a SINGLE marker pair reveals wholly, even across a
    /// line break.
    ///
    /// This test used to be named `test_revealIsBlockScoped…` and its comment
    /// read "Obsidian reveals per line, which splits a multi-line emphasis span
    /// mid-word and looks broken". The concern was right; the remedy — making
    /// EVERY construct reveal by block — was too coarse, and is what showed all
    /// five markers of a list when the caret entered one item. Reveal is now
    /// line-scoped and widens over single-pair spans specifically, so the
    /// guarantee this test protects is unchanged while the collateral damage is
    /// gone. See `StyleSpan.Kind.isDelimitedByASinglePair`.
    func test_aMultiLineSpanRevealsWholly() {
        let body = "**bold\nacross lines**\n\nother"
        // Caret on the FIRST line of the span; the marker on the SECOND line
        // must reveal too.
        XCTAssertTrue(hidden(body, selection: NSRange(location: 2, length: 0)).isEmpty)
    }

    /// A selection spanning two blocks reveals both.
    func test_aSelectionCrossingBlocksRevealsBoth() {
        let body = "**a**\n\n*b*"
        let whole = NSRange(location: 0, length: (body as NSString).length)
        XCTAssertTrue(hidden(body, selection: whole).isEmpty)
    }

    /// Only the touched block reveals — the other keeps its markers hidden.
    func test_anUntouchedBlockKeepsItsMarkersHidden() {
        let body = "**a**\n\n*b*"
        let inFirst = NSRange(location: 1, length: 0)
        let stillHidden = hidden(body, selection: inFirst)
        XCTAssertEqual(stillHidden.count, 2, "the emphasis pair in the second block")
    }

    /// A CRLF document with a single line break and no blank line is ONE
    /// block. "\r\n" is one line terminator, not a blank-line marker.
    func test_aSingleCRLFLineBreakIsNotABlankLine() {
        let body = "para one line a\r\npara one line b"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 1)
    }

    /// A genuine blank line in CRLF form ("\r\n\r\n") splits into TWO blocks.
    func test_aCRLFBlankLineSplitsIntoTwoBlocks() {
        let body = "para one\r\n\r\npara two"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 2)
    }

    /// A lone "\r" (old Mac line ending) behaves the same as "\n": one
    /// terminator, and two in a row is a blank line.
    func test_aLoneCarriageReturnBehavesLikeANewline() {
        let single = "para one line a\rpara one line b"
        XCTAssertEqual(MarkdownReveal.blocks(in: single).count, 1)

        let blank = "para one\r\rpara two"
        XCTAssertEqual(MarkdownReveal.blocks(in: blank).count, 2)
    }

    /// Mixed line endings within one document are each counted as a single
    /// terminator, not per-unit.
    func test_mixedLineEndingsAreCountedAsSingleTerminators() {
        let body = "line a\r\nline b\nline c\r\n\r\nline d"
        XCTAssertEqual(MarkdownReveal.blocks(in: body).count, 2)
    }

    /// The multi-line reveal guarantee holds in a CRLF document too: the CRLF
    /// analogue of `test_aMultiLineSpanRevealsWholly`.
    func test_aMultiLineSpanRevealsWhollyAcrossACRLFLineBreak() {
        let body = "**bold\r\nacross lines**\r\n\r\nother"
        // Caret on the FIRST line of the span; the marker on the SECOND line
        // must reveal too, because CRLF must not fracture the block.
        XCTAssertTrue(hidden(body, selection: NSRange(location: 2, length: 0)).isEmpty)
    }

    // MARK: - M6 syntax reveal (Finding 6 / spec §9)

    /// `==highlight==` is delimited by a single pair, exactly like `**bold**`
    /// — focused with the caret inside reveals both markers.
    func test_highlightMarkersRevealWhenFocusedInsideTheSpan() {
        let body = "before ==lit== after"
        XCTAssertTrue(hidden(body, selection: NSRange(location: 9, length: 0)).isEmpty)
    }

    func test_highlightMarkersHideWhenUnfocused() {
        let body = "before ==lit== after"
        XCTAssertFalse(
            hidden(
                body, selection: NSRange(location: 9, length: 0),
                isFocused: false
            ).isEmpty)
    }

    /// `[^1]` inline reference.
    func test_footnoteReferenceMarkersRevealWhenFocusedInsideTheSpan() {
        let body = "claim[^1] more"
        XCTAssertTrue(hidden(body, selection: NSRange(location: 7, length: 0)).isEmpty)
    }

    func test_footnoteReferenceMarkersHideWhenUnfocused() {
        let body = "claim[^1] more"
        XCTAssertFalse(
            hidden(
                body, selection: NSRange(location: 7, length: 0),
                isFocused: false
            ).isEmpty)
    }

    /// `[^1]:` definition at line start.
    func test_footnoteDefinitionMarkersRevealWhenFocusedInsideTheSpan() {
        let body = "[^1]: the note"
        XCTAssertTrue(hidden(body, selection: NSRange(location: 2, length: 0)).isEmpty)
    }

    func test_footnoteDefinitionMarkersHideWhenUnfocused() {
        let body = "[^1]: the note"
        XCTAssertFalse(
            hidden(
                body, selection: NSRange(location: 2, length: 0),
                isFocused: false
            ).isEmpty)
    }

    /// `#tag` carries no `.marker` span at all — see
    /// `MarkdownDocumentModel.styleSpans(from:)`: the `#` stays visible on
    /// purpose, so there is nothing for reveal to collapse in EITHER focus
    /// state. Pinned so a future marker span added for tags is forced to
    /// update this pair.
    func test_tagHasNoMarkersToRevealOrHideInEitherFocusState() {
        let body = "before #idea after"
        let caret = NSRange(location: 10, length: 0)
        XCTAssertTrue(hidden(body, selection: caret).isEmpty)
        XCTAssertTrue(hidden(body, selection: caret, isFocused: false).isEmpty)
    }

    /// `^block-id` — same shape as `.tag`, same "nothing to collapse" answer.
    func test_blockIDHasNoMarkersToRevealOrHideInEitherFocusState() {
        let body = "A paragraph. ^abc123"
        let caret = NSRange(location: 15, length: 0)
        XCTAssertTrue(hidden(body, selection: caret).isEmpty)
        XCTAssertTrue(hidden(body, selection: caret, isFocused: false).isEmpty)
    }
}
