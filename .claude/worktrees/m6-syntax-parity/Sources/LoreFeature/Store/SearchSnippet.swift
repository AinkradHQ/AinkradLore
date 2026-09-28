import Foundation

/// A matched excerpt from a document, and where inside it the query matched.
///
/// ## Why search needed this
///
/// `store.search(query)` returned `[IndexRow]` and the sidebar rendered the
/// same rows it renders while browsing: a title and nothing else. So the
/// answer to "which of these nine notes mentions the thing I typed, and in
/// what context" was "open them and find out". The capability already existed
/// one function away — `LoreStore.context(in:for:)` extracts the matching line
/// for BACKLINKS — it just was not offered to the one feature named after it.
///
/// The excerpt comes from SQLite's own `snippet()`, not from re-reading files.
/// That matters at vault scale: a 17,000-object vault with 200 hits would
/// otherwise mean 200 file reads on the main actor to draw one list.
public struct SearchSnippet: Equatable, Sendable {
    /// The excerpt, with the markers stripped.
    public let text: String
    /// Ranges within `text` that matched the query, in order.
    public let matches: [Range<String.Index>]

    public init(text: String, matches: [Range<String.Index>]) {
        self.text = text
        self.matches = matches
    }

    /// Sentinels handed to FTS5's `snippet()` as its open/close markers.
    ///
    /// C0 control characters, not `<b>`/`</b>` or `**`. The excerpt is document
    /// text, and any printable delimiter is a delimiter a document can legally
    /// contain — a note containing the literal string `<b>` would otherwise
    /// parse as a match and highlight the wrong span. These two code points
    /// cannot appear in the plaintext an engine indexes, so the parse is
    /// unambiguous.
    static let open = "\u{2}"
    static let close = "\u{3}"

    /// Splits a `snippet()` result into plain text plus match ranges.
    ///
    /// Pure, so the parsing is asserted directly rather than through SQLite —
    /// which also means the tests do not need a database to cover the cases
    /// that actually break parsers: adjacent matches, a match at either end,
    /// and an unbalanced marker.
    ///
    /// Tolerant of a trailing unbalanced open marker (returns the rest as an
    /// unmatched tail rather than dropping it). A malformed snippet should
    /// degrade to "no highlight", never to "no result" — the row is still a
    /// real hit.
    public static func parse(marked: String) -> SearchSnippet {
        var text = ""
        var matches: [Range<String.Index>] = []
        var pendingStart: String.Index?
        var index = marked.startIndex

        while index < marked.endIndex {
            let character = marked[index]
            if String(character) == open {
                pendingStart = text.endIndex
            } else if String(character) == close {
                if let start = pendingStart {
                    matches.append(start..<text.endIndex)
                    pendingStart = nil
                }
                // A close with no open is dropped: nothing sensible to mark.
            } else {
                text.append(character)
            }
            index = marked.index(after: index)
        }
        return SearchSnippet(text: text, matches: matches)
    }
}

public extension SearchSnippet {
    /// The excerpt as styled text, matches emphasised.
    ///
    /// Built by CONCATENATING runs — unmatched piece, matched piece, unmatched
    /// piece — rather than by applying attributes to ranges after the fact.
    /// `String.Index` and `AttributedString.Index` are different index spaces,
    /// and translating between them by counting characters is both fiddly and
    /// wrong the moment the text contains anything outside the BMP (an emoji
    /// in a note is not exotic). Concatenation never needs the translation.
    ///
    /// `styleMatch` is passed in rather than hard-coded so this stays free of
    /// SwiftUI colour and can be asserted on the plain string.
    func attributed(styleMatch: (inout AttributedString) -> Void) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for match in matches where match.lowerBound >= cursor {
            out.append(AttributedString(String(text[cursor..<match.lowerBound])))
            var highlighted = AttributedString(String(text[match]))
            styleMatch(&highlighted)
            out.append(highlighted)
            cursor = match.upperBound
        }
        out.append(AttributedString(String(text[cursor...])))
        return out
    }
}

/// One search result: the document, and why it matched.
public struct SearchHit: Identifiable, Sendable {
    public var id: URL { row.path }
    public let row: IndexRow
    /// Nil when the match was in the TITLE only, or when the document has no
    /// indexable text (an attachment). A title match needs no excerpt — the
    /// title is already the row's headline — and inventing one from an empty
    /// body would show a blank line under every attachment hit.
    public let snippet: SearchSnippet?

    public init(row: IndexRow, snippet: SearchSnippet?) {
        self.row = row
        self.snippet = snippet
    }
}
