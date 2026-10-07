import AppKit

/// The selection-driven half of Live Preview.
///
/// `MarkdownReveal` answers "which markers are hidden". This answers the
/// cheaper question the editor asks on EVERY arrow-key press: has anything
/// about the reveal actually changed? Recomputing hidden markers costs a walk
/// over every span in the document; recomputing revealed BLOCKS costs a walk
/// over the blocks, of which there are orders of magnitude fewer. When the
/// answer is unchanged — which is every keypress that does not cross a blank
/// line — the editor does no styling work at all.
///
/// Neither path parses. Block ranges come from `MarkdownReveal.blocks(in:)`,
/// which is a character scan, and they are recomputed only when the text is
/// re-rendered.
enum MarkdownEditorReveal {

    /// Everything the caret path needs, derived once per TEXT change.
    ///
    /// The point of this type is that `revealForSelectionChange` may touch none
    /// of the document: the block ranges are here rather than rescanned, the
    /// spans are already bucketed by block so no walk over all spans is needed
    /// to find the two that matter, and list depths — which are global, being
    /// derived from containment — are computed once so a per-block restyle
    /// cannot disagree with a full one.
    struct Index {
        let blocks: [Range<Int>]
        /// Positions into the coordinator's `spans`, bucketed by block. A span
        /// belongs to the block containing its start; markdown spans do not
        /// cross a blank line, so that is also the block containing all of it.
        let spansByBlock: [[Int]]
        /// Nesting depth per span, aligned by index. See `MarkdownListDepth`.
        let depths: [Int]
        /// The single-pair spans that cross a line — all the caret path needs
        /// to compute reveal. See `MarkdownReveal.wideSpans`, which explains
        /// why this is cached rather than derived per caret move.
        let wideSpans: [Range<Int>]

        static let empty = Index(blocks: [], spansByBlock: [], depths: [], wideSpans: [])
    }

    /// Builds the index for `text` and `spans`. O(text) once, on a text change
    /// — never on a caret move.
    static func index(text: String, spans: [StyleSpan]) -> Index {
        index(
            blocks: MarkdownReveal.blocks(in: text), spans: spans,
            wideSpans: MarkdownReveal.wideSpans(in: text, spans: spans))
    }

    /// The same, for a caller that has ALREADY segmented the text.
    ///
    /// The edit path recomputes the block list every keystroke to prove the
    /// segmentation did not move (`renderStylesForEdit`, check 4); having it
    /// then call `index(text:spans:)` would scan the document a second time for
    /// an answer it is holding.
    static func index(
        blocks: [Range<Int>], spans: [StyleSpan],
        wideSpans: [Range<Int>]
    ) -> Index {
        var buckets = [[Int]](repeating: [], count: blocks.count)
        for (position, span) in spans.enumerated() {
            guard let block = blockIndex(of: span.range.lowerBound, in: blocks) else { continue }
            buckets[block].append(position)
        }
        return Index(
            blocks: blocks, spansByBlock: buckets,
            depths: MarkdownListDepth.depths(of: spans),
            wideSpans: wideSpans)
    }

    /// The block containing `offset`, by binary search. Blocks are sorted and
    /// contiguous, which is what makes this — and `revealedBlockIndices` —
    /// logarithmic rather than a scan.
    static func blockIndex(of offset: Int, in blocks: [Range<Int>]) -> Int? {
        var low = 0
        var high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offset < blocks[mid].lowerBound {
                high = mid - 1
            } else if offset >= blocks[mid].upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        // Past the last block's end — an offset at the very end of the
        // document belongs to the last block rather than to nothing.
        return blocks.isEmpty ? nil : min(max(low, 0), blocks.count - 1)
    }

    /// The indices of the blocks a source RANGE overlaps, or none for `nil`.
    ///
    /// Two binary searches and then a count, so a caret move locates the blocks
    /// it affects without walking the document — the property the caret path
    /// has always been held to. A line-scoped reveal overlaps one block almost
    /// always, and two only where a line sits across a block boundary.
    static func blockIndices(
        touching range: Range<Int>?,
        in blocks: [Range<Int>]
    ) -> Set<Int> {
        guard let range, !blocks.isEmpty,
            let first = blockIndex(of: range.lowerBound, in: blocks),
            let last = blockIndex(
                of: max(range.lowerBound, range.upperBound - 1),
                in: blocks)
        else { return [] }
        return Set(min(first, last)...max(first, last))
    }

    /// The INDICES of the blocks the selection touches.
    ///
    /// Contiguous, and therefore a range rather than a set: blocks tile the
    /// document end to end, so the blocks a selection touches are exactly those
    /// between the one holding its start and the one holding its end. A caret
    /// resting exactly on a boundary belongs to both adjacent blocks — the
    /// inclusive rule `MarkdownReveal.hiddenMarkers` uses — which this
    /// preserves by widening one step at a boundary rather than flickering
    /// between two answers.
    static func revealedBlockIndices(
        _ blocks: [Range<Int>],
        selection: NSRange
    ) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        let lower = selection.location
        let upper = lower + max(selection.length, 0)
        guard var first = blockIndex(of: lower, in: blocks),
            var last = blockIndex(of: upper, in: blocks)
        else { return 0..<0 }
        if first > 0, blocks[first].lowerBound == lower { first -= 1 }
        if last < blocks.count - 1, blocks[last].upperBound == upper { last += 1 }
        return first..<(last + 1)
    }

    /// The blocks the selection touches, and therefore the blocks whose
    /// markers are shown.
    ///
    /// The value-level statement of the same rule, kept for tests and for
    /// callers that want the ranges rather than their positions.
    static func revealedBlocks(
        _ blocks: [Range<Int>],
        selection: NSRange
    ) -> [Range<Int>] {
        let lower = selection.location
        let upper = selection.location + max(selection.length, 0)
        return blocks.filter { lower <= $0.upperBound && $0.lowerBound <= upper }
    }
}
