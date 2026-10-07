import AinkradAppKit
import AppKit
import SwiftUI

/// Block decoration that is DRAWN, not attributed.
///
/// `.backgroundColor` is a per-glyph attribute, so a fenced block whose lines
/// differ in length gets a ragged right edge — a staircase, not a panel. That
/// raggedness is a large part of why the M2a editor read as "messed up". The
/// same applies to a blockquote: an indent alone does not say "quote", and the
/// bar that does say it exists between the text and the margin, where no
/// character lives.
///
/// Drawing is display-only by construction: nothing here touches the text
/// storage's string, and nothing here adds an attribute. The regions are
/// derived from style spans by the caller and handed over as plain ranges.
enum MarkdownBlockBackgrounds {

    /// The regions implied by a document's style spans.
    ///
    /// Spans arrive parent-first and may nest; only the two block kinds matter
    /// here, and each contributes exactly one region, so nesting cannot
    /// multiply the drawing.
    ///
    /// - Parameter window: the range whose ATTRIBUTES were applied, on an
    ///   over-cap document. Regions are intersected with it rather than merely
    ///   filtered by it, for two reasons: a panel must never be painted behind
    ///   text that was left unstyled, and asking the layout manager for the
    ///   bounding rect of a region far outside the viewport is exactly the work
    ///   that makes a long note stutter. `nil` means "the whole document was
    ///   styled", which is the ordinary case.
    /// - Parameter text: the document, needed only to read what a list marker
    ///   actually SAYS — `1.` and `7.` must not both draw as `1.`. `nil` (the
    ///   default, used by callers that only care about the block decorations)
    ///   emits no list markers rather than guessing at one.
    /// - Parameter tagPills: `EditorSettings.renderTagsAsChips`, resolved by
    ///   the theme. The setting is honoured HERE rather than at the styling
    ///   call site because the chip is now a drawn region rather than a text
    ///   attribute — with it off, no region is emitted at all and a tag is
    ///   simply tinted text.
    static func regions(
        for spans: [StyleSpan], length: Int,
        limitedTo window: NSRange? = nil,
        in text: NSString? = nil,
        tagPills: Bool = false
    ) -> [Region] {
        // The lines that carry a checkbox, so the bullet on those lines can be
        // suppressed. Collected in one pass up front rather than searched per
        // bullet, which would be quadratic on a long task list.
        // Nesting depth per list item, keyed by where the item STARTS — which
        // is also where its bullet marker starts, since `visitListItem` emits
        // both from the same range. That shared origin is what lets a marker
        // find its own depth without a second containment scan.
        let depths = MarkdownListDepth.depths(of: spans)
        var depthByItemStart: [Int: Int] = [:]
        for (index, span) in spans.enumerated() {
            guard case .listItem = span.kind else { continue }
            depthByItemStart[span.range.lowerBound] = depths[index]
        }

        var taskLines: Set<Int> = []
        if let text {
            for span in spans {
                guard case .checkbox = span.kind else { continue }
                let r = NSRange(location: span.range.lowerBound, length: span.range.count)
                guard NSMaxRange(r) <= text.length else { continue }
                taskLines.insert(text.lineRange(for: r).location)
            }
        }
        return spans.compactMap { span in
            var r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= length else { return nil }

            let kind: Kind
            switch span.kind {
            case .thematicBreak: kind = .rule
            case .inlineCode: kind = .inlineCodePill
            case .tag:
                guard tagPills else { return nil }
                kind = .tagPill
            case .codeBlock: kind = .codePanel
            case .blockQuote: kind = .quoteBar
            case .callout(let callout):
                // The heading to draw is decided HERE, where the text is in
                // hand, rather than at draw time: `draw` runs on every redraw
                // and must not be re-reading the document to find out whether
                // the author wrote a title.
                guard let text, NSMaxRange(r) <= text.length else { return nil }
                let header = MarkdownCallout.header(ofQuoteAt: span.range, in: text)
                let marker =
                    header.map {
                        NSRange(
                            location: $0.markerRange.lowerBound,
                            length: $0.markerRange.count)
                    } ?? NSRange(location: span.range.lowerBound, length: 0)
                kind = .callout(
                    callout,
                    title: header?.titleRange == nil
                        ? callout.displayTitle : nil,
                    marker: marker)
            case .checkbox(let done):
                // Drawn only where the source is collapsed, decided at draw
                // time from geometry — the same self-correcting witness the
                // callout heading and the list marker use, and for the same
                // reason: reveal moves on a caret press, which does not
                // rebuild these regions.
                guard NSMaxRange(r) <= length else { return nil }
                return Region(kind: .checkbox(done), range: r)

            case .marker(of: .listBullet):
                // A TASK item's bullet is not drawn: its checkbox stands where
                // the bullet would, and drawing both would put `• ☐` on every
                // line of a task list.
                if let text, taskLines.contains(text.lineRange(for: r).location) {
                    return nil
                }
                // NOT clipped to the window: a marker is two or three
                // characters, so intersecting it would draw half a `10.`. It is
                // either wholly inside the styled window or it is not drawn.
                guard let text, NSMaxRange(r) <= text.length,
                    let glyph = listMarkerGlyph(
                        for: text.substring(with: r),
                        depth: depthByItemStart[span.range.lowerBound] ?? 0)
                else { return nil }
                if let window,
                    NSIntersectionRange(r, window).length != r.length
                {
                    return nil
                }
                return Region(kind: .listMarker(glyph), range: r)
            default: return nil
            }
            if let window {
                r = NSIntersectionRange(r, window)
                guard r.length > 0 else { return nil }
            }
            return Region(kind: kind, range: r)
        }
    }

    /// What a list marker's SOURCE draws as once collapsed.
    ///
    /// `- `, `* `, `+ ` become a real bullet; an ordinal keeps its own number
    /// and is normalised to a trailing `.` so a `1)` list and a `1.` list read
    /// alike. Anything else returns nil — the same "emit nothing rather than a
    /// guess" rule `MarkdownMarkers` follows, since a wrong glyph in the gutter
    /// is worse than none.
    /// - Parameter depth: nesting level, 0 for a top-level item. An UNORDERED
    ///   bullet cycles with it — Obsidian draws a filled disc, then a hollow
    ///   one, then a small square — which is what lets a reader tell a nested
    ///   list from a wrapped line at a glance. An ordinal does not cycle: a
    ///   number is already its own distinguishing mark.
    static func listMarkerGlyph(for source: String, depth: Int = 0) -> String? {
        let body = source.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body == "-" || body == "*" || body == "+" {
            let cycle = ["•", "◦", "▪"]
            return cycle[max(0, depth) % cycle.count]
        }
        let digits = body.dropLast()
        guard let last = body.last, last == "." || last == ")",
            !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return digits + "."
    }

    /// The corner radius of a code panel. Enough to read as a panel, little
    /// enough not to read as a button.
    static let cornerRadius: CGFloat = 5
    /// Width of a blockquote's bar.
    static let barWidth: CGFloat = 3
    /// Vertical breathing room inside a code panel, above the first line and
    /// below the last.
    static let codePanelPadding: CGFloat = 8
    /// The gap between a drawn list marker and the item's text.
    static let listMarkerGap: CGFloat = 5
    /// How far a tag's pill extends past the tag's own glyphs. Horizontal is
    /// generous and vertical is not: a pill wants air at its ends, and a tall
    /// one collides with the line above.
    /// How far an inline code pill extends past its glyphs, and how round it
    /// is. Obsidian's is a small radius rather than a capsule — code is often
    /// a single character, and a capsule around `x` reads as a badge.
    static let inlineCodePaddingH: CGFloat = 4
    static let inlineCodePaddingV: CGFloat = 2
    static let inlineCodeRadius: CGFloat = 4
    static let tagPillPaddingH: CGFloat = 5
    static let tagPillPaddingV: CGFloat = 1
    /// Below this rendered width a marker's source is COLLAPSED and its
    /// substitute must be drawn; at or above it the real characters are on
    /// screen — the caret is in the block — and drawing would double them.
    ///
    /// Geometry rather than bookkeeping, deliberately: reveal state changes on
    /// a caret move, which does not rebuild the regions, so a cached flag would
    /// go stale exactly when the user looked at it. The collapsed font is
    /// 0.01pt (see `MarkdownStyleRenderer.collapse`) and the revealed one is
    /// 14pt monospaced, so any threshold between them separates the two cases
    /// by three orders of magnitude.
    static let collapsedMarkerWidth: CGFloat = 2

    /// The gap between the bar and a callout's icon, and between the icon and
    /// the text.
    static let calloutIconGap: CGFloat = 6

    /// How far a callout's text is indented: exactly the room its decoration
    /// occupies — the bar, a gap, the icon, a gap.
    ///
    /// ONE definition, read by both the paragraph indent
    /// (`MarkdownParagraphStyles`) and the drawing below, because they are two
    /// answers to the same question and were previously computed apart. The
    /// indent was `listIndentStep * 2` = 44 pt against decoration needing 29,
    /// so a callout carried 15 pt of dead space — invisible while the icon
    /// covered it, and an obvious empty gutter the moment the caret revealed
    /// the source and the icon stopped being drawn (2026-08-17, image 9).
    /// - Parameter iconSize: the icon's side, which is the theme's body point
    ///   size — the icon is drawn to match the text beside it. A PARAMETER
    ///   rather than a constant since the font stopped being one: this used to
    ///   read `MarkdownStyleRenderer.baseSize`, and leaving it fixed while the
    ///   drawing scaled would re-open the 15 pt dead gutter of 2026-08-17 at
    ///   every density except the one it was written for.
    nonisolated static func calloutTextIndent(iconSize: CGFloat) -> CGFloat {
        barWidth + calloutIconGap + iconSize + calloutIconGap
    }
}
