import AinkradAppKit
import AppKit
import SwiftUI

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
    public func textView(
        _ tv: NSTextView, shouldChangeTextIn affected: NSRange,
        replacementString: String?
    ) -> Bool {
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
        pendingEdit =
            styleCache.describes(tv.string)
            ? replacementString.map {
                PendingEdit(
                    range: affected, replacementLength: ($0 as NSString).length,
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
    private static func disturbsStructure(
        removed affected: NSRange,
        from text: String
    ) -> Bool {
        let ns = text as NSString
        guard affected.location >= 0, affected.length >= 0,
            NSMaxRange(affected) <= ns.length
        else { return true }
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
            styleCache.shift(
                editedRange: edit.range,
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
}
