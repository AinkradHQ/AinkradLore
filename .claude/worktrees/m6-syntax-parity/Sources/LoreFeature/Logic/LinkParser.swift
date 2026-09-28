import Foundation

/// Which syntax a link was written in. Load-bearing for exactly two decisions
/// that must not be guessed from the target text alone: whether the target is
/// percent-ENCODED (markdown links are, wikilinks never are), and therefore
/// whether a rewritten target must be re-encoded on the way back out.
public enum LinkSyntax: String, Equatable, Hashable, Sendable {
    case wikilink
    case markdown
}

/// One outbound link found in a document.
public struct DocumentLink: Equatable, Sendable {
    /// The target exactly as written, including any `#Heading` or `#^block`
    /// fragment. Never includes the `|display` part.
    ///
    /// Stored verbatim because rename rewriting must reproduce the user's own
    /// syntax: a link written `[[design]]` becomes `[[new-name]]`, never
    /// `[[Projects/New Name.md]]`. For a markdown link this is also the
    /// possibly percent-ENCODED form — see `resolutionTarget`.
    public let rawTarget: String
    public let displayText: String?
    public let isEmbed: Bool
    public let syntax: LinkSyntax

    public init(rawTarget: String, displayText: String? = nil, isEmbed: Bool = false,
                syntax: LinkSyntax = .wikilink) {
        self.rawTarget = rawTarget; self.displayText = displayText; self.isEmbed = isEmbed
        self.syntax = syntax
    }

    /// The target to hand `LinkResolver` — percent-DECODED for a markdown link.
    ///
    /// Obsidian writes `[text](Design%20Doc.md)` for any name containing a
    /// space in markdown-link mode. Resolved raw, that link finds nothing: it
    /// is stored with `target_path NULL`, contributes no backlink, and — worst
    /// — is not rewritten by a rename, so it silently breaks.
    ///
    /// Wikilink targets are returned UNTOUCHED. Obsidian does not encode them,
    /// so a `%` in a `[[…]]` target is a literal `%` in a filename, and
    /// decoding it would resolve the link to the wrong document (or to none).
    public var resolutionTarget: String {
        guard syntax == .markdown, let decoded = rawTarget.removingPercentEncoding
        else { return rawTarget }
        return decoded
    }
}

/// One link together with WHERE its target text sits in the scanned string.
///
/// The offsets are CHARACTER offsets into the string handed to
/// `LinkParser.spans(in:)`, and they cover the raw target only — not the
/// brackets, not the `|display` part, not a markdown link's text. They exist so
/// that `LinkRewriter` can replace a link by RANGE instead of by string search:
/// a whole-document `replacingOccurrences` also mutates every `[[Design]]`
/// written inside a fenced block or inline code, which this parser deliberately
/// excludes from the graph. One scanner, one answer.
public struct LinkSpan: Equatable, Sendable {
    public let link: DocumentLink
    public let targetRange: Range<Int>
    public init(link: DocumentLink, targetRange: Range<Int>) {
        self.link = link; self.targetRange = targetRange
    }
}

/// Extracts links from markdown body text.
///
/// Deliberately code-aware: a `[[link]]` inside a fenced block or inline code
/// is documentation ABOUT a link, not a link. The line-scanning outline this
/// module used to have (`MarkdownEngine.outline(of:)`, deleted in M2a Task 7)
/// had exactly this gap and produced phantom headings from `#` comments in
/// code; a phantom LINK would be worse, because it appears in another
/// document's backlinks and survives into rename rewriting.
public enum LinkParser {
    public static func links(in body: String) -> [DocumentLink] {
        spans(in: body).map(\.link)
    }

    /// Every link, with the character range of its target text.
    ///
    /// The single scan; `links(in:)` is a projection of it. `LinkRewriter`
    /// consumes the ranges so that the rewrite covers EXACTLY the regions the
    /// graph covers — no second, subtly different notion of "inside a code
    /// block" to keep in step.
    public static func spans(in body: String) -> [LinkSpan] {
        spans(in: body, codeRegions: nil)
    }

    /// - Parameter codeRegions: regions the caller has ALREADY computed for
    ///   this exact string, saving the parse this scan would otherwise do.
    ///   `nil` — every existing caller — parses as before. The grammar, the
    ///   kind filter and the results are identical either way; this is a
    ///   work-saving injection point, not a behaviour switch. Passing regions
    ///   computed for a DIFFERENT string (a pre-normalisation one, say) would
    ///   misplace suppression, which is why `MarkdownDocumentModel` withholds
    ///   them for CRLF documents.
    static func spans(in body: String, codeRegions: [CodeRegion]?) -> [LinkSpan] {
        spans(in: body, suppression: codeRegions.map {
            CodeRegionIndex(regions: $0, kinds: MarkdownDocumentModel.linkSuppressingKinds)
        })
    }

    /// The same injection point, pre-indexed. Callers that hold a
    /// `MarkdownDocumentModel` already have the index and should not rebuild it.
    static func spans(in body: String, suppression: CodeRegionIndex?) -> [LinkSpan] {
        scan(body, suppression: suppression).spans
    }

    /// The scan, plus the character→UTF-16 table it had to build anyway.
    ///
    /// Exposed because `WikilinkSpanBuilder` needs exactly that table to convert
    /// the spans it gets back, and building a second identical one was a second
    /// `count`-sized allocation and a second grapheme walk per parse.
    ///
    /// - Returns: `normalised` is true when the body contained CRLF and the
    ///   offsets therefore describe the NORMALISED string rather than `body` —
    ///   the caller must not use the table against `body`'s UTF-16 offsets.
    static func scan(_ body: String, suppression: CodeRegionIndex?)
        -> (spans: [LinkSpan], offsets: CharacterOffsetMap, normalised: Bool) {
        // CRLF documents — Windows-authored vaults, sync clients, `core.autocrlf`
        // checkouts — do not split on `"\n"`: Swift treats `"\r\n"` as ONE
        // Character, which is not equal to `"\n"`, so the whole file scans as a
        // single line and every fence goes undetected. Normalising first fixes
        // that, and it is offset-SAFE precisely because `"\r\n"` is one
        // Character: every span offset still indexes the caller's own string.
        let normalised = body.contains("\r\n")
        let text = normalised
            ? body.replacingOccurrences(of: "\r\n", with: "\n") : body

        // Code regions now come from the ONE markdown parse, not from a second
        // hand-written fence tracker living here. The bracket grammar below is
        // unchanged; only the answer to "is this position inside code?" moved.
        //
        // The model is built from `text` — the SAME string the character
        // offsets below index — so its UTF-16 offsets and our character offsets
        // describe one string, and `utf16OffsetForCharacterOffset` is the only
        // place the two units meet.
        // Injected regions, when the caller has them, describe this same
        // string — see the parameter's note. Otherwise parse.
        // `init(body:)`, never `init(fullText:)`. Every caller of this scan
        // hands over a body already: `MarkdownEngine` passes `note.body`,
        // `LinkRewriter` passes the slice past `Frontmatter.bodyOffset`, and
        // `WikilinkSpanBuilder` passes the string its model already indexes.
        // A frontmatter scan HERE would fire on any body opening with an `---`
        // rule and drop that whole region from the suppression index — turning
        // a `[[link]]` documented inside a fence there into a real graph edge
        // that a rename then rewrites, in a file the user never opened.
        let index = suppression ?? MarkdownDocumentModel(body: text).linkSuppressionIndex
        let utf16OffsetForCharacterOffset = CharacterOffsetMap.make(for: text)
        //
        // FENCED and INLINE code only. Indented code blocks, HTML blocks and
        // HTML comments deliberately do NOT suppress: the old hand-written
        // scanner recognised only ``` / ~~~ fences and inline spans, and
        // widening the net deletes links from the graph. A CommonMark type-6
        // HTML block runs to the next BLANK line, so `text\n<div>\n[[A]]\n
        // </div>\ntext [[R]]` swallows `[[R]]` — a link in an ordinary prose
        // line — which a rename would then silently stop rewriting.
        //
        // The kind filter now lives in the INDEX, applied when it was built —
        // `MarkdownDocumentModel.linkSuppressionIndex`, or the conversion in
        // `spans(in:codeRegions:)` above. Same set, same answer, O(log n).
        let isInsideCode: (Int) -> Bool = { characterOffset in
            guard characterOffset >= 0,
                  characterOffset < utf16OffsetForCharacterOffset.count else { return false }
            return index.contains(utf16OffsetForCharacterOffset[characterOffset])
        }

        var found: [LinkSpan] = []
        // Character offset of the current line's first character. Maintained
        // incrementally: computing it with `distance(from:to:)` per line would
        // make the scan quadratic in document length.
        var lineStartCharacterOffset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // +1 for the "\n" removed by split
            defer { lineStartCharacterOffset += line.count + 1 }
            found.append(contentsOf: spans(inLine: String(line),
                                           offsetBy: lineStartCharacterOffset,
                                           isInsideCode: isInsideCode))
        }
        return (found, utf16OffsetForCharacterOffset, normalised)
    }

    /// - Parameter isInsideCode: takes an ABSOLUTE character offset into the
    ///   scanned string (not a line-relative one).
    private static func spans(inLine line: String, offsetBy base: Int,
                              isInsideCode: (Int) -> Bool) -> [LinkSpan] {
        var result: [LinkSpan] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" {
                let isEmbed = i > 0 && chars[i - 1] == "!"
                if let close = closingBrackets(chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<close])
                    let span = wikilink(inner, isEmbed: isEmbed, innerStart: i + 2,
                                        offsetBy: base)
                    if let span, isInsideCode(span.targetRange.lowerBound) {
                        // Suppressed: step ONE character rather than past the
                        // closing brackets. A `[[` that opened inside inline
                        // code can pair with a `]]` belonging to a REAL link
                        // later on the line (`` `[[x` [[Real]] ``); jumping
                        // past `close` would swallow that real link.
                        i += 1
                        continue
                    }
                    if let span { result.append(span) }
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "[", let found = markdownLink(chars, from: i, offsetBy: base) {
                if !isInsideCode(found.span.targetRange.lowerBound) {
                    result.append(found.span)
                    i = found.end
                    continue
                }
                i += 1
                continue
            }
            i += 1
        }
        return result
    }

    private static func closingBrackets(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            i += 1
        }
        return nil
    }

    private static func wikilink(_ inner: String, isEmbed: Bool, innerStart: Int,
                                 offsetBy base: Int) -> LinkSpan? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let display = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        let link = DocumentLink(rawTarget: target,
                                displayText: (display?.isEmpty ?? true) ? nil : display,
                                isEmbed: isEmbed, syntax: .wikilink)
        return LinkSpan(link: link,
                        targetRange: range(of: target, within: String(parts[0]),
                                           startingAt: base + innerStart))
    }

    /// The range the TRIMMED target occupies, given the untrimmed slice it came
    /// from and where that slice starts. Trimming happens before the span is
    /// built, so `[[  Design  ]]` must still point at `Design` and not at the
    /// spaces around it — a rewrite that included them would silently reflow
    /// the user's spacing.
    private static func range(of target: String, within slice: String,
                              startingAt start: Int) -> Range<Int> {
        let leading = slice.prefix { $0 == " " || $0 == "\t" }.count
        return (start + leading)..<(start + leading + target.count)
    }

    /// `[text](target)` — local targets only. A URL with a scheme is not a
    /// vault link and must never enter the graph.
    private static func markdownLink(_ chars: [Character], from start: Int,
                                     offsetBy base: Int)
        -> (span: LinkSpan, end: Int)? {
        var i = start + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        guard i + 1 < chars.count, chars[i] == "]", chars[i + 1] == "(" else { return nil }
        let text = String(chars[(start + 1)..<i])
        var j = i + 2
        while j < chars.count, chars[j] != ")" { j += 1 }
        guard j < chars.count else { return nil }
        let slice = String(chars[(i + 2)..<j])
        let target = slice.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://"), !target.hasPrefix("mailto:") else {
            return nil
        }
        let link = DocumentLink(rawTarget: target, displayText: text.isEmpty ? nil : text,
                                isEmbed: false, syntax: .markdown)
        return (LinkSpan(link: link,
                         targetRange: range(of: target, within: slice,
                                            startingAt: base + i + 2)),
                j + 1)
    }
}

/// Character offset → UTF-16 offset for one string.
///
/// `LinkSpan.targetRange` is in CHARACTERS (it indexes the string handed to
/// `LinkParser`); `MarkdownDocumentModel` answers in UTF-16 units. Mixing them
/// silently misplaces every span in a document containing an emoji, so the two
/// units meet here and nowhere else.
///
/// The table used to be built unconditionally: `count + 1` `Int`s, allocated and
/// grapheme-walked on EVERY parse, twice over (once here, once in
/// `WikilinkSpanBuilder`). For an all-ASCII string the map is the identity, and
/// prose notes are overwhelmingly all-ASCII in the relevant sense, so the common
/// case now allocates nothing at all.
///
/// The ASCII test is `utf8.count == utf16.count` — true exactly when every
/// scalar is < U+0080 — PLUS the absence of any CR. The CR exclusion is not
/// paranoia: `"\r\n"` is ASCII in both counts but is ONE `Character` carrying
/// TWO UTF-16 units, which is precisely the case the identity map gets wrong.
/// Both checks read contiguous code units, so neither pays for grapheme
/// breaking.
enum CharacterOffsetMap: Sendable {
    /// Character offset equals UTF-16 offset. Payload is the character count.
    case identity(characters: Int)
    case table([Int])

    static func make(for text: String) -> CharacterOffsetMap {
        let utf16Count = text.utf16.count
        if text.utf8.count == utf16Count, !text.utf8.contains(0x0D) {
            return .identity(characters: utf16Count)
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count + 1)
        var running = 0
        for character in text {
            offsets.append(running)
            running += character.utf16.count
        }
        offsets.append(running)
        return .table(offsets)
    }

    /// Addressable offsets: one per character, plus a trailing entry so an END
    /// offset can be looked up. Unchanged from the array it replaced, which is
    /// what the callers' `< count` bounds checks are written against.
    var count: Int {
        switch self {
        case .identity(let characters): return characters + 1
        case .table(let table): return table.count
        }
    }

    subscript(characterOffset: Int) -> Int {
        switch self {
        case .identity: return characterOffset
        case .table(let table): return table[characterOffset]
        }
    }
}
