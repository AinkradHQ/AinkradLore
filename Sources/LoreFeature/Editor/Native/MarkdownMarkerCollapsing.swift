import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownStyleRenderer {
    // MARK: - Collapsing hidden markers

    /// Merges overlapping and adjacent ranges into a minimal covering set.
    ///
    /// Marker ranges are NOT disjoint. A nested blockquote `>> a` emits an
    /// outer `">> "` marker and an inner `"> "` marker that overlap, and two
    /// abutting markers (`**` immediately followed by `*`) produce ranges that
    /// touch. Applying attributes range-by-range would still be correct for
    /// `.font`, but the overlap makes the work quadratic in the worst case and
    /// makes any future non-idempotent attribute (a width reservation, a
    /// count) silently wrong. Coalescing first removes the whole class.
    ///
    /// Adjacent ranges are merged too (`<=`, not `<`): `a..<b` and `b..<c`
    /// describe one contiguous stretch of hidden syntax.
    static func coalesce(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Makes `ranges` take no visual space, WITHOUT altering the text.
    ///
    /// A near-zero font rather than a zero font: AppKit treats a zero-point
    /// font as invalid and substitutes the system default, which would make
    /// hidden markers render at FULL size — the opposite of the intent.
    ///
    /// The document string is never touched. Collapsing is attributes and
    /// visibility only, so every offset the search index, the link graph and
    /// the MCP tools hold stays valid by construction. If this ever starts
    /// deleting or rewriting characters, a display concern has reached the
    /// document — after fourteen data-loss defects in M0/M1, that is the one
    /// trade this codebase does not make.
    static func collapse(_ ranges: [Range<Int>], in storage: NSTextStorage) {
        let length = storage.length
        let collapsedFont = NSFont.systemFont(ofSize: 0.01)
        storage.beginEditing()
        for range in coalesce(ranges) {
            let ns = NSRange(location: range.lowerBound, length: range.count)
            guard ns.location >= 0, ns.location + ns.length <= length else { continue }
            storage.addAttribute(.font, value: collapsedFont, range: ns)
            storage.addAttribute(.kern, value: CGFloat(0), range: ns)
        }
        storage.endEditing()
    }

    /// The visible character range plus a margin.
    ///
    /// Deliberately does NOT touch `tv.layoutManager`: reading that property on
    /// a TextKit 2 text view silently downgrades the whole view to TextKit 1.
    /// `characterIndexForInsertion(at:)` is the version-agnostic answer, and is
    /// already the API `LinkTextView` uses for Cmd-click.
    static func viewportWindow(of tv: NSTextView) -> NSRange {
        let length = (tv.string as NSString).length
        let visible = tv.visibleRect
        guard !visible.isEmpty else { return NSRange(location: 0, length: length) }
        let a = tv.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: visible.minY))
        let b = tv.characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY))
        let lower = max(0, min(a, b) - viewportMargin)
        let upper = min(length, max(a, b) + viewportMargin)
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}
