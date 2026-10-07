import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownBlockBackgrounds {
    /// The left edge of the text column, in the text view's own coordinates.
    ///
    /// `textContainerOrigin` and nothing else. The rects this decoration is
    /// drawn against come from the LAYOUT, in container coordinates, and are
    /// offset by that same origin — so taking the panel's x from
    /// `textContainerInset.width` instead was a second coordinate source that
    /// happened to agree only while the column was not centred. Once
    /// `MarkdownEditorLayout` centres a capped column the two part company and
    /// every panel and bar detaches from its text.
    @MainActor
    static func columnX(in textView: NSTextView) -> CGFloat {
        textView.textContainerOrigin.x
    }

    /// The width of the text column — the container's, not the view's.
    ///
    /// A code panel is full width OF THE COLUMN. Using the view's bounds would
    /// make it overhang the text on a wide window by exactly the amount the
    /// measure cap took away.
    @MainActor
    static func columnWidth(in textView: NSTextView) -> CGFloat {
        if let container = textView.textContainer, container.size.width > 0 {
            return container.size.width
        }
        return max(0, textView.bounds.width - columnX(in: textView) * 2)
    }
    /// The union of the line rects `range` occupies, in TEXT CONTAINER
    /// coordinates, or a null rect if it occupies none.
    ///
    /// TextKit 2 first and by preference. Reading `NSTextView.layoutManager`
    /// on a TextKit 2 view silently downgrades the whole view to TextKit 1 —
    /// the same trap `MarkdownStyleRenderer.viewportWindow(of:)` documents — so
    /// that property is touched ONLY when `textLayoutManager` is already nil,
    /// which means the view is TextKit 1 and there is nothing left to downgrade.
    @MainActor
    /// Internal rather than private since `MarkdownMathStyling` places a drawn
    /// expression from the same rect this returns — one source of geometry, so
    /// the decoration and the text cannot disagree about where a run is.
    static func boundingRect(of range: NSRange, in textView: NSTextView) -> NSRect {
        if let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        {
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length),
                let textRange = NSTextRange(location: start, end: end)
            else { return .null }
            var union = NSRect.null
            // No `ensureLayout(for:)`. Forcing layout from inside
            // `drawBackground(in:)` is a reentrancy hazard — drawing asks the
            // layout manager to change the thing being drawn — and it ran once
            // per region per draw, over ranges that were not clipped to the
            // viewport. Nothing is lost by dropping it: this is only ever
            // called while the visible text is being drawn, and text that is
            // being drawn is by definition laid out. A region that is entirely
            // off screen enumerates no segments, returns a null rect, and is
            // skipped — which is the desired outcome, reached without the work.
            layout.enumerateTextSegments(
                in: textRange, type: .standard,
                options: []
            ) { _, frame, _, _ in
                if !frame.isEmpty { union = union.union(frame) }
                return true
            }
            return union
        }
        guard let manager = textView.layoutManager,
            let container = textView.textContainer
        else { return .null }
        let glyphs = manager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .null }
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// The rect of each LINE FRAGMENT `range` occupies, in text container
    /// coordinates.
    ///
    /// `boundingRect` unions them, which is right for a block panel and wrong
    /// for anything that must not paint the space between two lines. Same
    /// TextKit 2 preference and the same reason: reading `layoutManager` on a
    /// TextKit 2 view downgrades it.
    @MainActor
    static func lineRects(of range: NSRange, in textView: NSTextView) -> [NSRect] {
        if let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        {
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length),
                let textRange = NSTextRange(location: start, end: end)
            else { return [] }
            var rects: [NSRect] = []
            layout.enumerateTextSegments(
                in: textRange, type: .standard,
                options: []
            ) { _, frame, _, _ in
                if !frame.isEmpty { rects.append(frame) }
                return true
            }
            return merged(rects)
        }
        guard let manager = textView.layoutManager,
            let container = textView.textContainer
        else { return [] }
        var rects: [NSRect] = []
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
            let intersection = NSIntersectionRange(lineGlyphs, glyphs)
            guard intersection.length > 0 else { return }
            var rect = manager.boundingRect(forGlyphRange: intersection, in: container)
            rect.origin.y = used.origin.y
            rect.size.height = used.size.height
            rects.append(rect)
        }
        return rects
    }

    /// Joins segments that share a line, so one pill is drawn per line rather
    /// than one per style run. TextKit 2 reports a segment per run, and inline
    /// code containing a collapsed marker is several runs.
    private static func merged(_ rects: [NSRect]) -> [NSRect] {
        var out: [NSRect] = []
        for rect in rects.sorted(by: { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }) {
            if let last = out.last, abs(last.minY - rect.minY) < 0.5 {
                out[out.count - 1] = last.union(rect)
            } else {
                out.append(rect)
            }
        }
        return out
    }

    /// Whether a callout's icon and heading should be drawn: only while its
    /// `[!type]` declaration is collapsed.
    ///
    /// A zero-length marker (a callout whose header could not be re-read)
    /// answers `true`, which keeps the heading — the same direction every
    /// other guard in this file takes when it is unsure.
    @MainActor
    static func drawsCalloutHeader(marker: NSRange, in textView: NSTextView) -> Bool {
        guard marker.length > 0 else { return true }
        let rect = boundingRect(of: marker, in: textView)
        guard !rect.isNull else { return true }
        return rect.width < collapsedMarkerWidth
    }
}
