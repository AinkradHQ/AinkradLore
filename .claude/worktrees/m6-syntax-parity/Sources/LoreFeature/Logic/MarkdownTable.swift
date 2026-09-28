import Foundation

/// A pipe table's shape, in absolute UTF-16 offsets into the editor's string.
///
/// swift-markdown parses GFM tables and gives back a `Table` node, which is
/// what tells the collector one is HERE. It does not give back what the
/// renderer needs — where each pipe sits in the source, and how wide each
/// column has to be — so that is measured from the text here.
///
/// Kept pure and text-only for the same reason as every other rule in this
/// folder: the alignment arithmetic is the part that can be subtly wrong, and
/// it is far easier to assert on a value than to squint at a screenshot.
struct MarkdownTable: Equatable {

    /// One cell's CONTENT, trimmed of the padding spaces the author typed.
    struct Cell: Equatable {
        /// The trimmed content, or an empty range at the cell's start when the
        /// cell holds only whitespace.
        let range: Range<Int>
        /// Rendered width in CHARACTERS, which in a monospaced font is the
        /// width in columns. Swift `Character`s rather than UTF-16 units: an
        /// emoji is one grapheme and two units, and padding by units would
        /// indent every row containing one.
        let width: Int
    }

    struct Row: Equatable {
        let cells: [Cell]
        /// Every `|` on this line, in source order.
        let pipes: [Range<Int>]
        /// The line, terminator excluded.
        let range: Range<Int>
    }

    /// How a column's cells sit inside their width, from the colons on the
    /// delimiter row: `|:--|` left, `|--:|` right, `|:-:|` centred.
    enum Alignment: Equatable {
        case left, center, right
    }

    let rows: [Row]
    /// The `|---|:--:|` line, which carries no content and is hidden whole.
    let delimiterRow: Row?
    /// Width in characters of each column: the widest cell in it.
    let columnWidths: [Int]
    /// One entry per column, defaulting to `.left` — GFM's own default, and
    /// the answer for a table whose delimiter row carries no colons at all.
    let columnAlignments: [Alignment]
    /// The header row, which is the first one. `nil` for a malformed table
    /// with no rows at all.
    var headerRow: Row? { rows.first }

    /// Reads the table occupying `range`.
    ///
    /// Returns `nil` when the text does not look like a table after all —
    /// fewer than two lines, or no pipes. The AST has already said this IS a
    /// table, so `nil` here means the two disagree, and the honest answer is to
    /// leave the source alone rather than half-render it.
    static func parse(range: Range<Int>, in text: NSString) -> MarkdownTable? {
        guard range.lowerBound >= 0, range.upperBound <= text.length,
              range.lowerBound < range.upperBound else { return nil }

        var lines: [Range<Int>] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            var end = min(NSMaxRange(line), range.upperBound)
            // Trim the terminator: it belongs to no cell, and including it
            // would put the last column's padding after the line break.
            while end > index, isLineBreak(text.character(at: end - 1)) { end -= 1 }
            if end > index { lines.append(index..<end) }
            index = max(NSMaxRange(line), index + 1)
        }
        guard lines.count >= 2 else { return nil }

        let parsed = lines.map { row(in: $0, text: text) }
        guard parsed.allSatisfy({ !$0.pipes.isEmpty }) else { return nil }

        // The delimiter is the SECOND line by GFM's definition, not "any line
        // that looks like one" — a body cell containing `---` is content.
        let delimiterIndex = 1
        let isDelimiter = parsed.indices.contains(delimiterIndex)
            && parsed[delimiterIndex].cells.allSatisfy {
                isDelimiterCell($0.range, in: text)
            }
        let delimiter = isDelimiter ? parsed[delimiterIndex] : nil
        let content = parsed.enumerated()
            .filter { isDelimiter ? $0.offset != delimiterIndex : true }
            .map(\.element)

        let columns = content.map(\.cells.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in content {
            for (column, cell) in row.cells.enumerated() where column < columns {
                widths[column] = max(widths[column], cell.width)
            }
        }
        var alignments = [Alignment](repeating: .left, count: columns)
        if let delimiter {
            for (column, cell) in delimiter.cells.enumerated() where column < columns {
                alignments[column] = alignment(ofDelimiterCell: cell.range, in: text)
            }
        }
        return MarkdownTable(rows: content, delimiterRow: delimiter,
                             columnWidths: widths, columnAlignments: alignments)
    }

    /// Splits one line into cells and pipes.
    ///
    /// A pipe preceded by a backslash is CONTENT — `\|` is how GFM writes a
    /// literal pipe inside a cell — and splitting on it would shear the row
    /// into the wrong number of columns and misalign every one after it.
    private static func row(in line: Range<Int>, text: NSString) -> Row {
        var pipes: [Range<Int>] = []
        var cells: [Cell] = []
        var cursor = line.lowerBound
        var index = line.lowerBound

        func closeCell(upTo end: Int) {
            let trimmed = trim(cursor..<end, in: text)
            cells.append(Cell(range: trimmed, width: characterWidth(of: trimmed, in: text)))
        }

        while index < line.upperBound {
            if text.character(at: index) == 0x7C {                    // |
                let escaped = index > line.lowerBound
                    && text.character(at: index - 1) == 0x5C          // \
                if !escaped {
                    pipes.append(index..<(index + 1))
                    closeCell(upTo: index)
                    cursor = index + 1
                }
            }
            index += 1
        }
        if cursor < line.upperBound { closeCell(upTo: line.upperBound) }

        // A leading `|` opens an empty cell before the first column, and a
        // trailing one closes an empty cell after the last. Both are notation,
        // not content, and counting them would add two phantom columns.
        if let first = cells.first, first.width == 0, pipes.first?.lowerBound == line.lowerBound {
            cells.removeFirst()
        }
        if let last = cells.last, last.width == 0, cells.count > 0 { cells.removeLast() }
        return Row(cells: cells, pipes: pipes, range: line)
    }

    /// Which way a delimiter cell's colons point.
    ///
    /// Read from the SOURCE rather than taken from swift-markdown's
    /// `Table.columnAlignments`, because this type is consumed by the styling
    /// layer, which holds text and no AST — and because the two must agree
    /// about column INDICES, which only the same split can guarantee.
    private static func alignment(ofDelimiterCell range: Range<Int>,
                                  in text: NSString) -> Alignment {
        guard range.lowerBound < range.upperBound else { return .left }
        let leading = text.character(at: range.lowerBound) == 0x3A
        let trailing = text.character(at: range.upperBound - 1) == 0x3A
        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .right
        default: return .left
        }
    }

    /// Whether a cell is a delimiter cell: optional colons around a run of at
    /// least one dash, and nothing else.
    private static func isDelimiterCell(_ range: Range<Int>, in text: NSString) -> Bool {
        guard range.lowerBound < range.upperBound else { return false }
        var sawDash = false
        for offset in range.lowerBound..<range.upperBound {
            switch text.character(at: offset) {
            case 0x2D: sawDash = true          // -
            case 0x3A: continue                // :
            default: return false
            }
        }
        return sawDash
    }

    private static func trim(_ range: Range<Int>, in text: NSString) -> Range<Int> {
        var lower = range.lowerBound
        var upper = max(range.lowerBound, range.upperBound)
        while lower < upper, isSpace(text.character(at: lower)) { lower += 1 }
        while upper > lower, isSpace(text.character(at: upper - 1)) { upper -= 1 }
        return lower..<upper
    }

    private static func characterWidth(of range: Range<Int>, in text: NSString) -> Int {
        guard range.lowerBound < range.upperBound else { return 0 }
        let slice = text.substring(with: NSRange(location: range.lowerBound,
                                                 length: range.count))
        return slice.count
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
    private static func isLineBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D }
}
