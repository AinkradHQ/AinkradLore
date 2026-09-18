import Foundation

/// Converts cmark's 1-based line/column positions into UTF-16 offsets in the
/// EDITOR's string.
///
/// Three separate hazards make this non-trivial, and all three have bitten this
/// codebase before:
///
/// * **Line endings.** `"\r\n"` is ONE Swift `Character` but TWO UTF-16 code
///   units. A previous milestone found that `split(separator: "\n")` never
///   splits a CRLF document at all, so a Windows-authored note scanned as a
///   single line. Line starts are therefore found by scanning UTF-16 units,
///   not by splitting on Characters.
/// * **Columns are BYTES.** cmark counts UTF-8 bytes, not characters and not
///   UTF-16 units. `é` is 2 bytes / 1 unit; `👍` is 4 bytes / 2 units.
/// * **Frontmatter.** The parser sees the body; the editor holds the whole
///   file. `bodyUTF16Offset` shifts every result.
///
/// Out-of-range positions return `nil` rather than clamping. A dropped span is
/// invisible; a span applied to the wrong range is a visible defect and, if it
/// ever drove an edit, a destructive one.
public struct SourceOffsetMap: Sendable {
    /// UTF-16 offset (relative to the body) where each 1-based line begins.
    private let lineStarts: [Int]
    /// Per line, the UTF-16 offset of each 1-based UTF-8 byte column.
    private let columnTables: [[Int]]
    private let bodyUTF16Offset: Int
    private let bodyUTF16Length: Int

    public init(body: String, bodyUTF16Offset: Int) {
        self.bodyUTF16Offset = bodyUTF16Offset
        let units = Array(body.utf16)
        self.bodyUTF16Length = units.count

        var starts: [Int] = [0]
        var tables: [[Int]] = []
        var currentLineStart = 0
        var i = 0
        while i < units.count {
            let unit = units[i]
            let isCR = unit == 0x000D
            let isLF = unit == 0x000A
            if isCR || isLF {
                tables.append(Self.columnTable(of: units, from: currentLineStart, to: i))
                // CRLF counts as one line break spanning two UTF-16 units.
                if isCR, i + 1 < units.count, units[i + 1] == 0x000A { i += 1 }
                i += 1
                currentLineStart = i
                starts.append(currentLineStart)
                continue
            }
            i += 1
        }
        tables.append(Self.columnTable(of: units, from: currentLineStart, to: units.count))
        self.lineStarts = starts
        self.columnTables = tables
    }

    /// Maps each 1-based UTF-8 byte column on one line to a UTF-16 offset.
    ///
    /// Built by walking the line's scalars once: each scalar contributes its
    /// UTF-8 length in byte columns, all pointing at the UTF-16 offset where
    /// that scalar starts. A column landing mid-scalar therefore resolves to
    /// that scalar's start, which is the only sane answer.
    private static func columnTable(of units: [UInt16], from start: Int, to end: Int) -> [Int] {
        let slice = Array(units[start..<end])
        let line = String(decoding: slice, as: UTF16.self)
        var table: [Int] = []
        var utf16Offset = start
        for scalar in line.unicodeScalars {
            let byteCount = String(scalar).utf8.count
            let unitCount = String(scalar).utf16.count
            for _ in 0..<byteCount { table.append(utf16Offset) }
            utf16Offset += unitCount
        }
        // One past the end, so a column pointing at the line terminator maps.
        table.append(utf16Offset)
        return table
    }

    public func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= columnTables.count, column >= 1 else { return nil }
        let table = columnTables[line - 1]
        guard column <= table.count else { return nil }
        return bodyUTF16Offset + table[column - 1]
    }

    public func utf16Range(fromLine: Int, fromColumn: Int,
                           toLine: Int, toColumn: Int) -> NSRange? {
        guard let lower = utf16Offset(line: fromLine, column: fromColumn),
              let upper = utf16Offset(line: toLine, column: toColumn),
              upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}
