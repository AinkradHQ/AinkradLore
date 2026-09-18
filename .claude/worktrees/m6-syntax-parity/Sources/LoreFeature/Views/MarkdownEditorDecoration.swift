import AppKit
import SwiftUI
import AinkradAppKit

/// What is HIDDEN, and what is DRAWN over the gap it leaves.
///
/// Split out of `MarkdownEditorReveal.swift` at the 500-line ceiling, and by
/// subject rather than by count: that file decides which blocks are revealed,
/// this one carries out the consequence — collapsing the markers of everything
/// that is not, and assembling the decoration that stands in for them.
///
/// The two-pass collapse lives here, and the ordering is the reason a drawn
/// table renders correctly. See `collapseHiddenMarkers`.
extension MarkdownEditor.Coordinator {

    /// Hides the markers of every block the selection is NOT in, and records
    /// the reveal state that `revealForSelectionChange` compares against.
    ///
    /// The whole-document version, run only as part of a full render. See
    /// `renderStyles`'s doc comment for `forcedFocus`.
    /// Internal rather than `private` since the render path moved to another
    /// file for the length ceiling, and Swift's `private` is file-scoped. Still
    /// an implementation detail outside this module.
    func collapseHiddenMarkers(in storage: NSTextStorage, window: NSRange?,
                                       forcedFocus: Bool? = nil) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        let focused = forcedFocus ?? isTextViewFocused
        lastRevealFocus = focused
        revealedRange = MarkdownReveal.revealedRange(in: tv.string, selection: selection,
                                                     spans: styleCache.spans,
                                                     isFocused: focused)
        var hidden = MarkdownReveal.hiddenMarkers(spans: styleCache.spans,
                                                  selection: selection,
                                                  text: tv.string,
                                                  isFocused: focused)
        if let window {
            hidden = hidden.filter {
                $0.lowerBound < NSMaxRange(window) && $0.upperBound > window.location
            }
        }
        // The collapse happens in TWO passes, either side of the table capture,
        // and the order is the whole reason a cell renders correctly.
        //
        // `prepare` captures each cell's ATTRIBUTED text to draw later. Capture
        // too late — after the rows collapse — and the grid draws at 0.01 pt.
        // Capture too early — before the INLINE markers collapse — and a cell
        // reading `**1 — unblock**` keeps its asterisks in the drawn grid,
        // which is what Ahmed photographed on 2026-08-17 (image 13).
        //
        // So: hide everything except the table rows, capture the cells as the
        // reader will see them, then hide the rows themselves.
        let rowMarkers = MarkdownTableStyling.rowMarkerRanges(styleCache.spans)
        MarkdownStyleRenderer.collapse(hidden.filter { !rowMarkers.contains($0) },
                                       in: storage)
        tableRegions = MarkdownTableStyling.prepare(styleCache.spans,
                                                    revealed: revealedRange,
                                                    maxWidth: textColumnWidth(of: tv),
                                                    in: storage)
        MarkdownStyleRenderer.collapse(hidden.filter { rowMarkers.contains($0) },
                                       in: storage)
        MarkdownMathStyling.reserveSpace(styleCache.spans, revealed: revealedRange,
                                         font: MarkdownStyleRenderer.baseFont,
                                         in: storage)
    }

    /// Assembles every drawn decoration in one place, so the panels, the
    /// substituted markers, the maths and the tables can never be built from
    /// different passes over different spans.
    func refreshBlockBackgrounds(in storage: NSTextStorage, window: NSRange?) {
        guard let linkView = textView as? LinkTextView else { return }
        linkView.blockBackgroundPalette = MarkdownBlockBackgrounds.Palette(tokens: tokens)
        linkView.blockBackgrounds =
            MarkdownBlockBackgrounds.regions(for: styleCache.spans,
                                             length: storage.length,
                                             limitedTo: window,
                                             in: storage.string as NSString)
            + MarkdownMathStyling.regions(for: styleCache.spans,
                                          font: MarkdownStyleRenderer.baseFont,
                                          in: storage.string as NSString)
            + tableRegions
    }

    /// The width a line of text actually has, which is what decides whether a
    /// table can be aligned into columns.
    func textColumnWidth(of tv: NSTextView) -> CGFloat {
        let width = tv.textContainer?.size.width ?? 0
        return width > 0 ? width : .greatestFiniteMagnitude
    }
}
