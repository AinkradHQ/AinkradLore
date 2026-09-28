import Foundation

/// The four markdown syntaxes `swift-markdown` has no node for: `==highlight==`,
/// footnotes, `#tags` and `^block-ids`.
///
/// ## Why one scanner and not four
///
/// Highlight, strikethrough and math all use repeated ASCII punctuation and all
/// can nest. Four independent passes would make the precedence between them
/// EMERGENT — whichever happened to run first would win, and `==a $b== c$` would
/// have no defined answer. One ordered pass makes the precedence a stated
/// decision with a test per adjacent pair. See `order` below.
///
/// ## The rules it inherits
///
/// From `MarkdownMath`, whose shape this copies: the scanner may never CHANGE
/// THE TEXT. Every offset the index, the link graph and the MCP tools hold is
/// measured against the unmodified source.
///
/// From `MarkdownMarkers`: a malformed span emits NOTHING rather than a guess.
/// A missing span is cosmetic; a wrong one hides the user's own content once
/// Live Preview collapses it.
///
/// Every range is an absolute UTF-16 offset into the editor's full string,
/// frontmatter included — matching `StyleSpan.range`. Never `Character`
/// offsets, which misplace every span after an emoji.
public enum MarkdownExtensions {

    public struct Span: Equatable, Sendable {
        /// The whole source form, delimiters included.
        public let range: Range<Int>
        /// Between the delimiters. Equal to `range` for kinds that have none.
        public let content: Range<Int>
        public let kind: Kind
    }

    public enum Kind: Equatable, Sendable {
        case highlight
        case footnoteReference(label: String)
        case footnoteDefinition(label: String)
        case tag(name: String)
        case blockID(id: String)
    }

    /// A mutable "is this offset already spoken for" bitmap — one `Bool` per
    /// UTF-16 offset in the scanned string.
    ///
    /// Replaces the linear scan over `found` that `isClaimed` used to do.
    /// `found` grows over the course of one `scan` call — up to one entry per
    /// matched span — and `isClaimed` is queried once per CANDIDATE character
    /// in every scanner, so scanning it linearly was O(spans × candidates):
    /// unnoticeable while a document has a handful of highlights and
    /// footnotes, quadratic once a document is heavy in extension syntax —
    /// exactly the shape of Task 12's benchmark. A prebuilt `CodeRegionIndex`
    /// (the fix already used for `masked` and `linkRanges`, both fixed once
    /// per `scan` call before any scanner runs) does not fit here, because
    /// `found` is appended to WHILE the scan runs — rebuilding a sorted,
    /// coalesced index after every single append would cost more than the
    /// linear scan it replaced. A flat bitmap gives O(1) queries and O(range
    /// length) updates, and O(n) memory in bytes — negligible beside the
    /// text itself.
    struct ClaimedBitmap {
        private var claimed: [Bool]

        init(length: Int) { claimed = Array(repeating: false, count: length) }

        /// Marks every offset in `range` claimed. Clamped to the bitmap's
        /// bounds so a span whose range was computed against a different
        /// string (should never happen, but "emit nothing rather than crash"
        /// extends to this too) cannot trap.
        mutating func mark(_ range: Range<Int>) {
            let lower = max(0, range.lowerBound)
            let upper = min(claimed.count, range.upperBound)
            guard lower < upper else { return }
            for i in lower..<upper { claimed[i] = true }
        }

        func contains(_ offset: Int) -> Bool {
            offset >= 0 && offset < claimed.count && claimed[offset]
        }
    }

    /// Scans `text`, skipping every range in `masked`.
    ///
    /// `masked` carries the code regions AND the math expressions — computed by
    /// `MarkdownDocumentModel` and `MarkdownMath` respectively, and passed in
    /// rather than recomputed here so there is exactly one answer to "is this
    /// offset inside code" in the whole editor.
    ///
    /// - Parameter linkRanges: a `#` inside one of these (a link target or a
    ///   wikilink's fragment) is never a tag — see `scanTags`.
    static func scan(_ text: NSString, masked: [Range<Int>],
                     linkRanges: [Range<Int>] = []) -> [Span] {
        var found: [Span] = []
        var claimed = ClaimedBitmap(length: text.length)
        // Built ONCE per scan, not per character: `isClaimed` used to
        // construct a fresh `CodeRegionIndex` on every call, an O(n log n)
        // sort-and-coalesce paid once per offset scanned — O(n² log n)
        // overall, strictly worse than the linear scan it replaced. See
        // `MarkdownDocumentModel.swift:31-34`.
        let index = CodeRegionIndex(regions: masked.map {
            CodeRegion(range: NSRange(location: $0.lowerBound, length: $0.count),
                       kind: .fencedCodeBlock)
        }, kinds: nil)
        // `linkRanges` gets the SAME treatment as `masked` above and for the
        // same reason: `scanTags` used to test membership with
        // `linkRanges.contains(where: { $0.contains(i) })`, a linear scan
        // over every link range evaluated once per `#` candidate. On a
        // document with L link ranges and T `#` candidates that is O(L × T)
        // — on `MarkdownSavePathBenchmark.largeBody` (~5,000 wikilinks,
        // ~5,000 headings) that was ~25M closure calls per parse and turned
        // an 0.9 s benchmark into 1204 s. Built once here, reusing
        // `CodeRegionIndex` rather than inventing a second structure for
        // the same shape of data — same fix as the note above, and the same
        // bug this exact file already fixed once for the code mask.
        let linkIndex = CodeRegionIndex(regions: linkRanges.map {
            CodeRegion(range: NSRange(location: $0.lowerBound, length: $0.count),
                       kind: .fencedCodeBlock)
        }, kinds: nil)
        // THE ORDER IS THE CONTRACT. Each scanner appends in the order
        // listed, and `isClaimed` stops a later one from taking an offset an
        // earlier one already has — that is what makes the precedence below
        // a stated decision rather than an accident of which function
        // happened to run first. Every adjacent pair has a test in
        // `MarkdownExtensionsPrecedenceTests`. Do not reorder without moving
        // the tests with it.
        //
        // 1-2. Code regions and math arrive already masked, from
        //      `MarkdownDocumentModel` and `MarkdownMath`. They are not
        //      rescanned here — one answer to "is this inside code", not two.
        scanHighlights(text, masked: index, found: &found, claimed: &claimed)   // 3
        scanFootnotes(text, masked: index, found: &found, claimed: &claimed)    // 4, 5
        scanTags(text, masked: index, found: &found, claimed: &claimed, linkIndex: linkIndex) // 6
        scanBlockIDs(text, masked: index, found: &found, claimed: &claimed)     // 7
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `^block-id`, anchored to the END of a line and preceded by whitespace.
    ///
    /// Runs LAST, after math is masked: `^` is superscript inside `$…$`, and a
    /// block ID scanned first would claim it before the math scan could.
    private static func scanBlockIDs(_ text: NSString, masked: CodeRegionIndex,
                                     found: inout [Span], claimed: inout ClaimedBitmap) {
        var i = 0
        while i < text.length {
            guard text.character(at: i) == 0x5E,          // ^
                  !isClaimed(i, masked: masked, claimed: claimed) else { i += 1; continue }
            // Must be preceded by whitespace: `caret^abc` is one word.
            guard i > 0 else { i += 1; continue }
            let before = text.character(at: i - 1)
            guard before == 0x20 || before == 0x09 else { i += 1; continue }
            var j = i + 1
            while j < text.length {
                let u = text.character(at: j)
                let ok = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A)
                    || (u >= 0x61 && u <= 0x7A) || u == 0x2D
                guard ok else { break }
                j += 1
            }
            // The id is sliced from the SOURCE over the matched UTF-16 range
            // in one operation, not built scalar-by-scalar — same reasoning
            // as `scanTags`' `name`, even though this charset (letters,
            // digits, hyphen) cannot itself contain a surrogate pair: the
            // guard above is what must be trusted, not the accumulator.
            let id = text.substring(with: NSRange(location: i + 1, length: j - (i + 1)))
            // Must run to the end of the line — a block ID is a trailing
            // anchor, not something in the middle of a sentence.
            let atLineEnd = j >= text.length || text.character(at: j) == 0x0A
                || text.character(at: j) == 0x0D
            guard !id.isEmpty, atLineEnd else { i = max(j, i + 1); continue }
            found.append(Span(range: i..<j, content: (i + 1)..<j, kind: .blockID(id: id)))
            claimed.mark(i..<j)
            i = j
        }
    }

    /// `#tag`, `#nested/tag`.
    ///
    /// `#` is the most overloaded character in markdown — heading marker,
    /// wikilink fragment separator, URL anchor, shebang — so this is mostly a
    /// list of disqualifications. Every one of them has a test.
    private static func scanTags(_ text: NSString, masked: CodeRegionIndex,
                                 found: inout [Span], claimed: inout ClaimedBitmap,
                                 linkIndex: CodeRegionIndex) {
        var i = 0
        while i < text.length {
            guard text.character(at: i) == 0x23,          // #
                  !isClaimed(i, masked: masked, claimed: claimed),
                  !linkIndex.contains(i) else { i += 1; continue }
            // A heading: `#`(s) at line start, then a space. The AST owns it.
            if isAtLineStart(i, text: text) {
                var h = i
                while h < text.length, text.character(at: h) == 0x23 { h += 1 }
                if h < text.length, text.character(at: h) == 0x20 { i = h; continue }
            }
            var j = i + 1
            var hasNonDigit = false
            while j < text.length {
                let u = text.character(at: j)
                let isDigit = (u >= 0x30 && u <= 0x39)
                let isLetter = (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u > 0x7F
                let isJoiner = u == 0x5F || u == 0x2D || u == 0x2F    // _ - /
                guard isDigit || isLetter || isJoiner else { break }
                if isLetter || isJoiner { hasNonDigit = true }
                j += 1
            }
            // The name is sliced from the SOURCE over the matched UTF-16
            // range in one operation, not built scalar-by-scalar — a
            // surrogate pair (an astral character, e.g. an emoji) split
            // across two UTF-16 units would otherwise mangle into "?" per
            // unit, and a tag name flows into the index, the sidebar chip
            // row and the MCP tools, where two different emoji tags
            // collapsing to the same string is a real collision.
            let name = text.substring(with: NSRange(location: i + 1, length: j - (i + 1)))
            // At least one non-digit, or `#1234` (an issue reference) becomes a
            // tag and every changelog in the vault fills with them.
            guard hasNonDigit, !name.isEmpty else { i += 1; continue }
            // A trailing `/` is notation the author was mid-typing, not part of
            // the name — but it stays inside the SPAN so the chip does not
            // visibly clip while they type.
            let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard !trimmed.isEmpty else { i += 1; continue }
            found.append(Span(range: i..<j, content: (i + 1)..<j, kind: .tag(name: trimmed)))
            claimed.mark(i..<j)
            i = j
        }
    }

    /// `[^label]` and, at line start, `[^label]:`.
    ///
    /// The definition is checked FIRST at each candidate, because `[^1]:` at
    /// line start is a definition and the same characters mid-line are a
    /// reference — the two differ only by position, so one scan decides both
    /// rather than two scans racing.
    private static func scanFootnotes(_ text: NSString, masked: CodeRegionIndex,
                                      found: inout [Span], claimed: inout ClaimedBitmap) {
        var i = 0
        while i + 2 < text.length {
            guard text.character(at: i) == 0x5B,          // [
                  text.character(at: i + 1) == 0x5E,      // ^
                  !isClaimed(i, masked: masked, claimed: claimed) else { i += 1; continue }
            // A preceding `!` makes this an embed, never a footnote.
            if i > 0, text.character(at: i - 1) == 0x21 { i += 1; continue }
            var j = i + 2
            var valid = true
            while j < text.length, text.character(at: j) != 0x5D {   // ]
                let u = text.character(at: j)
                // No whitespace in a label — that is what separates a footnote
                // from a bracketed aside the author wrote by hand. `0x0D`
                // alongside `0x0A`: "\r\n" is two UTF-16 units and either half
                // alone still means "not a label" — see `scanHighlights` and
                // `isAtLineStart`, which the same CRLF consistency pass fixed.
                if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D { valid = false; break }
                j += 1
            }
            guard valid, j < text.length, j > i + 2 else { i += 1; continue }
            // The label is sliced from the SOURCE over the matched UTF-16
            // range in one operation, not built scalar-by-scalar — the exact
            // bug this branch already fixed for `scanTags`' `name` and
            // `scanBlockIDs`' `id`, see their comments. Building it one
            // `UnicodeScalar(u)` at a time turned a surrogate pair (an
            // astral label character) into `"?"` per unit, so `[^🎈]` and
            // `[^🎉]` both produced the label `"??"` and collided — and the
            // label is the key `jumpFootnote` matches on, so the jump landed
            // on the wrong footnote.
            let label = text.substring(with: NSRange(location: i + 2, length: j - (i + 2)))
            let closeEnd = j + 1
            let atLineStart = isAtLineStart(i, text: text)
            let isDefinition = atLineStart && closeEnd < text.length
                && text.character(at: closeEnd) == 0x3A          // :
            let end = isDefinition ? closeEnd + 1 : closeEnd
            found.append(Span(range: i..<end, content: (i + 2)..<j,
                              kind: isDefinition ? .footnoteDefinition(label: label)
                                                 : .footnoteReference(label: label)))
            claimed.mark(i..<end)
            i = end
        }
    }

    /// Whether `offset` starts a line, allowing up to three leading spaces —
    /// CommonMark's own indent tolerance.
    private static func isAtLineStart(_ offset: Int, text: NSString) -> Bool {
        var k = offset - 1
        var spaces = 0
        while k >= 0, spaces <= 3 {
            let u = text.character(at: k)
            // `0x0D` alongside `0x0A`: a lone `"\r"` (old Mac line ending)
            // terminates a line exactly as `"\n"` does, and treating only
            // `0x0A` as a terminator was the one inconsistency left between
            // this and `scanBlockIDs`' `atLineEnd`, which already checks
            // both.
            if u == 0x0A || u == 0x0D { return true }
            if u == 0x20 { spaces += 1; k -= 1; continue }
            return false
        }
        return k < 0
    }

    /// `==text==`. Paired, equal delimiters, SINGLE LINE — Obsidian's own
    /// behaviour, and the constraint that keeps a stray `==` from swallowing
    /// the rest of a document.
    private static func scanHighlights(_ text: NSString, masked: CodeRegionIndex,
                                       found: inout [Span], claimed: inout ClaimedBitmap) {
        var i = 0
        while i + 1 < text.length {
            guard text.character(at: i) == 0x3D, text.character(at: i + 1) == 0x3D,
                  !isClaimed(i, masked: masked, claimed: claimed) else { i += 1; continue }
            let contentStart = i + 2
            var j = contentStart
            // Stop at the line end: an unclosed `==` must emit nothing, not
            // run on. Both halves of a CRLF terminator stop the scan, not
            // just `0x0A` — `"\r\n"` is two UTF-16 units, and checking only
            // one of them left a highlight free to run across a CRLF break
            // it should have stopped at, inconsistent with `scanBlockIDs`
            // and `isAtLineStart`, which already check both.
            while j + 1 < text.length, text.character(at: j) != 0x0A, text.character(at: j) != 0x0D {
                if text.character(at: j) == 0x3D, text.character(at: j + 1) == 0x3D { break }
                j += 1
            }
            guard j + 1 < text.length,
                  text.character(at: j) == 0x3D, text.character(at: j + 1) == 0x3D,
                  j > contentStart,                                  // non-empty
                  !isClaimed(j, masked: masked, claimed: claimed) else { i += 1; continue }
            found.append(Span(range: i..<(j + 2), content: contentStart..<j, kind: .highlight))
            claimed.mark(i..<(j + 2))
            i = j + 2
        }
    }

    /// Whether `offset` is inside a masked region or an already-emitted span.
    ///
    /// `masked` is a pre-built `CodeRegionIndex`, constructed ONCE per `scan`
    /// call by the caller, not rebuilt here per character — see `scan`.
    /// `claimed` is the bitmap every scanner marks as it appends to `found` —
    /// see `ClaimedBitmap` — so this is two O(1)/O(log n) checks, never a
    /// scan over a collection that grows with the document.
    static func isClaimed(_ offset: Int, masked: CodeRegionIndex,
                          claimed: ClaimedBitmap) -> Bool {
        masked.contains(offset) || claimed.contains(offset)
    }
}
