import AppKit

/// A pipe table laid out as a real grid, with per-cell wrapping.
///
/// ## Why this exists at all
///
/// Columns used to be aligned by PADDING cells with `.kern`. That works only
/// while the whole table fits one line: a row is a single paragraph, so once it
/// exceeds the text column it wraps at the container's edge and the
/// continuation starts at the left margin with no memory of its cell. MEASURED
/// on a real table from Ahmed's vault (2026-08-17): 987 pt needed against a
/// 760 pt measure. It could not fit at any window width, and the table came
/// apart on screen.
///
/// Per-cell wrapping needs real table layout. `NSTextTable` is TextKit 1 and
/// this editor is deliberately TextKit 2, so the grid is measured here and
/// DRAWN — the same collapse-reserve-draw route the maths takes, and the same
/// one that keeps the document's text untouched.
///
/// ## What it deliberately does not hold
///
/// No text. Only RANGES, column widths and row heights. The cell content is
/// pulled from the text storage at draw time as an attributed substring, which
/// means every inline style already applied — bold, inline code, a wikilink's
/// colour, a collapsed `**` — comes along for free and cannot drift out of step
/// with what the rest of the editor thinks that text looks like.
struct TableBox: Equatable {
    struct Cell: Equatable {
        /// The cell's content, captured from the storage WITH its attributes.
        ///
        /// Held rather than re-read at draw time, and that ordering is
        /// load-bearing: by then the row has been collapsed to a 0.01 pt font,
        /// so reading it live would draw a microscopic grid. Captured before
        /// the collapse, it carries every inline style the editor had already
        /// applied — bold, inline code, a wikilink's colour, a hidden `**`.
        let text: NSAttributedString
        let column: Int
    }

    struct Row: Equatable {
        /// The source line this row occupies, which is where the drawing
        /// anchors itself and where the height is reserved.
        let sourceRange: NSRange
        let cells: [Cell]
        let height: CGFloat
        let isHeader: Bool
    }

    let columnWidths: [CGFloat]
    let columnAlignments: [MarkdownTable.Alignment]
    let rows: [Row]
    /// The delimiter row's source line, whose height collapses to nothing —
    /// the drawn rule under the header says what it said.
    let delimiterRange: NSRange?

    /// The x offset of a column's left edge.
    func columnOrigin(_ column: Int) -> CGFloat {
        columnWidths.prefix(column).reduce(0, +)
    }

    var totalWidth: CGFloat { columnWidths.reduce(0, +) }
}

@MainActor
enum MarkdownTableLayout {

    /// Space inside a cell, either side of its text.
    static let cellPadding: CGFloat = 8
    /// Space above and below a cell's text.
    static let rowPadding: CGFloat = 4
    /// The narrowest a column may be squeezed before the table simply
    /// overflows. A column thinner than this wraps every word onto its own
    /// line, which is less readable than the source it replaced.
    static let minimumColumnWidth: CGFloat = 48

    /// Measures a table against the width actually available.
    ///
    /// Returns `nil` when there are no columns, or when even the minimum widths
    /// cannot fit — the caller then leaves the source alone, which is the
    /// standing rule for anything that cannot be rendered properly.
    static func layout(_ table: MarkdownTable, in storage: NSTextStorage,
                       maxWidth: CGFloat) -> TableBox? {
        let columnCount = table.columnWidths.count
        guard columnCount > 0, maxWidth > 0 else { return nil }
        guard CGFloat(columnCount) * minimumColumnWidth <= maxWidth else { return nil }

        // 1. What each column would like: its widest cell, plus padding.
        var natural = [CGFloat](repeating: minimumColumnWidth, count: columnCount)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                let width = measure(cell.range, in: storage).width + cellPadding * 2
                natural[column] = max(natural[column], width)
            }
        }

        // 2. Squeeze proportionally if that is more than there is. Columns
        // already at the floor are left alone and the rest give up the
        // difference, so one very wide column does not crush a narrow one to
        // nothing.
        let widths = fit(natural, into: maxWidth)

        // 3. Row heights, from the WRAPPED height of each cell at its final
        // column width. This is the whole point of the exercise: a cell too
        // long for its column now takes two lines inside the column rather
        // than pushing the row off the edge.
        var rows: [TableBox.Row] = []
        for (index, row) in table.rows.enumerated() {
            var height = MarkdownStyleRenderer.baseFont.ascender
                - MarkdownStyleRenderer.baseFont.descender
            var cells: [TableBox.Cell] = []
            for (column, cell) in row.cells.enumerated() where column < columnCount {
                let inner = max(1, widths[column] - cellPadding * 2)
                height = max(height, measure(cell.range, in: storage, wrappingAt: inner).height)
                cells.append(TableBox.Cell(text: attributed(cell.range, in: storage),
                                           column: column))
            }
            rows.append(TableBox.Row(
                sourceRange: NSRange(location: row.range.lowerBound, length: row.range.count),
                cells: cells, height: height + rowPadding * 2, isHeader: index == 0))
        }
        guard !rows.isEmpty else { return nil }

        return TableBox(columnWidths: widths,
                        columnAlignments: table.columnAlignments,
                        rows: rows,
                        delimiterRange: table.delimiterRow.map {
                            NSRange(location: $0.range.lowerBound, length: $0.range.count)
                        })
    }

    /// Scales `natural` down to `maxWidth`, never below the floor.
    ///
    /// Proportional rather than equal: a column of one-word cells and a column
    /// of sentences should not end up the same width just because both are too
    /// wide together.
    static func fit(_ natural: [CGFloat], into maxWidth: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > maxWidth else { return natural }
        var widths = natural.map { max(minimumColumnWidth, $0 * maxWidth / total) }
        // The floor may have pushed the total back over; take the excess from
        // whatever is above the floor, proportionally to its slack.
        var excess = widths.reduce(0, +) - maxWidth
        if excess > 0 {
            let slack = widths.map { max(0, $0 - minimumColumnWidth) }
            let totalSlack = slack.reduce(0, +)
            if totalSlack > 0 {
                for index in widths.indices {
                    widths[index] -= excess * slack[index] / totalSlack
                }
                excess = 0
            }
        }
        return widths
    }

    /// One cell's content, with the attributes it currently carries.
    private static func attributed(_ range: Range<Int>,
                                   in storage: NSTextStorage) -> NSAttributedString {
        let ns = NSRange(location: range.lowerBound, length: range.count)
        guard ns.length > 0, NSMaxRange(ns) <= storage.length else {
            return NSAttributedString()
        }
        return storage.attributedSubstring(from: ns)
    }

    /// One cell's rendered size, taken from the STORAGE so every inline style
    /// already applied is accounted for — a bold cell measures as bold, and a
    /// collapsed `**` measures as nothing.
    private static func measure(_ range: Range<Int>, in storage: NSTextStorage,
                                wrappingAt width: CGFloat = .greatestFiniteMagnitude)
        -> CGSize {
        let ns = NSRange(location: range.lowerBound, length: range.count)
        guard ns.length > 0, NSMaxRange(ns) <= storage.length else { return .zero }
        let text = storage.attributedSubstring(from: ns)
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}
