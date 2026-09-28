import AppKit
import SwiftUI
import AinkradAppKit

/// Column alignment for pipe tables.
///
/// ## Why kerning, and not the two obvious alternatives
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
/// So the columns are aligned by PADDING: each cell's trailing `|` — already
/// collapsed to nothing by the marker machinery — is given a `.kern` equal to
/// the space the cell needs to reach its column's width. The text is untouched,
/// no character is added or removed, and the alignment is exact rather than
/// approximate because the editor's base font is MONOSPACED, so a column's
/// width in characters is its width on screen.
///
/// ## Why it runs after collapse
///
/// `MarkdownStyleRenderer.collapse` writes `.kern = 0` over every hidden
/// marker. Padding applied before it would be wiped; padding applied after it
/// lands on top, which is also the only point at which the reveal state — and
/// therefore whether a row is showing its source at all — is known.
@MainActor
enum MarkdownTableStyling {

    /// Aligns every table in `spans` that is not currently revealed.
    ///
    /// - Parameter revealed: the source range whose syntax is shown. A row
    ///   inside it keeps its real `|` characters at full width, so padding it
    ///   would push the columns apart by the width of the pipes it can now see.
    ///   Obsidian does the same thing — the row you are editing goes back to
    ///   source — so this is the behaviour being matched, not a limitation.
    static func align(_ spans: [StyleSpan], revealed: Range<Int>?,
                      maxWidth: CGFloat = .greatestFiniteMagnitude,
                      in storage: NSTextStorage) {
        let text = storage.string as NSString
        let space = (" " as NSString).size(
            withAttributes: [.font: MarkdownStyleRenderer.baseFont]).width
        guard space > 0 else { return }

        for span in spans {
            guard case .table = span.kind,
                  let table = MarkdownTable.parse(range: span.range, in: text),
                  fits(table, space: space, maxWidth: maxWidth)
            else { continue }

            for row in table.rows {
                // A revealed row shows its pipes, so it must not be padded.
                if let revealed,
                   row.range.lowerBound < revealed.upperBound,
                   revealed.lowerBound < row.range.upperBound { continue }

                for (column, cell) in row.cells.enumerated()
                where column < table.columnWidths.count {
                    let padding = table.columnWidths[column] - cell.width
                    guard padding > 0 else { continue }

                    // Where the slack goes decides how the column reads. Left
                    // puts it all after the cell, right all before it, centre
                    // splits it — with the ODD unit going after, so a column
                    // that cannot centre exactly leans the same way every row
                    // rather than jittering between them.
                    let alignment = column < table.columnAlignments.count
                        ? table.columnAlignments[column] : .left
                    let before: Int
                    switch alignment {
                    case .left: before = 0
                    case .right: before = padding
                    case .center: before = padding / 2
                    }

                    // The pipes that OPEN and CLOSE this cell. Found by
                    // position rather than by index arithmetic, which would be
                    // off by one for a row without a leading `|` — both
                    // spellings are legal GFM and a vault contains both.
                    let closing = row.pipes.first { $0.lowerBound >= cell.range.upperBound }
                    let opening = row.pipes.last { $0.upperBound <= cell.range.lowerBound }

                    // A first cell in a row with no leading `|` has nothing to
                    // pad in front of, so it stays left-aligned. Falling back
                    // is right: the alternative is padding the END and shifting
                    // every later column, which misaligns the whole row to
                    // honour one cell's colon.
                    let leading = opening == nil ? 0 : before
                    let trailing = padding - leading

                    if leading > 0, let opening {
                        pad(opening, by: leading, space: space, in: storage)
                    }
                    if trailing > 0, let closing {
                        pad(closing, by: trailing, space: space, in: storage)
                    }
                }
            }
        }
    }

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
    static func prepare(_ spans: [StyleSpan], revealed: Range<Int>?, maxWidth: CGFloat,
                        in storage: NSTextStorage) -> [MarkdownBlockBackgrounds.Region] {
        let text = storage.string as NSString
        var out: [MarkdownBlockBackgrounds.Region] = []
        for span in spans {
            guard case .table = span.kind,
                  let table = MarkdownTable.parse(range: span.range, in: text),
                  let box = MarkdownTableLayout.layout(table, in: storage,
                                                       maxWidth: maxWidth)
            else { continue }
            reserveRows(box, revealed: revealed, in: storage)
            out.append(MarkdownBlockBackgrounds.Region(
                kind: .table(box, marker: NSRange(location: span.range.lowerBound,
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
    static func reserveRows(_ box: TableBox, revealed: Range<Int>?,
                            in storage: NSTextStorage) {
        for row in box.rows {
            guard NSMaxRange(row.sourceRange) <= storage.length else { continue }
            // A revealed table shows its source and must keep the source's own
            // line heights, or the rows stand apart while being edited.
            if isRevealed(row.sourceRange, in: revealed) { continue }
            let style = (storage.attribute(.paragraphStyle, at: row.sourceRange.location,
                                           effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.minimumLineHeight = row.height
            style.maximumLineHeight = row.height
            storage.addAttribute(.paragraphStyle, value: style, range: row.sourceRange)
        }
        if let delimiter = box.delimiterRange, NSMaxRange(delimiter) <= storage.length,
           !isRevealed(delimiter, in: revealed) {
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
    static func draw(_ box: TableBox, tint: NSColor, rule: NSColor,
                     in textView: NSTextView, origin: NSPoint, dirtyRect: NSRect) {
        for row in box.rows {
            var rect = MarkdownBlockBackgrounds.boundingRect(of: row.sourceRange,
                                                             in: textView)
            guard !rect.isNull, !rect.isEmpty else { continue }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(dirtyRect.insetBy(dx: -400, dy: -400)) else { continue }

            // A row showing its SOURCE must not also be drawn over. Measured
            // from the row's first character, which is 0.01 pt while collapsed
            // and a real glyph once the caret reveals it.
            guard MarkdownMathStyling.drawsExpression(
                at: NSRange(location: row.sourceRange.location, length: 1), in: textView)
            else { continue }

            for cell in row.cells where cell.column < box.columnWidths.count {
                let width = box.columnWidths[cell.column]
                let inner = max(1, width - cellPaddingH * 2)
                let text = cell.text
                guard text.length > 0 else { continue }
                let size = text.boundingRect(
                    with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).size

                // Alignment decides where the text sits in the slack, which is
                // the same question the kern version answered with padding.
                let slack = max(0, inner - size.width)
                let alignment = cell.column < box.columnAlignments.count
                    ? box.columnAlignments[cell.column] : .left
                let offset = cellOffset(for: alignment, slack: slack)
                let x = rect.minX + box.columnOrigin(cell.column) + cellPaddingH + offset
                text.draw(with: CGRect(x: x, y: rect.minY + cellPaddingV,
                                       width: inner, height: rect.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            }

            rule.setFill()
            // Under the header, a firm rule; between body rows, a hairline.
            let thickness: CGFloat = row.isHeader ? 1 : 0.5
            NSRect(x: rect.minX, y: rect.maxY - thickness,
                   width: box.totalWidth, height: thickness).fill()
        }
    }

    /// Where a cell's text sits inside the slack its column leaves it.
    ///
    /// Pulled out of the drawing so it can be asserted directly. The kern-era
    /// version of this decision was testable on screen — the padding moved real
    /// glyphs — but a drawn grid puts the text somewhere no character rect can
    /// report, so the arithmetic has to be checkable on its own.
    static func cellOffset(for alignment: MarkdownTable.Alignment,
                           slack: CGFloat) -> CGFloat {
        switch alignment {
        case .left: return 0
        case .right: return slack
        case .center: return slack / 2
        }
    }

    static let cellPaddingH = MarkdownTableLayout.cellPadding
    static let cellPaddingV = MarkdownTableLayout.rowPadding

    /// Whether an aligned table would fit the text column.
    ///
    /// It very often does not, and that is a LIMIT of this approach rather than
    /// a bug to tune away. Padding aligns columns by widening cells, and a row
    /// is one paragraph: when it exceeds the column it wraps at the container's
    /// edge, and the continuation starts at the left margin with no memory of
    /// which cell it belonged to. The table stops being a table.
    ///
    /// Per-cell wrapping needs real table layout — `NSTextTable`, which is
    /// TextKit 1 and unavailable here — or drawing the whole grid. Until one of
    /// those, a table that cannot fit is left as SOURCE: pipes visible,
    /// delimiter row visible, nothing padded. Markdown a reader can follow
    /// beats a grid that has come apart.
    ///
    /// MEASURED on a real table from Ahmed's vault (2026-08-17): 114 characters
    /// of content against a 760 pt measure — 987 pt needed. It could not fit at
    /// any window width.
    static func fits(_ table: MarkdownTable, space: CGFloat, maxWidth: CGFloat) -> Bool {
        let columns = table.columnWidths.reduce(0, +)
        // One space of gutter between columns, which is what the collapsed
        // pipes leave behind.
        let gutters = max(0, table.columnWidths.count - 1)
        return CGFloat(columns + gutters) * space <= maxWidth
    }

    /// The tables in `spans` that cannot fit, so their notation stays visible.
    static func rangesShownAsSource(_ spans: [StyleSpan], maxWidth: CGFloat,
                                    in text: NSString) -> [Range<Int>] {
        let space = (" " as NSString).size(
            withAttributes: [.font: MarkdownStyleRenderer.baseFont]).width
        guard space > 0 else { return [] }
        return spans.compactMap { span in
            guard case .table = span.kind,
                  let table = MarkdownTable.parse(range: span.range, in: text),
                  !fits(table, space: space, maxWidth: maxWidth) else { return nil }
            return span.range
        }
    }

    /// Writes `columns` worth of space into a collapsed pipe.
    private static func pad(_ pipe: Range<Int>, by columns: Int, space: CGFloat,
                            in storage: NSTextStorage) {
        let range = NSRange(location: pipe.lowerBound, length: pipe.count)
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.kern, value: CGFloat(columns) * space, range: range)
    }
}
