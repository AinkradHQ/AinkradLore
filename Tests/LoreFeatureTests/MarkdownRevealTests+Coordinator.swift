import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

@MainActor
extension MarkdownRevealTests {

    /// THE constraint of this milestone: collapsing changes attributes only.
    /// If this ever fails, a display concern has reached the document — and
    /// after fourteen data-loss defects in M0/M1, that is not a trade we make.
    func test_collapsingNeverChangesTheDocumentText() {
        let body = "**bold** and *italic*"
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse([0..<2, 6..<8], in: storage)
        XCTAssertEqual(storage.string, body)
    }

    /// Collapsed markers must take no width.
    func test_collapsedMarkersHaveEffectivelyZeroWidth() throws {
        let storage = NSTextStorage(string: "**bold**")
        MarkdownStyleRenderer.collapse([0..<2], in: storage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertLessThan(try XCTUnwrap(font).pointSize, 0.1)
        let kern = storage.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(try XCTUnwrap(kern), 0, accuracy: 0.001)
    }

    /// Uncollapsed text is untouched — collapse must be surgical.
    func test_collapseLeavesNeighbouringTextAlone() throws {
        let storage = NSTextStorage(string: "**bold**")
        storage.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 15),
            range: NSRange(location: 0, length: 8))
        MarkdownStyleRenderer.collapse([0..<2], in: storage)
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(font).pointSize, 15, accuracy: 0.01)
    }

    /// Marker ranges are NOT disjoint — a nested blockquote emits an outer and
    /// an inner marker that overlap — so `collapse` coalesces before applying.
    func test_overlappingAndAdjacentRangesCoalesce() {
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([0..<3, 0..<2]), [0..<3])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([2..<4, 0..<2]), [0..<4])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([5..<7, 0..<2]), [0..<2, 5..<7])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([1..<4, 2..<3]), [1..<4])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([3..<3, 1..<2]), [1..<2])
        XCTAssertEqual(MarkdownStyleRenderer.coalesce([]), [])
    }

    /// A nested blockquote really does produce overlapping markers; collapsing
    /// them must still hide exactly the syntax and leave the text alone.
    func test_nestedBlockQuoteMarkersOverlapAndStillCollapse() throws {
        let body = ">> quoted"
        let model = MarkdownDocumentModel(body: body)
        let markers = model.styleSpans.compactMap { span -> Range<Int>? in
            if case .marker = span.kind { return span.range }
            return nil
        }
        XCTAssertFalse(markers.isEmpty)
        let storage = NSTextStorage(string: body)
        storage.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 15),
            range: NSRange(location: 0, length: (body as NSString).length))
        MarkdownStyleRenderer.collapse(markers, in: storage)
        XCTAssertEqual(storage.string, body)
        let head = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertLessThan(try XCTUnwrap(head).pointSize, 0.1)
        let tail =
            storage.attribute(
                .font, at: (body as NSString).length - 1,
                effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(tail).pointSize, 15, accuracy: 0.01)
    }

    /// Out-of-bounds ranges are skipped, not trapped, and never touch the text.
    func test_collapseIgnoresOutOfBoundsRanges() {
        let body = "abc"
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse([2..<99, -4 ..< -1], in: storage)
        XCTAssertEqual(storage.string, body)
    }

    /// Requirement 1. Reveal must be driven by SELECTION, not only by edits —
    /// otherwise markers only update when the user types, which reads as the
    /// editor being stuck. Nothing about the text changes between these two
    /// calls; only the caret moves.
    func test_changingOnlyTheSelectionChangesWhichMarkersAreHidden() {
        let body = "**a**\n\n*b*"
        let model = MarkdownDocumentModel(body: body)
        let blocks = MarkdownReveal.blocks(in: body)
        let storage = NSTextStorage(string: body)

        func markerSize(caret: Int) -> CGFloat {
            MarkdownStyleRenderer.apply(
                model.styleSpans, to: storage,
                tokens: TestTokens.make(),
                theme: MarkdownTheme(tokens: TestTokens.make()),
                limitedTo: nil)
            MarkdownStyleRenderer.collapse(
                MarkdownReveal.hiddenMarkers(
                    spans: model.styleSpans,
                    selection: NSRange(location: caret, length: 0),
                    text: body, isFocused: true),
                in: storage)
            return (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?
                .pointSize ?? -1
        }

        // Caret in the SECOND block: the first block's `**` is collapsed.
        XCTAssertLessThan(markerSize(caret: 8), 0.1)
        // Caret in the FIRST block, same text, same spans: it comes back.
        XCTAssertGreaterThan(markerSize(caret: 1), 1)
        XCTAssertEqual(storage.string, body, "reveal is attributes only")
    }

    /// The fast path that keeps arrowing cheap: which blocks are revealed is
    /// the whole of the reveal state, and it only changes when the caret
    /// CROSSES a block boundary. Moving within a block must be a no-op, so the
    /// editor can skip re-attributing entirely.
    func test_revealedBlocksAreStableWhileTheCaretMovesWithinOneBlock() {
        let body = "**a** and more\n\n*b*"
        let blocks = MarkdownReveal.blocks(in: body)
        let atOne = MarkdownEditorReveal.revealedBlocks(
            blocks, selection: NSRange(location: 1, length: 0))
        let atFive = MarkdownEditorReveal.revealedBlocks(
            blocks, selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(atOne, atFive, "moving inside a block must not change reveal")

        let inSecond = MarkdownEditorReveal.revealedBlocks(
            blocks, selection: NSRange(location: (body as NSString).length - 1, length: 0))
        XCTAssertNotEqual(atOne, inSecond, "crossing a boundary must change reveal")
    }

    /// A live editor over `body`, styled once, with the caret at `caret`.
    private func editor(_ body: String, caret: Int, width: CGFloat = 800)
        -> (LinkTextView, MarkdownEditor.Coordinator)
    {
        let tokens = TestTokens.make()
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.string = body
        let coordinator = MarkdownEditor.Coordinator(text: .constant(body), tokens: tokens)
        coordinator.textView = tv
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.applyStyles()
        return (tv, coordinator)
    }

    /// FINDING 1/2. Crossing a block boundary must re-attribute the two blocks
    /// that changed and NOTHING else. The first version of this called
    /// `renderStyles()`, which clears and restyles the whole document — so
    /// arrowing down ordinary prose restyled the note every few keypresses.
    ///
    /// Pinned with a sentinel: an attribute written into a distant block by
    /// hand survives the caret move only if that block was never touched.
    func test_crossingABlockBoundaryRestylesOnlyTheBlocksThatChanged() throws {
        let body = "**one**\n\n**two**\n\n**three**\n\n**four**"
        let (tv, coordinator) = editor(body, caret: 1)
        let storage = try XCTUnwrap(tv.textStorage)

        let distant = (body as NSString).range(of: "four")
        let sentinel = NSColor.magenta
        storage.addAttribute(.foregroundColor, value: sentinel, range: distant)

        // Caret from block 0 into block 1 — two blocks away from the sentinel.
        tv.setSelectedRange(
            NSRange(
                location: (body as NSString).range(of: "two").location,
                length: 0))
        coordinator.revealForSelectionChange()

        let survived =
            storage.attribute(
                .foregroundColor, at: distant.location,
                effectiveRange: nil) as? NSColor
        XCTAssertEqual(
            survived, sentinel,
            "an untouched block must not be re-attributed by a caret move")
    }

    /// FINDING 1/2. `MarkdownReveal.blocks(in:)` is an O(document) scan and
    /// depends only on the TEXT, so a caret move must never trigger it. The
    /// index that holds it is rebuilt only by a render.
    func test_movingTheCaretNeverRebuildsTheBlockIndex() {
        let body = "**one**\n\n**two**\n\n**three**\n\n**four**"
        let (tv, coordinator) = editor(body, caret: 1)
        let afterRender = coordinator.revealIndexBuilds
        XCTAssertGreaterThan(afterRender, 0, "the render must have built it once")

        let ns = body as NSString
        // Within a block, and across three boundaries.
        for caret in [
            2, 3, ns.range(of: "two").location, ns.range(of: "three").location,
            ns.range(of: "four").location, 1,
        ] {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            coordinator.revealForSelectionChange()
        }
        XCTAssertEqual(
            coordinator.revealIndexBuilds, afterRender,
            "no caret move may rescan the document for blocks")
    }

    /// And the reveal still has to be CORRECT after all that incremental work:
    /// the block the caret lands in shows its markers, the one it left hides
    /// them again, and the text is untouched throughout.
    func test_theIncrementalPathStillRevealsAndRehidesCorrectly() throws {
        let body = "**one**\n\n**two**\n\n**three**"
        let (tv, coordinator) = editor(body, caret: 1)
        let storage = try XCTUnwrap(tv.textStorage)
        let secondMarker = (body as NSString).range(of: "**two").location

        func size(at offset: Int) -> CGFloat {
            (storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)?
                .pointSize ?? -1
        }
        XCTAssertGreaterThan(size(at: 0), 1, "the caret's own block is revealed")
        XCTAssertLessThan(size(at: secondMarker), 0.1, "other blocks are hidden")

        tv.setSelectedRange(NSRange(location: secondMarker + 2, length: 0))
        coordinator.revealForSelectionChange()
        XCTAssertLessThan(size(at: 0), 0.1, "the block left behind re-hides")
        XCTAssertGreaterThan(size(at: secondMarker), 1, "the block entered reveals")
        XCTAssertEqual(storage.string, body, "reveal is attributes only")
    }

    /// FINDING 4. The live-resize path: `setFrameSize` is the only hook that
    /// fires while a window is being dragged. It must re-centre the column and
    /// SETTLE — the handler writes `textContainerInset`, which can itself
    /// resize the view, and only a width guard stands between that and a loop.
    func test_theRealSetFrameSizePathRecentresAndSettles() {
        let body = "some prose"
        let (tv, coordinator) = editor(body, caret: 0, width: 400)
        var callbacks = 0
        tv.onWidthChange = { [weak coordinator] width in
            callbacks += 1
            coordinator?.applyContainerGeometry(forWidth: width)
        }

        tv.setFrameSize(NSSize(width: 2000, height: 600))
        XCTAssertEqual(callbacks, 1, "one width change must produce exactly one pass")
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let expected = MarkdownEditorLayout.containerInset(forViewWidth: 2000, theme: theme)
        XCTAssertEqual(
            tv.textContainerInset.width, expected.width, accuracy: 0.5,
            "the real resize path must re-centre the column")

        // Same width again, and a HEIGHT-only change — neither is a width
        // change, and neither may re-enter the handler.
        tv.setFrameSize(NSSize(width: 2000, height: 600))
        tv.setFrameSize(NSSize(width: 2000, height: 4000))
        XCTAssertEqual(callbacks, 1, "the path must settle, not recurse")
    }

    /// End to end: what `hiddenMarkers` reports, `collapse` hides — and the
    /// document text is identical afterwards.
    func test_hiddenMarkersCollapseWithoutTouchingTheDocument() {
        let body = "**bold**\n\nplain paragraph"
        let caret = NSRange(location: (body as NSString).length - 1, length: 0)
        let ranges = hidden(body, selection: caret)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.collapse(ranges, in: storage)
        XCTAssertEqual(storage.string, body)
        XCTAssertEqual((storage.string as NSString).length, (body as NSString).length)
    }
}
