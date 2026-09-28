import AppKit
import SwiftUI
import AinkradAppKit

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
        index(blocks: MarkdownReveal.blocks(in: text), spans: spans,
              wideSpans: MarkdownReveal.wideSpans(in: text, spans: spans))
    }

    /// The same, for a caller that has ALREADY segmented the text.
    ///
    /// The edit path recomputes the block list every keystroke to prove the
    /// segmentation did not move (`renderStylesForEdit`, check 4); having it
    /// then call `index(text:spans:)` would scan the document a second time for
    /// an answer it is holding.
    static func index(blocks: [Range<Int>], spans: [StyleSpan],
                      wideSpans: [Range<Int>]) -> Index {
        var buckets = [[Int]](repeating: [], count: blocks.count)
        for (position, span) in spans.enumerated() {
            guard let block = blockIndex(of: span.range.lowerBound, in: blocks) else { continue }
            buckets[block].append(position)
        }
        return Index(blocks: blocks, spansByBlock: buckets,
                     depths: MarkdownListDepth.depths(of: spans),
                     wideSpans: wideSpans)
    }

    /// The block containing `offset`, by binary search. Blocks are sorted and
    /// contiguous, which is what makes this — and `revealedBlockIndices` —
    /// logarithmic rather than a scan.
    static func blockIndex(of offset: Int, in blocks: [Range<Int>]) -> Int? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offset < blocks[mid].lowerBound { high = mid - 1 }
            else if offset >= blocks[mid].upperBound { low = mid + 1 }
            else { return mid }
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
    static func blockIndices(touching range: Range<Int>?,
                             in blocks: [Range<Int>]) -> Set<Int> {
        guard let range, !blocks.isEmpty,
              let first = blockIndex(of: range.lowerBound, in: blocks),
              let last = blockIndex(of: max(range.lowerBound, range.upperBound - 1),
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
    static func revealedBlockIndices(_ blocks: [Range<Int>],
                                     selection: NSRange) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        let lower = selection.location
        let upper = lower + max(selection.length, 0)
        guard var first = blockIndex(of: lower, in: blocks),
              var last = blockIndex(of: upper, in: blocks) else { return 0..<0 }
        if first > 0, blocks[first].lowerBound == lower { first -= 1 }
        if last < blocks.count - 1, blocks[last].upperBound == upper { last += 1 }
        return first..<(last + 1)
    }

    /// The blocks the selection touches, and therefore the blocks whose
    /// markers are shown.
    ///
    /// The value-level statement of the same rule, kept for tests and for
    /// callers that want the ranges rather than their positions.
    static func revealedBlocks(_ blocks: [Range<Int>],
                               selection: NSRange) -> [Range<Int>] {
        let lower = selection.location
        let upper = selection.location + max(selection.length, 0)
        return blocks.filter { lower <= $0.upperBound && $0.lowerBound <= upper }
    }
}

extension MarkdownEditor.Coordinator {

    // MARK: - Styling

    /// The one entry point for callers that do not know whether the text
    /// changed: `makeNSView`, and `updateNSView` on every ancestor redraw.
    ///
    /// Parses ONLY when the cached spans describe a different string than
    /// the one on screen — which, after a keystroke, they do not, because
    /// `textDidChange` has already shifted them. A redraw therefore costs a
    /// render and nothing else.
    /// A LARGE document arriving here — the open path, a document switch, an
    /// external write — no longer parses on the main actor. It claims currency
    /// provisionally, renders unstyled, and `parseNow` fills the spans in from
    /// off-actor with the same snapshot-and-check discipline the debounce uses:
    /// the result is adopted only if the view still holds exactly the string it
    /// was derived from. Adopting a stale parse would style the wrong
    /// characters, which is the defect class M2a exists to remove.
    ///
    /// Small documents still parse inline — see
    /// `MarkdownStyleCache.synchronousParseCap` for why the flash, not the
    /// milliseconds, is the thing being avoided there.
    func applyStyles() {
        guard let tv = textView else { return }
        applyStylesCalls += 1
        // The redundant-redraw guard — see `isRenderStale` in
        // `MarkdownEditorEditPath.swift` for what it checks and why a keystroke
        // reaches here at all.
        if !isRenderStale(for: tv) { return }
        applyStylesRenders += 1
        if !styleCache.describes(tv.string) {
            if tv.string.utf16.count <= MarkdownStyleCache.synchronousParseCap {
                styleCache.reparse(tv.string)
            } else {
                styleCache.adoptProvisional(tv.string)
                renderStyles()
                parseNow()
                return
            }
        }
        renderStyles()
    }

    /// Applies the cached spans. No parse, ever.
    ///
    /// `forcedFocus` overrides the live first-responder read for callers that
    /// already KNOW the answer and cannot trust a live read at this exact
    /// moment — see `revealForSelectionChange`'s doc comment on why
    /// `resignFirstResponder`'s own callback is exactly such a moment. `nil`
    /// (every other caller) reads live, as before.
    func renderStyles(forcedFocus: Bool? = nil) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let window = styleCache.isOverViewportCap
            ? MarkdownStyleRenderer.viewportWindow(of: tv) : nil
        lastViewportWindow = window
        let theme = MarkdownTheme(tokens: tokens, settings: settings)
        MarkdownStyleRenderer.apply(styleCache.spans, to: storage,
                                    tokens: tokens, theme: theme,
                                    limitedTo: window)
        // Reveal rides the SAME pass as the attributes, and must come after
        // them: `apply` sets fonts over the whole string, so collapsing first
        // would be immediately overwritten.
        //
        // THE ONLY place the index is built, and this runs on a text change or
        // a redraw — never on a caret move. `MarkdownReveal.blocks(in:)` is a
        // scan of the whole string, so calling it from the selection path would
        // put an O(document) cost on every arrow key.
        revealIndex = MarkdownEditorReveal.index(text: tv.string, spans: styleCache.spans)
        revealIndexBuilds += 1
        // Mirrors the `revealIndex` build, from the same spans in the same
        // pass, so the caret path can answer "is the selection inside an
        // embed?" without walking the document — see `embedIndex`.
        rebuildEmbedIndex()
        // Cheap: an early-exit scan that stops at the FIRST strong character,
        // so it costs O(document) only for a document with none anywhere (rare,
        // and no worse than the `revealIndex`/`blockBackgrounds` scans this
        // same pass already does unconditionally). See `documentWritingDirection`'s
        // doc comment for who reads it and why a fresh scan per render is safe.
        documentWritingDirection = EmbedGeometry.strongWritingDirection(of: tv.string)
            ?? .leftToRight
        collapseHiddenMarkers(in: storage, window: window, forcedFocus: forcedFocus)
        // AFTER marker collapsing: an embed's `![[`/`]]` markers are their
        // OWN separate `.marker(of: .wikilink)` spans (fix round 1, see
        // `EmbedRendering.swift`'s doc comment on the chip pill), collapsed
        // by the same machinery as any other marker; the embed span itself
        // covers only the target text. Running `applyEmbeds` after that
        // collapse is what lets it repaint that target range (image or chip)
        // without a marker-collapse pass clobbering it back afterward.
        applyEmbeds(to: storage, window: window)
        // Code panels, quote bars and collapsed list markers are DRAWN, not
        // attributed — see
        // `MarkdownBlockBackgrounds`. Refreshed from the same spans in the
        // same pass, so the decoration can never describe older text than
        // the attributes do. Clipped to the SAME window the attributes were,
        // so a panel is never painted behind text that was left unstyled.
        refreshBlockBackgrounds(in: storage, window: window)
        stylingNotice?.isHidden = !styleCache.isOverHardCap
        stylingNotice?.textColor = NSColor(tokens.accentSecondary)
        // LAST, and only here: what is on screen now, and what produced it.
        // Recorded after every early-return-free path through this method, so
        // the guard in `applyStyles` can never be told a render happened that
        // did not.
        renderedSnapshot = (tv.string, tokens)
    }

    /// `NSTextView`'s first-responder state, read live rather than cached —
    /// a cached copy can go stale the moment focus moves elsewhere.
    ///
    /// A text view with NO window (as in unit tests that build one directly,
    /// never inserting it into a window) has no first-responder concept at
    /// all; treated as focused rather than unfocused, since "no window" is
    /// not the same claim as "lost focus to something else".
    var isTextViewFocused: Bool {
        guard let tv = textView else { return false }
        guard let window = tv.window else { return true }
        return window.firstResponder === tv
    }

    /// Called from `textViewDidChangeSelection` — i.e. on every arrow key.
    ///
    /// Costs, in order of how often each is reached:
    ///
    /// 1. Caret still inside the same block — two binary searches over the
    ///    cached block list and an equality check. No parse, no scan of the
    ///    text, no attribute written. This is nearly every keypress.
    /// 2. Caret crossed a boundary — the blocks that ENTERED and LEFT reveal
    ///    are re-attributed, and nothing else is. Two blocks, from spans
    ///    already bucketed per block, over character ranges bounded by the
    ///    blocks themselves.
    ///
    /// What it deliberately does NOT do is call `renderStyles()`, which is what
    /// the first version of this did. `MarkdownStyleRenderer.apply` clears the
    /// whole document before styling — correct for a text change, ruinous for
    /// an arrow key — and `MarkdownReveal.blocks(in:)` rescans the entire
    /// string. Blocks are blank-line-separated paragraphs, so arrowing down
    /// ordinary prose crosses one every few keypresses; the full path would
    /// have restyled the note each time. Block ranges depend only on the TEXT
    /// and are rebuilt only when the text is rendered.
    /// `forcedFocus`: pass the KNOWN state rather than let this read live
    /// when the caller is invoked from inside `resignFirstResponder` — at
    /// that point `NSWindow` has not yet reassigned `_firstResponder` away
    /// from `tv` (it does so only after `resignFirstResponder` RETURNS), so
    /// a live read of `window.firstResponder === tv` still answers `true`
    /// and this whole focus-changed branch never triggers. A deferred
    /// `DispatchQueue.main.async` read would also see the post-reassignment
    /// value, but passing the already-known answer is simpler and doesn't
    /// leave a frame where the markers are wrong. `nil` (the ordinary
    /// selection-change path) reads live, as before.
    func revealForSelectionChange(forcedFocus: Bool? = nil) {
        // Both writing modes key off the caret, so they ride the SAME
        // selection-change pass the reveal logic already runs rather than
        // adding a second observer of the same event.
        //
        // Before the `revealIndex` guard below: that guard returns early for a
        // document with no reveal blocks (an empty note), and focus dimming
        // still has to clear itself there — otherwise turning the mode off in
        // an empty document leaves nothing to un-dim it.
        applyWritingModes()
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard !revealIndex.blocks.isEmpty else { return }
        // The block list must actually describe the text on screen.
        //
        // AppKit posts `textViewDidChangeSelection` BETWEEN mutating the
        // storage and calling `textDidChange`, so this method can run with
        // `revealIndex.blocks` still describing the PRE-edit string laid over
        // the already-edited one. Restyling then writes a stale block's range:
        // after deleting five characters it re-applied the paragraph's
        // attributes five units past the paragraph's new end, over the start of
        // the list below — which `textDidChange` never corrected, because the
        // edit path restyles the blocks it knows changed and that was not one
        // of them.
        //
        // Returning is safe and complete: the edit that moved the text is on
        // its way to `textDidChange`, which recomputes the blocks and the
        // reveal from scratch. This is only reachable in that window.
        //
        // Previously latent. Block-scoped reveal compared block INDICES, which
        // a mid-paragraph edit usually left unchanged, so the guard below
        // returned early and the stale ranges were never used. A line-scoped
        // reveal moves whenever the caret moves, so it reaches the restyle.
        // Caught by `test_aDeletionAlsoProducesIdenticalAttributes`.
        guard styleCache.describes(tv.string) else { return }
        let selection = tv.selectedRange()
        let focused = forcedFocus ?? isTextViewFocused
        // A focus change does not move the caret, so `now == was` below would
        // otherwise short-circuit an unfocus away as "same selection, nothing
        // to do" and leave the caret's block visibly revealed to a reader who
        // is no longer editing. Route it through the full render instead,
        // which is the only path that knows how to re-hide markers wholesale.
        guard focused == lastRevealFocus else {
            renderStyles(forcedFocus: focused)
            return
        }
        // The CACHED wide spans, not the whole span array: this is the caret
        // path, and scanning every span here is what made an arrow key cost a
        // function of the document's length.
        let now = MarkdownReveal.revealedRange(in: tv.string, selection: selection,
                                               wideSpans: revealIndex.wideSpans,
                                               isFocused: focused)
        let was = revealedRange
        guard now != was else {
            // NOT a block flip — but an embed's reveal is a SPAN-level
            // property, not a block-level one, so the caret can move into or
            // out of an `![[…]]` without any block changing. Checking here,
            // before the early return, is what makes an image embed actually
            // reveal on caret entry instead of staying collapsed (with the
            // caret invisibly inside it) until the next keystroke or the
            // 150 ms debounce — fix round 2, I6. Costs a walk of `embedIndex`,
            // which is empty for the overwhelming majority of documents and
            // tiny for the rest, and does no styling work at all unless the
            // answer changed.
            if revealEmbedsForSelectionChange(in: storage) { tv.needsDisplay = true }
            return
        }
        revealedRange = now

        // Exactly the blocks the reveal moved out of or into. Located by binary
        // search rather than by scanning, so an arrow key costs O(log blocks)
        // to find them and then one restyle each — the O(1)-blocks contract
        // this path has always carried.
        //
        // It is a UNION rather than a symmetric difference now: with a
        // line-scoped reveal the caret can move WITHIN one block (line 1 to
        // line 2 of a paragraph), where the block is in both the old set and
        // the new one and still has to be restyled, because which of its
        // markers are hidden has changed. A symmetric difference would cancel
        // exactly that case out and leave the previous line's syntax showing.
        var changed = MarkdownEditorReveal.blockIndices(touching: was,
                                                        in: revealIndex.blocks)
        changed.formUnion(MarkdownEditorReveal.blockIndices(touching: now,
                                                            in: revealIndex.blocks))
        for block in changed.sorted() {
            restyleBlock(block, revealed: now, in: storage)
        }
        // The blocks just restyled above already re-ran `applyEmbeds`, so this
        // only has to catch embeds in blocks that did NOT flip; it also keeps
        // `revealedEmbedSpans` in step so the next caret move compares against
        // the truth.
        revealEmbedsForSelectionChange(in: storage)
        // The DRAWN decoration is a function of reveal state too — a list
        // marker's substitute is drawn only while the real one is collapsed —
        // and it lives in the gutter, outside the glyph rects an attribute
        // change dirties. Once per boundary crossing, not per keypress.
        tv.needsDisplay = true
    }

    /// Re-attributes ONE block and re-hides its markers if it is not revealed.
    ///
    /// A marker that must REAPPEAR cannot be un-collapsed in place — the font it
    /// should return to is a function of its enclosing spans — so the block is
    /// rebuilt from the cached spans. Still no parse, and still nothing outside
    /// this block is touched.
    func restyleBlock(_ block: Int, revealed: Range<Int>?, in storage: NSTextStorage) {
        guard block >= 0, block < revealIndex.blocks.count else { return }
        restyledBlockCount += 1
        let range = revealIndex.blocks[block]
        let ns = NSRange(location: range.lowerBound, length: range.count)
        MarkdownStyleRenderer.restyle(styleCache.spans,
                                      at: revealIndex.spansByBlock[block],
                                      depths: revealIndex.depths,
                                      in: ns, to: storage,
                                      tokens: tokens,
                                      theme: MarkdownTheme(tokens: tokens, settings: settings))
        // Re-run RIGHT AFTER `restyle`, scoped to this one block, so an
        // embed's collapse/paragraph-style/drawn-image never has a frame
        // where it looks wrong. `restyle` above just reset this block's
        // attributes to the plain-span defaults — including popping any
        // collapsed embed image back to full-size, editable source text —
        // and applying embeds here immediately restores (or, if the caret
        // just entered the block, deliberately withholds) that decoration
        // before this method returns. Fixed in Task 8 fix round 1, Critical
        // 2: without this call an image embed visibly popped back to raw
        // text and a NOW-STALE `EmbedImageRegion` kept painting at the wrong
        // rect until the next full render. See `applyEmbeds`'s doc comment
        // for why this costs a cache hit, not a decode, and does not reopen
        // the O(1)-blocks caret contract.
        // `spanIndices` is what keeps this O(spans in THIS block) rather than
        // O(spans in the document) — fix round 2, NEW-1. It is the same
        // bucketed list `MarkdownStyleRenderer.restyle` just consumed, so the
        // two cannot disagree about which spans belong to this block.
        applyEmbeds(to: storage, window: nil, restrictTo: ns,
                    spanIndices: revealIndex.spansByBlock[block])
        // Per MARKER rather than per block. The block is the unit that gets
        // re-attributed; which of its markers are hidden is now a line-scoped
        // question, so a block can be half revealed — the caret's line showing
        // its syntax while the rest of the paragraph stays rendered. That is
        // the whole point of the change.
        let hidden = revealIndex.spansByBlock[block].compactMap { index -> Range<Int>? in
            guard index < styleCache.spans.count,
                  case .marker = styleCache.spans[index].kind else { return nil }
            let range = styleCache.spans[index].range
            return MarkdownReveal.isRevealed(range, in: revealed) ? nil : range
        }
        let blockSpans = revealIndex.spansByBlock[block].compactMap {
            $0 < styleCache.spans.count ? styleCache.spans[$0] : nil
        }
        // The same two-pass ordering as the full render — see its comment. Only
        // when this block holds a table: a caret move into one changes every
        // row's reserved height, but that is rare, and re-measuring on every
        // arrow key would put an O(document) cost back on the path that exists
        // not to have one.
        let holdsTable = blockSpans.contains {
            if case .table = $0.kind { return true }
            return false
        }
        if let tv = textView, holdsTable {
            let rowMarkers = MarkdownTableStyling.rowMarkerRanges(styleCache.spans)
            MarkdownStyleRenderer.collapse(hidden.filter { !rowMarkers.contains($0) },
                                           in: storage)
            tableRegions = MarkdownTableStyling.prepare(styleCache.spans,
                                                        revealed: revealed,
                                                        maxWidth: textColumnWidth(of: tv),
                                                        in: storage)
            MarkdownStyleRenderer.collapse(hidden.filter { rowMarkers.contains($0) },
                                           in: storage)
            refreshBlockBackgrounds(in: storage, window: nil)
        } else if !hidden.isEmpty {
            MarkdownStyleRenderer.collapse(hidden, in: storage)
        }
        // Unconditional, unlike the collapse above: a row that just became
        // REVEALED hides nothing and still has to lose its padding, which is
        // this same call reaching the opposite answer.
        MarkdownMathStyling.reserveSpace(blockSpans, revealed: revealed,
                                         font: MarkdownStyleRenderer.baseFont,
                                         in: storage)
    }

    // Container geometry and the off-actor parse pipeline (the debounce,
    // `parseNow`, viewport restyling) live in `MarkdownEditorParsing.swift`.
}
