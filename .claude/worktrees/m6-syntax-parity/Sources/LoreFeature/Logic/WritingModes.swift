import Foundation

/// The arithmetic behind focus mode and typewriter scrolling.
///
/// Pure, so the two questions that actually matter — "which run of text is the
/// caret's paragraph" and "where should the caret sit on screen" — are asserted
/// without a text view, a window, or a running app.
enum WritingModes {

    /// The paragraph containing `caret`, as a UTF-16 range.
    ///
    /// A PARAGRAPH, not a line: a wrapped sentence is one paragraph and dimming
    /// it by visual line would fade half of what the writer is looking at. The
    /// boundaries are blank lines, matching how markdown itself separates
    /// blocks, so the focused run is the block being written.
    ///
    /// Clamped, and safe on empty text: a caret past the end (a stale
    /// selection after an edit) yields the last paragraph rather than a range
    /// that would crash `addAttribute`.
    static func paragraphRange(in text: String, caret: Int) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let position = min(max(caret, 0), ns.length)

        // Walk back to the blank line before, and forward to the one after.
        var start = position
        while start > 0 {
            let lineStart = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            let line = ns.substring(with: lineStart).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { break }
            start = lineStart.location
            if lineStart.location == 0 { break }
        }
        var end = position
        while end < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { break }
            end = lineRange.location + lineRange.length
            if end >= ns.length { break }
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Where the caret should sit vertically, as a fraction of the viewport.
    ///
    /// Above centre, not at it. Centring puts as much blank space below the
    /// caret as above, which wastes half the screen on text not yet written;
    /// this keeps a comfortable run of what was just written visible while
    /// still lifting the caret out of the bottom edge — which is the actual
    /// complaint typewriter scrolling answers.
    static let typewriterAnchor: CGFloat = 0.42

    /// The scroll origin that puts `caretY` at the anchor line.
    ///
    /// Clamped to the document: without this, the top of a short document
    /// scrolls into negative space (a band of nothing above the first line)
    /// and the end of one scrolls past its last line.
    static func typewriterOrigin(caretY: CGFloat, viewportHeight: CGFloat,
                                 documentHeight: CGFloat) -> CGFloat {
        let target = caretY - viewportHeight * typewriterAnchor
        let maximum = max(0, documentHeight - viewportHeight)
        return min(max(target, 0), maximum)
    }
}
