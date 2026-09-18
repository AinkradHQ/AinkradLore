import AppKit
import SwiftUI
import AinkradAppKit

/// The EDIT path: what a keystroke costs, and the guard that stops a redraw
/// from paying for it twice.
///
/// Split out of `MarkdownEditor.swift` (AppKit wiring) and
/// `MarkdownEditorReveal.swift` (the caret path) because it is neither, and
/// because both of those files are at their length limit. What lives here is
/// the answer to M5 Task 10's measurement: typing re-rendered the whole
/// document, once from `textDidChange` and again from SwiftUI's `updateNSView`.
///
/// Two changes, in the order they were measured:
///
/// 1. `isRenderStale` — a redraw whose inputs are all unchanged does nothing.
/// 2. `renderStylesForEdit` — an edit re-attributes only the block it landed
///    in, or refuses and lets the caller do the whole document.
///
/// The counters (`applyStylesCalls`, `revealIndexBuilds`,
/// `lastEditTookFastPath`) exist so both claims are asserted rather than
/// argued: see `MarkdownEditorRedrawTests`, `MarkdownEditFastPathTests` and
/// `MarkdownTypingLagBenchmark`.
extension MarkdownEditor.Coordinator {
    // MARK: - Text

    /// Records WHERE the edit is about to happen, so `textDidChange` can
    /// shift the cached spans instead of re-parsing. Never vetoes an edit.
    ///
    /// A nil `replacementString` is an attributes-only change: there is no
    /// delta to shift by, so the cache is left to notice the mismatch.
    public func textView(_ tv: NSTextView, shouldChangeTextIn affected: NSRange,
                         replacementString: String?) -> Bool {
        // `tv.string` is still the PRE-edit text here, which is the only
        // moment the cache's currency can be checked against it. Spans that
        // did not describe the text before the edit cannot be shifted into
        // describing it after.
        //
        // It is also the only moment BOTH halves of the edit are readable —
        // what is going in, and what is coming out — which is what
        // `MarkdownEditorReveal`'s single-block fast path needs to decide
        // whether the edit can possibly have moved a block boundary. Once
        // `textDidChange` fires, the removed text is gone.
        pendingEdit = styleCache.describes(tv.string)
            ? replacementString.map {
                PendingEdit(range: affected, replacementLength: ($0 as NSString).length,
                            touchesBlockStructure:
                                Self.disturbsStructure($0)
                                || Self.disturbsStructure(removed: affected, from: tv.string))
              }
            : nil
        return true
    }

    /// The text `affected` is about to REMOVE, tested for structure characters.
    ///
    /// `affected` arrives from AppKit — a system boundary — and
    /// `NSString.substring(with:)` traps on an out-of-bounds range. Every
    /// in-repo caller passes a range computed against this very string, so this
    /// is not reachable today; it is nonetheless the keystroke path, where a
    /// trap is a crash in the user's editor mid-sentence, and validating input
    /// at a boundary is cheaper than being sure about every future caller.
    ///
    /// An out-of-bounds range answers `true` — "this edit disturbs structure" —
    /// which bars the fast path and takes the full render. The conservative
    /// direction: a redundant whole-document render is the behaviour that
    /// shipped for years, and it cannot be wrong about anything.
    private static func disturbsStructure(removed affected: NSRange,
                                          from text: String) -> Bool {
        let ns = text as NSString
        guard affected.location >= 0, affected.length >= 0,
              NSMaxRange(affected) <= ns.length else { return true }
        return disturbsStructure(ns.substring(with: affected))
    }

    /// What `shouldChangeTextIn` recorded, for `textDidChange` to consume.
    struct PendingEdit {
        let range: NSRange
        let replacementLength: Int
        /// Whether this half of the edit contains a character that could
        /// re-segment the document or re-scope a multi-line span, and so
        /// bars the single-block fast path. See `disturbsStructure`.
        let touchesBlockStructure: Bool
    }

    /// Characters whose arrival or departure can change something no
    /// single-block re-attribution could cover.
    ///
    /// - line terminators move block boundaries outright
    ///   (`MarkdownReveal.blocks` splits on blank lines);
    /// - a backtick or tilde can open or close a FENCE, whose span reaches
    ///   past every block between its ends.
    ///
    /// Applied to both the inserted and the removed text, because either
    /// direction changes the same things. Deliberately a character test
    /// rather than an analysis: it costs a scan of a one-character string
    /// on the hot path, it is impossible to get subtly wrong, and every
    /// false positive merely takes the full render that used to be
    /// unconditional.
    static func disturbsStructure(_ text: String) -> Bool {
        text.utf16.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0x60 || $0 == 0x7E }
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        text.wrappedValue = tv.string
        if let edit = pendingEdit {
            styleCache.shift(editedRange: edit.range,
                             delta: edit.replacementLength - edit.range.length,
                             newText: tv.string)
        }
        let edit = pendingEdit
        pendingEdit = nil
        // `renderStylesForEdit` re-parses and re-attributes only the block the
        // edit landed in, and returns false — falling back to the full,
        // whole-document render this used to do unconditionally — whenever
        // it cannot PROVE that is equivalent. See its doc comment for the
        // list of things it refuses to be clever about.
        //
        // The spans OUTSIDE that block are the shifted ones: right position,
        // possibly wrong kind, settled by the debounced parse a moment later.
        // Inside it they are freshly parsed, which is what lets syntax style
        // itself on the keystroke that finishes it rather than on the pause
        // afterwards.
        let handled = edit.map { renderStylesForEdit($0) } ?? false
        lastEditTookFastPath = handled
        if !handled { renderStyles() }
        scheduleParse()
        // The ONE place `completions` is called: a keystroke happened.
        refreshCompletions()
    }

    // MARK: - The redundant-redraw guard

    /// Whether what is on screen could differ from what a render would now
    /// produce.
    ///
    /// MEASURED, not assumed: a hosted editor runs `applyStyles()` exactly once
    /// per keystroke (`MarkdownEditorRedrawTests`), because `textDidChange`
    /// writes `text.wrappedValue` and SwiftUI then re-runs `updateNSView`,
    /// which calls it unconditionally. Together with `textDidChange`'s own
    /// render that was TWO full-document renders per typed character, the
    /// second recomputing byte for byte what the first had just written.
    ///
    /// Skipping is safe exactly when all three of a render's inputs are
    /// unchanged since the last one: the SPANS (identified by the string they
    /// describe), the TOKENS (every colour and font comes from them), and — in
    /// viewport mode only — the styled WINDOW, which follows the scroll.
    /// Selection and focus are deliberately NOT in that list, and that is a
    /// contract rather than an oversight: reveal is maintained incrementally by
    /// `revealForSelectionChange` (and by `renderStylesForEdit` for an edit),
    /// both of which re-attribute the affected blocks themselves and neither of
    /// which routes through here. If a future caller ever changes reveal state
    /// WITHOUT re-attributing — a new focus path, say — it must call
    /// `renderStyles()` directly rather than expect `applyStyles()` to notice,
    /// because by this guard's rule nothing about the document changed. Conservative in the only direction that matters: every answer
    /// it is not certain about is `true`, which costs a redundant render — the
    /// status quo — rather than showing stale attributes.
    func isRenderStale(for tv: NSTextView) -> Bool {
        guard let rendered = renderedSnapshot else { return true }
        guard rendered.tokens == tokens else { return true }
        // The spans on screen came from THIS string, and the cache still
        // describes it. Two O(n) string compares against a render that is
        // O(n) in the same n with a far larger constant — `apply` alone was
        // 52 ms where the compares are microseconds.
        guard rendered.text == tv.string, styleCache.describes(tv.string) else { return true }
        // Viewport mode styles a moving window, so an unchanged document can
        // still need re-styling after a scroll. (`restyleForViewportIfNeeded`
        // is the usual driver; this keeps the guard from swallowing the case
        // where a redraw arrives first.)
        if styleCache.isOverViewportCap {
            guard let last = lastViewportWindow,
                  NSEqualRanges(last, MarkdownStyleRenderer.viewportWindow(of: tv))
            else { return true }
        }
        return false
    }


    // MARK: - The single-block edit path

    /// Re-attributes ONLY the block the edit landed in, and returns whether it
    /// did. `false` means "I could not prove this was equivalent to a full
    /// render" and the caller must run `renderStyles()`.
    ///
    /// WHY. `renderStyles()` is O(document) in six places, and `textDidChange`
    /// called it per typed character: MEASURED at 9 ms per render on a
    /// 500-line note and 92 ms on a 5,000-line one, of which
    /// `MarkdownStyleRenderer.apply` — a full-range `setAttributes` plus a walk
    /// of every span in the document — is ~60%. A one-character edit can only
    /// change the attributes of ONE block; a 2,000-line note has 728. The caret
    /// path has re-attributed exactly the blocks that changed since M5 Task 8
    /// (`restyleBlock`, asserted by
    /// `test_arrowingThroughALargeDocumentReAttributesOnlyTwoBlocks`); this
    /// gives the EDIT path the same treatment, through the same machinery
    /// rather than a second implementation of it.
    ///
    /// CORRECTNESS. The bar is byte-identical attributes, not "close enough" —
    /// see `MarkdownEditFastPathTests`, which asserts exactly that against a
    /// full render for a range of realistic edits. Everything this needs is
    /// therefore CHECKED rather than argued:
    ///
    /// 1. The cache was current before the edit and shifted cleanly — the
    ///    caller only gets here with a `PendingEdit`, which is `nil` otherwise.
    /// 2. (Retired.) This used to require that `shift` DROPPED no span —
    ///    a deletion can collapse one, which silently re-indexed every bucket
    ///    in `revealIndex.spansByBlock`, and the buckets were carried over.
    ///    They are now REBUILT from the spliced spans, and check 5 is read off
    ///    the spans rather than off the buckets, so nothing depends on the
    ///    count being stable. Retiring it matters to the user rather than to
    ///    the arithmetic: deleting the `*` that closed an emphasis run collapses
    ///    a marker span, so every un-styling edit — the whole delete direction —
    ///    used to fall back to a render that does not re-parse either, and the
    ///    word stayed italic until the debounce.
    /// 3. The edit contains no line terminator and no fence character, in
    ///    EITHER direction — see `Coordinator.disturbsStructure`.
    /// 4. The recomputed block segmentation equals the old one moved by the
    ///    edit's delta. This is the load-bearing check, and the reason 3 can
    ///    afford to be a crude character test: rather than reasoning about
    ///    which edits can re-segment a document, the segmentation is simply
    ///    recomputed (a character scan — 1.5 ms on the 5,000-line fixture,
    ///    against the 92 ms it avoids) and required to match. Anything that
    ///    moved a boundary, for any reason anyone thought of or did not, fails
    ///    here and takes the full render.
    /// 5. No span overlaps the edited block without being bucketed INTO it.
    ///    This is exactly `restyleBlock`'s stated precondition ("nothing they
    ///    style can reach past the block's ends"), which a fenced code block
    ///    containing a blank line violates — its span starts in one block and
    ///    covers several. Restyling a later one would clear its code styling
    ///    and have no span left to restore it.
    /// 6. The document is under the viewport cap, so the render is not
    ///    windowed. Above it, styling follows the scroll and a block-scoped
    ///    update cannot maintain that.
    /// 7. The document contains no link reference definition — the one
    ///    construct that makes a block's styling depend on text outside it, and
    ///    so the one thing that stops the block from being parsable alone. See
    ///    `MarkdownStyleCache.hasReferenceDefinitions`.
    ///
    /// WHAT IT PARSES. Exactly one block, via `MarkdownStyleCache.deriveBlock`.
    /// This method originally parsed NOTHING, which is what made it fast and
    /// also what made it wrong to look at: shifted spans are the right shape in
    /// the right place with the WRONG KINDS, so markdown you had just finished
    /// typing stayed unstyled until the debounce fired after you stopped. The
    /// block parse is what the checks above buy — having proven the edit cannot
    /// have changed the meaning of anything outside this block, re-reading this
    /// block is both sufficient and cheap.
    ///
    /// What the fast path still does in full, because each is cheap and each is
    /// a whole-document fact: the block list, list depths, the embed index, the
    /// writing direction, and the drawn block backgrounds — whose regions are
    /// derived from span POSITIONS and would otherwise be left painting code
    /// panels at pre-edit offsets.
    ///
    /// And when this is wrong anyway, the 150 ms debounced parse lands a full,
    /// correct render on top: a mis-styled frame, never a mis-styled document.
    /// That is a safety net, not the argument — the checks above are.
    func renderStylesForEdit(_ edit: MarkdownEditor.Coordinator.PendingEdit) -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        // 3, 6.
        guard !edit.touchesBlockStructure else { return false }
        guard !styleCache.isOverViewportCap, !styleCache.isOverHardCap else { return false }
        // Nothing rendered yet — there is no previous picture to patch.
        guard renderedSnapshot != nil, !revealIndex.blocks.isEmpty else { return false }

        // 4. The old segmentation, moved by this edit, must be what the text
        // now actually segments into.
        let delta = edit.replacementLength - edit.range.length
        let limit = (tv.string as NSString).length
        let shifted = revealIndex.blocks.map { block in
            movedOffset(block.lowerBound, start: edit.range.location, delta: delta, limit: limit)
                ..< movedOffset(block.upperBound, start: edit.range.location,
                                delta: delta, limit: limit)
        }
        let fresh = MarkdownReveal.blocks(in: tv.string)
        guard shifted == fresh else { return false }

        guard let block = MarkdownEditorReveal.blockIndex(of: edit.range.location, in: fresh)
        else { return false }
        let blockRange = fresh[block]

        // 5. Every span that TOUCHES this block must lie wholly INSIDE it.
        //
        // Stated as containment rather than as bucket membership, which is what
        // it used to be. The two are equivalent — a span contained in the block
        // starts in the block, which is exactly what bucketing means — and
        // containment is the property step 7 actually needs: it replaces this
        // block's spans outright, so a span reaching past the block's ends
        // would lose its styling in a block nothing is about to re-attribute.
        // (`test_bails_whenAFenceSpansMultipleBlocks` is the case: a fence with
        // a blank line inside it. Reading the property off the spans instead of
        // off the buckets is also what lets check 2 go — see below.)
        var existing: [StyleSpan] = []
        for span in styleCache.spans
        where span.range.lowerBound < blockRange.upperBound
            && span.range.upperBound > blockRange.lowerBound {
            guard span.range.lowerBound >= blockRange.lowerBound,
                  span.range.upperBound <= blockRange.upperBound else { return false }
            existing.append(span)
        }

        // 7. Re-parse THIS BLOCK, so the markdown the user just typed is styled
        // on the keystroke that completed it.
        //
        // Everything above this line was already true, and the path was still
        // showing stale KINDS: `styleCache.shift` moves spans without re-reading
        // them, so typing `**bold**` left plain text on screen until the 150 ms
        // debounce fired — after the user stopped typing. That is the "renders
        // on key-up" defect. A whole-document parse here is not affordable
        // (9 ms on a 500-line note, 92 ms on a 5,000-line one, per character);
        // parsing the one block the caret is in is O(block) — microseconds for
        // an ordinary paragraph — and is the only part of the document whose
        // meaning this edit can have changed, which checks 3 and 4 have already
        // proven.
        //
        // A link reference definition is the one thing that would make that
        // false, because it gives a block a meaning that is written elsewhere.
        // Refuse rather than reason about it; see `hasReferenceDefinitions`.
        // A link reference definition gives a block a meaning written elsewhere,
        // so a block that could USE one cannot be parsed alone. That is a
        // property of the block, not of the document.
        //
        // This used to refuse whenever the document held a definition ANYWHERE,
        // which is how Ahmed's "styling lands late" came back on 2026-08-17: a
        // footnote (`[^1]: …`) has the shape of a definition, and one footnote
        // in a note disabled the block parse for every paragraph in it — every
        // keystroke, straight back to shifted spans. A block with no `[` in it
        // cannot contain a reference link of any kind, so the far narrower
        // question is the right one to ask.
        guard !(styleCache.hasReferenceDefinitions && blockContainsBracket(blockRange, in: tv))
        else { return false }
        guard let blockSpans = MarkdownStyleCache.deriveBlock(of: tv.string, range: blockRange)
        else { return false }

        // Proven. Everything below is the full render's whole-document
        // bookkeeping — all of it cheap — with the ONE expensive step,
        // re-attributing the document, narrowed to the block that changed.
        //
        // The splice is skipped outright when the parse agrees with the spans
        // already there, which is the ordinary case: typing a letter into a
        // paragraph changes where that paragraph's span ENDS, and `shift`
        // already moved it there. Worth a comparison because the splice is not
        // free — it re-indexes every span position after this block, so the
        // buckets have to be rebuilt, and that is O(spans in the DOCUMENT).
        // Measured: rebuilding unconditionally cost +5.8 ms per keystroke on
        // the 5,000-line fixture, which is most of a frame spent discovering
        // that nothing changed. When the parse DOES disagree — the keystroke
        // that closed a `**bold**`, the one that deleted its closing marker —
        // the rebuild is exactly the work that puts the new styling on screen,
        // and it is paid on that keystroke alone.
        if existing != blockSpans {
            styleCache.spliceBlock(blockRange, with: blockSpans)
            // Wide spans INCREMENTALLY, never by rescanning the document.
            // `MarkdownReveal.wideSpans` runs `rangeOfCharacter` per single-pair
            // span and MEASURED 3.75 ms over the 5,000-line fixture — a whole
            // frame, on the keystroke path, to rediscover facts about blocks
            // the edit could not have touched.
            //
            // Only the edited block's spans were replaced, so only its wide
            // spans can differ. The rest are shifted, exactly as the
            // non-splice branch shifts them and by the same rule.
            let limit = (tv.string as NSString).length
            let outside = revealIndex.wideSpans.compactMap { span -> Range<Int>? in
                let moved = movedOffset(span.lowerBound, start: edit.range.location,
                                        delta: delta, limit: limit)
                    ..< movedOffset(span.upperBound, start: edit.range.location,
                                    delta: delta, limit: limit)
                // Dropped if it belongs to the block just respliced; that
                // block's wide spans are recomputed from its fresh parse below.
                guard moved.lowerBound < blockRange.lowerBound
                        || moved.lowerBound >= blockRange.upperBound else { return nil }
                return moved.lowerBound < moved.upperBound ? moved : nil
            }
            revealIndex = MarkdownEditorReveal.index(
                blocks: fresh, spans: styleCache.spans,
                wideSpans: outside + MarkdownReveal.wideSpans(in: tv.string,
                                                              spans: blockSpans))
        } else {
            // The buckets and the wide spans are both carried over, but for
            // different reasons. The buckets describe POSITIONS in the span
            // array, which the splice did not change. The wide spans describe
            // OFFSETS, which the edit did move — so they are shifted by the
            // same rule `MarkdownStyleCache.shift` applies to the spans they
            // came from, rather than recomputed, which would put an O(spans)
            // scan back on the keystroke.
            //
            // Sound because check 3 already barred this edit from containing a
            // line terminator or a fence character in either direction: it
            // cannot have made a span cross a line, or stop crossing one, so
            // the SET is unchanged and only its offsets move.
            let limit = (tv.string as NSString).length
            revealIndex = MarkdownEditorReveal.Index(
                blocks: fresh, spansByBlock: revealIndex.spansByBlock,
                depths: MarkdownListDepth.depths(of: styleCache.spans),
                wideSpans: revealIndex.wideSpans.map { span in
                    movedOffset(span.lowerBound, start: edit.range.location,
                                delta: delta, limit: limit)
                        ..< movedOffset(span.upperBound, start: edit.range.location,
                                        delta: delta, limit: limit)
                })
        }
        revealIndexBuilds += 1
        rebuildEmbedIndex()
        documentWritingDirection = EmbedGeometry.strongWritingDirection(of: tv.string)
            ?? .leftToRight
        // Reveal, computed the way a FULL render computes it — from the live
        // selection and focus against the fresh blocks — rather than read from
        // `revealedRange`. That field is maintained by the caret path,
        // and during an edit AppKit posts its selection change against the
        // PRE-edit block list, so trusting it here collapsed the markers of the
        // very block being typed in: the first version of this method showed
        // `**bold**` with its asterisks hidden while the caret sat inside them,
        // which the equivalence test caught immediately.
        let focused = isTextViewFocused
        let was = revealedRange
        let now = MarkdownReveal.revealedRange(in: tv.string,
                                               selection: tv.selectedRange(),
                                               wideSpans: revealIndex.wideSpans,
                                               isFocused: focused)
        lastRevealFocus = focused
        revealedRange = now
        // The block that changed, plus every block the reveal moved out of or
        // into — the same union the caret path takes, and for the same reason:
        // a line-scoped reveal can move within one block. Block COUNT is
        // unchanged (checked above), so indices from before the edit are still
        // comparable with these.
        var toRestyle = MarkdownEditorReveal.blockIndices(touching: was, in: fresh)
        toRestyle.formUnion(MarkdownEditorReveal.blockIndices(touching: now, in: fresh))
        toRestyle.insert(block)
        for index in toRestyle.sorted() {
            restyleBlock(index, revealed: now, in: storage)
        }
        // Keeps `revealedEmbedSpans` in step, exactly as the caret path does,
        // so the next caret move compares against the truth.
        revealEmbedsForSelectionChange(in: storage)
        // A table's rows reserve their drawn heights, so an edit inside one has
        // to re-measure the grid before the decoration is rebuilt from it.
        if styleCache.spans.contains(where: { if case .table = $0.kind { return true }
                                              return false }) {
            tableRegions = MarkdownTableStyling.prepare(styleCache.spans,
                                                        revealed: revealedRange,
                                                        maxWidth: textColumnWidth(of: tv),
                                                        in: storage)
        }
        refreshBlockBackgrounds(in: storage, window: nil)
        stylingNotice?.isHidden = !styleCache.isOverHardCap
        stylingNotice?.textColor = NSColor(tokens.accentSecondary)
        renderedSnapshot = (tv.string, tokens)
        // The drawn decoration — code panels, quote bars, substituted list
        // markers — lives in the gutter, outside the glyph rects an attribute
        // change dirties, so it has to be asked for explicitly.
        tv.needsDisplay = true
        return true
    }

    /// Whether this block contains a `[`, and so could hold a reference link
    /// whose meaning lives in a definition elsewhere.
    ///
    /// A character scan of ONE block, on the keystroke path — cheap, and the
    /// answer is almost always no, which is what restores the fast path for
    /// ordinary prose in a note that happens to carry footnotes.
    func blockContainsBracket(_ block: Range<Int>, in tv: NSTextView) -> Bool {
        let ns = tv.string as NSString
        guard block.lowerBound >= 0, block.upperBound <= ns.length else { return true }
        for offset in block.lowerBound..<block.upperBound
        where ns.character(at: offset) == 0x5B { return true }
        return false
    }

    /// `MarkdownStyleCache.shift`'s offset rule, applied to block bounds.
    ///
    /// Deliberately the SAME rule, not a similar one: blocks and spans have to
    /// move together or the buckets stop describing the blocks they index. An
    /// offset at or before the edit stays put; one after it moves by the delta.
    func movedOffset(_ offset: Int, start: Int, delta: Int, limit: Int) -> Int {
        guard offset > start else { return min(offset, limit) }
        return min(max(start, offset + delta), limit)
    }
}
