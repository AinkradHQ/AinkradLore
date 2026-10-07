import AinkradAppKit
import AppKit
import SwiftUI

/// Preparing and painting a pipe table's drawn grid.
///
/// ## Why the grid is DRAWN
///
/// An `NSTextAttachment` is how most editors render a table, and it is ruled
/// out here: an attachment needs a `U+FFFC` character standing in for the
/// source, which changes the document's text and with it every offset the
/// index, the link graph and the MCP tools hold. That rule is the one this
/// codebase protects hardest.
///
/// `NSTextTable`/`NSTextBlock` is AppKit's own answer and is TextKit 1. The
/// editor is TextKit 2 on purpose — see `MarkdownStyleRenderer.viewportWindow`,
/// which avoids even READING `layoutManager` because that silently downgrades
/// the view.
///
/// So the grid is measured by `MarkdownTableLayout` and painted here, over
/// source that has been collapsed rather than altered — the same
/// collapse-reserve-draw route the maths and the transclusions take.
///
/// ## What used to be here
///
/// Columns were once aligned by KERNING: each cell's collapsed `|` was given a
/// `.kern` equal to the space the cell needed to reach its column's width. That
/// worked only while a whole row fitted one line — a row is one paragraph, so
/// past the container's edge it wrapped and the continuation started at the
/// left margin with no memory of its cell. `MarkdownTableLayout` replaced it
/// with per-cell wrapping inside a measured grid, and the kern path
/// (`align`, `fits`, `pad`, `rangesShownAsSource`) went unreferenced from that
/// day. It is deleted rather than kept: it was the last thing in the editor
/// that assumed a MONOSPACED base font — a column's width in characters being
/// its width on screen — and leaving it in place would have made the M9.1 font
/// change look far riskier than it is.
///
/// ## Why the reservations run after collapse
///
/// `MarkdownStyleRenderer.collapse` resets attributes over every hidden
/// marker, so a row height reserved before it would be wiped. Reserving after
/// it lands on top, and is also the only point at which the reveal state — and
/// therefore whether a row is showing its source at all — is known.
@MainActor
enum MarkdownTableStyling {

    /// The ranges of the row markers — the spans that hide a whole table row.
    ///
    /// Separated from the other markers so the collapse can happen in two
    /// passes around the cell capture: inline syntax hidden first, cells
    /// captured as the reader will see them, rows hidden last.
    static func rowMarkerRanges(_ spans: [StyleSpan]) -> Set<Range<Int>> {
        var out: Set<Range<Int>> = []
        for span in spans {
            guard case .marker(let owner) = span.kind, owner == .tablePipe else { continue }
            out.insert(span.range)
        }
        return out
    }

    /// The drawing regions for every table whose grid can be laid out.
    ///
    /// Also reserves each row's height, because the two must be decided from
    /// the SAME layout — a grid measured one way and reserved another is how a
    /// table ends up drawn over the paragraph beneath it.
    static func prepare(
        _ spans: [StyleSpan], revealed: Range<Int>?, maxWidth: CGFloat,
        bodyFont: NSFont,
        in storage: NSTextStorage
    ) -> [MarkdownBlockBackgrounds.Region] {
        let text = storage.string as NSString
        var out: [MarkdownBlockBackgrounds.Region] = []
        for span in spans {
            guard case .table = span.kind,
                let table = MarkdownTable.parse(range: span.range, in: text),
                let box = MarkdownTableLayout.layout(
                    table, in: storage,
                    maxWidth: maxWidth,
                    bodyFont: bodyFont)
            else { continue }
            reserveRows(box, revealed: revealed, in: storage)
            out.append(
                MarkdownBlockBackgrounds.Region(
                    kind: .table(
                        box,
                        marker: NSRange(
                            location: span.range.lowerBound,
                            length: 1)),
                    range: NSRange(location: span.range.lowerBound, length: span.range.count)))
        }
        return out
    }

    /// Reserves each row's DRAWN height on its own source line.
    ///
    /// One line per row, so row three's height is reserved on row three's line
    /// and the drawing can anchor itself to the same rect. The delimiter row
    /// reserves nothing: it collapses to a hairline, because the rule drawn
    /// under the header already says what `|---|` said.
    ///
    /// Runs AFTER `collapse`, like every other reservation here — that pass
    /// resets attributes on the ranges this writes to.
    static func reserveRows(
        _ box: TableBox, revealed: Range<Int>?,
        in storage: NSTextStorage
    ) {
        for row in box.rows {
            guard NSMaxRange(row.sourceRange) <= storage.length else { continue }
            // A revealed table shows its source and must keep the source's own
            // line heights, or the rows stand apart while being edited.
            if isRevealed(row.sourceRange, in: revealed) { continue }
            let style =
                (storage.attribute(
                    .paragraphStyle, at: row.sourceRange.location,
                    effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.minimumLineHeight = row.height
            style.maximumLineHeight = row.height
            storage.addAttribute(.paragraphStyle, value: style, range: row.sourceRange)
        }
        if let delimiter = box.delimiterRange, NSMaxRange(delimiter) <= storage.length,
            !isRevealed(delimiter, in: revealed)
        {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            storage.addAttribute(.paragraphStyle, value: style, range: delimiter)
        }
    }

    private static func isRevealed(_ range: NSRange, in revealed: Range<Int>?) -> Bool {
        guard let revealed else { return false }
        return range.location < revealed.upperBound
            && revealed.lowerBound < NSMaxRange(range)
    }

    /// Paints the grid: each cell's text, wrapped inside its column, plus the
    /// rule under the header and a hairline between rows.
    ///
    /// Cell content is pulled from the storage as an ATTRIBUTED substring, so
    /// bold, inline code, a wikilink's colour and a collapsed `**` all render
    /// exactly as the rest of the editor renders them. Drawing plain text here
    /// would mean a second, divergent idea of what a cell looks like.
    static func draw(
        _ box: TableBox, tint: NSColor, rule: NSColor,
        in textView: NSTextView, origin: NSPoint, dirtyRect: NSRect
    ) {
        for row in box.rows {
            var rect = MarkdownBlockBackgrounds.boundingRect(
                of: row.sourceRange,
                in: textView)
            guard !rect.isNull, !rect.isEmpty else { continue }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(dirtyRect.insetBy(dx: -400, dy: -400)) else { continue }

            // A row showing its SOURCE must not also be drawn over. Measured
            // from the row's first character, which is 0.01 pt while collapsed
            // and a real glyph once the caret reveals it.
            guard
                MarkdownMathStyling.drawsExpression(
                    at: NSRange(location: row.sourceRange.location, length: 1), in: textView)
            else { continue }

            for cell in row.cells where cell.column < box.columnWidths.count {
                let width = box.columnWidths[cell.column]
                let inner = max(1, width - cellPaddingH * 2)
                let text = cell.text
                guard text.length > 0 else { continue }
                let size = text.boundingRect(
                    with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).size

                // Alignment decides where the text sits in the slack, which is
                // the same question the kern version answered with padding.
                let slack = max(0, inner - size.width)
                let alignment =
                    cell.column < box.columnAlignments.count
                    ? box.columnAlignments[cell.column] : .left
                let offset = cellOffset(for: alignment, slack: slack)
                let x = rect.minX + box.columnOrigin(cell.column) + cellPaddingH + offset
                text.draw(
                    with: CGRect(
                        x: x, y: rect.minY + cellPaddingV,
                        width: inner, height: rect.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
            }

            // A GRID, not a set of underlines.
            //
            // This drew one horizontal rule per row and nothing else, which
            // reads as ruled paper rather than as a table: with no verticals a
            // reader cannot see where one column ends and the next begins, and
            // an empty cell is indistinguishable from a short one. Obsidian
            // draws every edge, and a table is the one construct where the
            // borders ARE the structure.
            rule.setFill()
            let thickness: CGFloat = row.isHeader ? 1 : 0.5
            NSRect(
                x: rect.minX, y: rect.maxY - thickness,
                width: box.totalWidth, height: thickness
            ).fill()
            // The row's top edge, so the first row is closed rather than open.
            if row.isHeader {
                NSRect(
                    x: rect.minX, y: rect.minY,
                    width: box.totalWidth, height: thickness
                ).fill()
            }
            // One vertical per column boundary, plus the two outer edges.
            // Hairlines throughout: a table wants to be read across, and
            // verticals as heavy as the header rule fight the text.
            for column in 0...box.columnWidths.count {
                let x = rect.minX + box.columnOrigin(column)
                NSRect(x: x, y: rect.minY, width: 0.5, height: rect.height).fill()
            }
        }
    }

    /// Where a cell's text sits inside the slack its column leaves it.
    ///
    /// Pulled out of the drawing so it can be asserted directly. The kern-era
    /// version of this decision was testable on screen — the padding moved real
    /// glyphs — but a drawn grid puts the text somewhere no character rect can
    /// report, so the arithmetic has to be checkable on its own.
    static func cellOffset(
        for alignment: MarkdownTable.Alignment,
        slack: CGFloat
    ) -> CGFloat {
        switch alignment {
        case .left: return 0
        case .right: return slack
        case .center: return slack / 2
        }
    }

    static let cellPaddingH = MarkdownTableLayout.cellPadding
    static let cellPaddingV = MarkdownTableLayout.rowPadding

}
