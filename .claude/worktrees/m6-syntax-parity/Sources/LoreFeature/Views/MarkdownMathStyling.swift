import AppKit
import SwiftUI
import AinkradAppKit

/// Makes room for a drawn expression, and paints it.
///
/// Three techniques, none of them new here: the source is COLLAPSED by the
/// marker machinery that hides `**`, its width is reserved with `.kern` exactly
/// as a table column's padding is, and the rendered form is PAINTED like a
/// substituted list marker or a callout's heading. The document's text is never
/// touched, which is what ruled out every other way of rendering mathematics.
@MainActor
enum MarkdownMathStyling {

    /// Reserves horizontal and vertical room for every drawable expression.
    ///
    /// Runs AFTER `collapse`, which writes `.kern = 0` over each hidden marker
    /// and would otherwise wipe the reservation — the same ordering
    /// `MarkdownTableStyling` needs, for the same reason.
    ///
    /// - Parameter revealed: an expression inside it shows its source, so it
    ///   gets no reservation at all: the real characters are back at full width
    ///   and reserving space as well would push the rest of the line aside.
    static func reserveSpace(_ spans: [StyleSpan], revealed: Range<Int>?,
                             font: NSFont, in storage: NSTextStorage) {
        let text = storage.string as NSString
        for span in spans {
            guard case .math(let isRendered) = span.kind, isRendered else { continue }
            guard !isRevealed(span.range, in: revealed) else { continue }
            guard let box = box(for: span.range, in: text, font: font) else { continue }

            // The kern goes on the LAST character of the collapsed run, so the
            // gap opens between the expression and whatever follows it rather
            // than in front of it.
            let last = NSRange(location: span.range.upperBound - 1, length: 1)
            guard NSMaxRange(last) <= storage.length else { continue }
            storage.addAttribute(.kern, value: box.width, range: last)

            // A fraction is taller than a line of prose. Without this it would
            // be drawn over the line above, which is the one failure mode that
            // damages text the reader did not write.
            let lineHeight = font.ascender - font.descender
            guard box.height > lineHeight else { continue }
            let paragraph = text.paragraphRange(
                for: NSRange(location: span.range.lowerBound, length: 0))
            let existing = storage.attribute(.paragraphStyle, at: paragraph.location,
                                             effectiveRange: nil) as? NSParagraphStyle
            // COPIED, never replaced: the paragraph may already carry a list
            // indent or a quote's head indent, and dropping those to make room
            // for a fraction would move the whole block.
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = max(style.minimumLineHeight, box.height + 2)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// The drawing regions for every expression whose source is collapsed.
    ///
    /// Whether it IS collapsed is measured at draw time by the caller, from the
    /// geometry — never stored. `blockBackgrounds` is rebuilt only on a full
    /// render while reveal changes on every caret move, so a stored flag is
    /// stale exactly when the caret enters the expression. That mistake put a
    /// callout's heading on top of its own source on 2026-08-17.
    static func regions(for spans: [StyleSpan], font: NSFont,
                        in text: NSString) -> [MarkdownBlockBackgrounds.Region] {
        spans.compactMap { span in
            guard case .math(let isRendered) = span.kind, isRendered,
                  let box = box(for: span.range, in: text, font: font) else { return nil }
            return MarkdownBlockBackgrounds.Region(
                kind: .math(box),
                range: NSRange(location: span.range.lowerBound, length: span.range.count))
        }
    }

    /// Parses and lays out one expression. `nil` when it is not drawable after
    /// all, which keeps every caller on the "show the source" path.
    private static func box(for range: Range<Int>, in text: NSString,
                            font: NSFont) -> MathBox? {
        guard range.lowerBound >= 0, range.upperBound <= text.length,
              range.lowerBound < range.upperBound else { return nil }
        let whole = text.substring(with: NSRange(location: range.lowerBound,
                                                 length: range.count))
        // Strip the `$` or `$$` delimiters, which are notation rather than
        // mathematics.
        let width = whole.hasPrefix("$$") ? 2 : 1
        guard whole.count > width * 2 else { return nil }
        let content = String(whole.dropFirst(width).dropLast(width))
        guard let tree = MathParser.parse(content) else { return nil }
        return MathLayout.layout(tree, font: font)
    }

    private static func isRevealed(_ range: Range<Int>, in revealed: Range<Int>?) -> Bool {
        guard let revealed else { return false }
        return range.lowerBound < revealed.upperBound && revealed.lowerBound < range.upperBound
    }

    /// Whether an expression's source is COLLAPSED, and so should be drawn.
    ///
    /// Measures the FIRST character — the opening `$` — and not the whole
    /// expression, which is the mistake that shipped a blank gap where the
    /// fraction should have been (2026-08-17, image 7). `reserveSpace` puts the
    /// box's width as `.kern` on the run's LAST character, so the run as a
    /// whole measures about as wide as the drawing regardless of whether the
    /// source is hidden. The opening delimiter carries no kern and is therefore
    /// the honest witness: 0.01 pt when collapsed, a real glyph when revealed.
    ///
    /// Measured at draw time rather than stored, for the reason
    /// `MarkdownBlockBackgrounds.Kind.callout` spells out.
    @MainActor
    static func drawsExpression(at range: NSRange, in textView: NSTextView) -> Bool {
        guard range.length > 0 else { return false }
        let opener = NSRange(location: range.location, length: 1)
        let rect = MarkdownBlockBackgrounds.boundingRect(of: opener, in: textView)
        guard !rect.isNull else { return false }
        return rect.width < MarkdownBlockBackgrounds.collapsedMarkerWidth
    }

    /// Paints a laid-out expression at the collapsed run's position.
    ///
    /// The box's own coordinates are baseline-relative with y growing UP;
    /// `NSTextView` is flipped, so y grows down on screen. Hence the
    /// subtraction — get this backwards and a fraction renders upside down,
    /// which is at least an obvious failure rather than a subtle one.
    static func draw(_ box: MathBox, at range: NSRange, tint: NSColor,
                     in textView: NSTextView, origin: NSPoint, dirtyRect: NSRect) {
        let rect = MarkdownBlockBackgrounds.boundingRect(of: range, in: textView)
        guard !rect.isNull, !rect.isEmpty else { return }
        let placed = rect.offsetBy(dx: origin.x, dy: origin.y)
        guard placed.intersects(dirtyRect.insetBy(dx: -200, dy: -200)) else { return }

        // The baseline of the line the expression sits on. The collapsed run
        // has no useful height of its own, so the LINE's rect provides it.
        let font = MarkdownStyleRenderer.baseFont
        let baselineY = placed.maxY - (placed.height - (font.ascender - font.descender)) / 2
            + font.descender

        for glyph in box.glyphs {
            let point = CGPoint(x: placed.minX + glyph.origin.x,
                                y: baselineY - glyph.origin.y - glyph.font.ascender)
            (glyph.text as NSString).draw(at: point,
                                          withAttributes: [.font: glyph.font,
                                                           .foregroundColor: tint])
        }
        tint.setFill()
        for rule in box.rules {
            NSRect(x: placed.minX + rule.minX, y: baselineY - rule.maxY,
                   width: rule.width, height: rule.height).fill()
        }
    }
}
