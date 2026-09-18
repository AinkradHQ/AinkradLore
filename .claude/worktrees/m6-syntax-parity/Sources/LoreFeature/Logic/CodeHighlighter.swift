import Foundation

/// One coloured run inside a fenced code block.
struct CodeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case comment, string, number, keyword, type
    }
    let range: Range<Int>
    let kind: Kind
}

/// A single-pass scanner over a fence's contents.
///
/// Not a parser and not trying to be. It answers the four questions a reader's
/// eye actually asks of code — where do the comments stop, where do the strings
/// stop, which words are the language's own, which are numbers — and nothing
/// else. `CodeGrammar` holds the per-language data; this holds the one scan
/// that consumes it, so adding a language is a table entry rather than code.
///
/// ORDER IS THE WHOLE ALGORITHM. Comments before strings, strings before
/// everything: `// "unterminated` is a comment, not a broken string, and
/// `"// not a comment"` is a string. Getting that backwards is how a
/// highlighter paints half a file the colour of a comment.
///
/// UTF-16 throughout, in absolute offsets into the editor's string, matching
/// `StyleSpan.range`. Never `Character` offsets, which would misplace every
/// token after an emoji in a comment.
enum CodeHighlighter {

    /// Above this much code, don't. A fence this long is machine-generated
    /// output pasted into a note, the tokens would be off-screen anyway, and
    /// the scan is the one part of a render that grows with the fence rather
    /// than with the viewport.
    static let maximumLength = 40_000

    static func tokens(in text: NSString, range: NSRange,
                       grammar: CodeGrammar) -> [CodeToken] {
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              range.length > 0, range.length <= maximumLength else { return [] }
        var out: [CodeToken] = []
        var index = range.location
        let end = NSMaxRange(range)

        while index < end {
            // 1. Line comments, longest marker first (see `CodeGrammar`).
            if let marker = grammar.lineCommentUnits.first(where: {
                matches($0, at: index, in: text, limit: end)
            }) {
                var scan = index + marker.count
                while scan < end, !isLineBreak(text.character(at: scan)) { scan += 1 }
                out.append(CodeToken(range: index..<scan, kind: .comment))
                index = scan
                continue
            }

            // 2. Block comments. An UNTERMINATED one runs to the end of the
            // fence rather than being abandoned: that is what the compiler
            // would do with it, and showing the rest as live code would be a
            // lie about what the snippet means.
            if !grammar.blockOpenUnits.isEmpty,
               matches(grammar.blockOpenUnits, at: index, in: text, limit: end) {
                var scan = index + grammar.blockOpenUnits.count
                while scan < end,
                      !matches(grammar.blockCloseUnits, at: scan, in: text, limit: end) {
                    scan += 1
                }
                if scan < end { scan = min(end, scan + grammar.blockCloseUnits.count) }
                out.append(CodeToken(range: index..<scan, kind: .comment))
                index = scan
                continue
            }

            // 3. Strings.
            if let delimiter = grammar.stringDelimiterUnits.first(where: {
                matches($0, at: index, in: text, limit: end)
            }) {
                let closed = scanString(from: index, delimiter: delimiter,
                                        in: text, limit: end, grammar: grammar)
                out.append(CodeToken(range: index..<closed, kind: .string))
                index = closed
                continue
            }

            let unit = text.character(at: index)

            // 4. Numbers. Only where a number can START — `foo2` is one
            // identifier, not `foo` followed by a number.
            if isDigit(unit) {
                var scan = index
                while scan < end, isNumberBody(text.character(at: scan)) { scan += 1 }
                out.append(CodeToken(range: index..<scan, kind: .number))
                index = scan
                continue
            }

            // 5. Words.
            if isIdentifierStart(unit) {
                var scan = index
                while scan < end,
                      isIdentifierBody(text.character(at: scan),
                                       hyphens: grammar.identifiersMayContainHyphen) {
                    scan += 1
                }
                let word = text.substring(with: NSRange(location: index,
                                                        length: scan - index))
                if grammar.keywords.contains(word) {
                    out.append(CodeToken(range: index..<scan, kind: .keyword))
                } else if grammar.types.contains(word) {
                    out.append(CodeToken(range: index..<scan, kind: .type))
                }
                index = scan
                continue
            }

            index += 1
        }
        return out
    }

    /// Where the string opened at `start` ends — the offset PAST its closing
    /// delimiter, or past the run the language would consider it to occupy.
    ///
    /// A single-character delimiter does not survive a line break: an
    /// unterminated `"` is a typo, and letting it swallow the rest of the fence
    /// would colour the whole snippet as a string. A multi-character one
    /// (`"""`, `'''`) is explicitly multi-line and does.
    private static func scanString(from start: Int, delimiter: [UInt16],
                                   in text: NSString, limit end: Int,
                                   grammar: CodeGrammar) -> Int {
        let width = delimiter.count
        var index = start + width
        while index < end {
            if grammar.hasBackslashEscapes, text.character(at: index) == 0x5C {
                index += 2
                continue
            }
            if matches(delimiter, at: index, in: text, limit: end) {
                return min(end, index + width)
            }
            if width == 1, isLineBreak(text.character(at: index)) { return index }
            index += 1
        }
        return end
    }

    // MARK: - Character classes

    private static func matches(_ units: [UInt16], at index: Int,
                                in text: NSString, limit: Int) -> Bool {
        guard !units.isEmpty, index + units.count <= limit else { return false }
        for (offset, unit) in units.enumerated()
        where text.character(at: index + offset) != unit { return false }
        return true
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }

    private static func isDigit(_ unit: unichar) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    /// Digits, letters (hex, and the `e` of an exponent), `.`, and `_` as a
    /// digit separator. Deliberately loose: over-consuming `0xFF_00` as one
    /// number is right, and the only cost of being loose is that a malformed
    /// literal is coloured as a number, which it was trying to be.
    private static func isNumberBody(_ unit: unichar) -> Bool {
        isDigit(unit) || unit == 0x2E || unit == 0x5F
            || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    /// A letter, `_`, `$`, `@`, `#`, or anything non-ASCII.
    ///
    /// `@` and `#` are included because several grammars here list words that
    /// begin with them — `@MainActor`, `#include`, `#pragma` — and a scanner
    /// that stopped at the sigil would look those words up without it and never
    /// match. Non-ASCII is included so an identifier in any script scans as one
    /// word rather than fragmenting.
    private static func isIdentifierStart(_ unit: unichar) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit == 0x24 || unit == 0x40 || unit == 0x23
            || unit > 0x7F
    }

    private static func isIdentifierBody(_ unit: unichar, hyphens: Bool) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || (hyphens && unit == 0x2D)
    }
}
