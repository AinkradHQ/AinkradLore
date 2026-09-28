import Foundation

/// What a marker span delimits.
///
/// `Sendable` because `StyleSpan` and its `Kind` are, and a marker owner rides
/// inside a `Kind`.
public enum MarkerOwner: Equatable, Sendable {
    case heading, strong, emphasis, inlineCode, codeFence, link, wikilink, blockQuote, listBullet
    /// A `~~` pair.
    case strikethrough
    /// A `==` pair.
    case highlight
    /// A footnote's `[^`…`]` (reference) or `[^`…`]:` (definition).
    case footnote
    /// A `#tag`'s own `#`. Unused by the reveal machinery — the `#` never
    /// collapses — but present so a future syntax that DOES want to
    /// distinguish "this marker belongs to a tag" from the other owners can.
    case tag
    /// A callout's `[!type]` header, which collapses like any other syntax
    /// so the rendered block shows a title rather than its own declaration.
    case callout
    /// A pipe table's `|` separators, and its `|---|` delimiter row. Both
    /// are notation the rendered table replaces with alignment and a rule.
    case tablePipe
    case tableDelimiter
    /// A math expression's `$` delimiters, and the `^`/`_`/`{}` that mark a
    /// script. Collapsed only when the expression renders exactly.
    case math
}

/// Marker ranges derived from a content span's ALREADY-RESOLVED source range.
///
/// Generalises `checkboxMarkerRange`, which already did exactly this for `[ ]`
/// and is the proof the approach works. Every range here is an absolute UTF-16
/// offset into the editor's string, matching `StyleSpan.range` — never a
/// `Character` offset, which would misplace every marker after an emoji, and
/// never arithmetic over `Character`s, which is wrong for a CRLF document
/// because `"\r\n"` is one `Character` and two UTF-16 units.
///
/// Every function returns `[]` rather than a guess when the source does not look
/// as expected. A WRONG marker range is destructive once Live Preview collapses
/// it — it hides the user's own content — so "emit nothing" is always the safe
/// failure. A missing marker is cosmetic; a wrong one makes text vanish.
enum MarkdownMarkers {

    /// Paired delimiters at both ends of `range`, e.g. `**…**`. The FIRST
    /// candidate that matches at both ends wins, so `strong` can pass
    /// `["**", "__"]` and get whichever spelling the author actually used.
    static func paired(anyOf delimiters: [String], in range: NSRange,
                       text: NSString) -> [NSRange] {
        for delimiter in delimiters {
            let found = paired(delimiter, in: range, text: text)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Paired delimiters at both ends of `range`, e.g. `**…**`.
    ///
    /// The two markers must not overlap — `**` in a two-unit range is one
    /// delimiter, not two — hence `length >= n * 2`.
    static func paired(_ delimiter: String, in range: NSRange, text: NSString) -> [NSRange] {
        let n = (delimiter as NSString).length
        guard n > 0, range.length >= n * 2,
              range.location >= 0, range.location + range.length <= text.length
        else { return [] }
        let open = NSRange(location: range.location, length: n)
        let close = NSRange(location: range.location + range.length - n, length: n)
        guard text.substring(with: open) == delimiter,
              text.substring(with: close) == delimiter else { return [] }
        return [open, close]
    }

    /// The backtick runs delimiting an inline code span, whatever their length:
    /// ``` `` a ` b `` ``` is a two-backtick span. The runs must be EQUAL in
    /// length — CommonMark requires it — and must not meet, or a lone `` ` ``
    /// would be reported as both the opening and the closing marker.
    static func backtickPair(in range: NSRange, text: NSString) -> [NSRange] {
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= text.length else { return [] }
        let end = range.location + range.length
        var open = range.location
        while open < end, text.character(at: open) == 0x60 { open += 1 }
        var close = end
        while close > range.location, text.character(at: close - 1) == 0x60 { close -= 1 }
        let openLength = open - range.location
        let closeLength = end - close
        guard openLength > 0, openLength == closeLength, open <= close else { return [] }
        return [NSRange(location: range.location, length: openLength),
                NSRange(location: close, length: closeLength)]
    }

    /// A run of `character` at the start of `range`, plus one trailing space —
    /// `### `, `> `. The space belongs to the marker: hiding the hashes but
    /// keeping the space indents the line by one, which reads as a bug.
    static func linePrefix(_ character: Character, in range: NSRange,
                           text: NSString) -> [NSRange] {
        guard range.location >= 0, range.location < text.length,
              let scalar = character.unicodeScalars.first?.value else { return [] }
        var end = range.location
        let limit = min(range.location + range.length, text.length)
        while end < limit, text.character(at: end) == scalar { end += 1 }
        guard end > range.location else { return [] }
        if end < limit, text.character(at: end) == 0x20 { end += 1 }
        return [NSRange(location: range.location, length: end - range.location)]
    }

    /// The bullet or ordinal that opens a list item — `- `, `* `, `+ `, `1. `,
    /// `2) ` — INCLUDING its trailing space, for the same reason as
    /// `linePrefix`.
    ///
    /// Nothing is emitted unless a space actually follows the marker: without
    /// one it is not a list marker at all, and this range is only ever consulted
    /// because the parser already said the item exists.
    static func listBullet(in range: NSRange, text: NSString) -> [NSRange] {
        guard range.location >= 0, range.location < text.length else { return [] }
        let limit = min(range.location + range.length, text.length)
        var end = range.location
        let first = text.character(at: end)
        if first == 0x2D || first == 0x2A || first == 0x2B {           // - * +
            end += 1
        } else if first >= 0x30, first <= 0x39 {                       // 0-9
            while end < limit, text.character(at: end) >= 0x30,
                  text.character(at: end) <= 0x39 { end += 1 }
            guard end < limit else { return [] }
            let delimiter = text.character(at: end)
            guard delimiter == 0x2E || delimiter == 0x29 else { return [] } // . )
            end += 1
        } else {
            return []
        }
        guard end < limit, text.character(at: end) == 0x20 else { return [] }
        return [NSRange(location: range.location, length: end + 1 - range.location)]
    }

    /// The opening and closing fence LINES of a fenced code block, whole. An
    /// info string (```` ```swift ````) is part of the opening marker: it is
    /// syntax, not content.
    ///
    /// An INDENTED code block yields nothing — its first line is not a fence —
    /// which is exactly the "emit nothing when unsure" rule, and an unterminated
    /// fence yields one marker rather than a guessed second one.
    static func fences(in range: NSRange, text: NSString) -> [NSRange] {
        guard range.location >= 0, range.length > 0,
              range.location + range.length <= text.length else { return [] }
        let limit = range.location + range.length

        func line(at start: Int) -> NSRange {
            var end = start
            while end < limit, text.character(at: end) != 0x0A { end += 1 }
            return NSRange(location: start, length: end - start)
        }
        func isFenceLine(_ ns: NSRange) -> Bool {
            let trimmed = text.substring(with: ns).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }

        let opening = line(at: range.location)
        guard opening.length > 0, isFenceLine(opening) else { return [] }

        // Walk back from the end to the last newline; that is the closing line.
        var closeStart = limit
        while closeStart > range.location, text.character(at: closeStart - 1) != 0x0A {
            closeStart -= 1
        }
        let closing = line(at: closeStart)
        guard closing.location > opening.location + opening.length,
              closing.length > 0, isFenceLine(closing)
        else { return [opening] }   // an unterminated fence has one marker, not two
        return [opening, closing]
    }

    /// `[` and `](target)` for an inline markdown link. The target is part of
    /// the closing marker: Live Preview hides the URL and shows the link text.
    ///
    /// Only the plain `[text](target)` shape is recognised. An autolink, a
    /// reference link or anything else yields nothing rather than a guess.
    static func inlineLink(in range: NSRange, text: NSString) -> [NSRange] {
        guard range.location >= 0, range.length >= 4,
              range.location + range.length <= text.length else { return [] }
        let limit = range.location + range.length
        guard text.character(at: range.location) == 0x5B,          // [
              text.character(at: limit - 1) == 0x29 else { return [] }  // )
        // Search backwards: the LAST `](` in the range opens the destination.
        let body = NSRange(location: range.location + 1, length: range.length - 1)
        let divider = text.range(of: "](", options: .backwards, range: body)
        guard divider.location != NSNotFound else { return [] }
        return [NSRange(location: range.location, length: 1),
                NSRange(location: divider.location, length: limit - divider.location)]
    }

    /// `[[` and `]]` around a wikilink whose CONTENT span covers only the
    /// target — `[[Target|Display]]` puts the closing brackets past the display
    /// text, so the closer is searched for on the target's own LINE and nowhere
    /// else. A `]]` on a later line belongs to some other link.
    static func wikilinkBrackets(around target: NSRange, text: NSString) -> [NSRange] {
        guard target.location >= 0, target.length >= 0,
              target.location + target.length <= text.length else { return [] }
        // Skip back over the whitespace `[[  Target  ]]` trims off the target.
        var open = target.location
        while open > 0, text.character(at: open - 1) == 0x20
            || text.character(at: open - 1) == 0x09 { open -= 1 }
        guard open >= 2,
              text.substring(with: NSRange(location: open - 2, length: 2)) == "[["
        else { return [] }

        var lineEnd = target.location + target.length
        while lineEnd < text.length, text.character(at: lineEnd) != 0x0A { lineEnd += 1 }
        let tail = NSRange(location: target.location + target.length,
                           length: lineEnd - (target.location + target.length))
        let close = text.range(of: "]]", options: [], range: tail)
        guard close.location != NSNotFound else { return [] }
        return [NSRange(location: open - 2, length: 2), close]
    }
}
