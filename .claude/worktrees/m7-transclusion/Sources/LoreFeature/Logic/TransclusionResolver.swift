import Foundation

/// What an `![[target]]` embed should show, resolved down to a slice of text.
///
/// Never a blank slice: every failure path carries a visible message rather
/// than an empty `.content("")`, matching `MarkdownExtensions`' "return a
/// neutral value rather than guess" discipline.
public enum TransclusionContent: Equatable, Sendable {
    case content(String)                 // the slice to render
    case truncated(String)               // slice + "content truncated" notice
    case missingFragment(String, String) // (opening content, fragment name)
    case circular
    case tooDeep
    case unreadable(String)              // message
}

/// Turns an embed's raw target (`note`, `note#Heading`, `note#^block-id`)
/// into the content it should show.
///
/// Pure logic: no editor, no cache. `path` is the chain of URLs already
/// being resolved on this call stack, supplied by the caller — this type
/// holds no state of its own, so the same resolver instance is safe to call
/// re-entrantly for nested embeds.
public enum TransclusionResolver {
    public static let depthCap = 3
    public static let byteCap = 256 * 1024

    public static func resolve(rawTarget: String,
                               resolver: LinkResolver,
                               path: [URL],
                               readFile: (URL) throws -> String) -> TransclusionContent {
        // 3. Resolve first — the URL is needed for the cycle check.
        guard let url = resolver.resolve(rawTarget) else {
            return .unreadable("Could not resolve \"\(rawTarget)\".")
        }

        // 1. Cycle check precedes reading, so a cycle never costs a file read.
        if path.contains(url) {
            return .circular
        }

        // 2. Depth check.
        if path.count >= depthCap {
            return .tooDeep
        }

        // 4. Read.
        let fullText: String
        do {
            fullText = try readFile(url)
        } catch {
            return .unreadable(error.localizedDescription)
        }

        // 5. Frontmatter-aware model, so the whole-note case strips frontmatter.
        let model = MarkdownDocumentModel(fullText: fullText)
        let text = model.fullText as NSString
        // `Frontmatter.bodyOffset` returns a CHARACTER offset; convert to
        // UTF-16 the same way `MarkdownDocumentModel.init` does, so this
        // stays correct past an emoji in the frontmatter block.
        let bodyCharOffset = Frontmatter.bodyOffset(in: model.fullText)
        let bodyStart = (String(model.fullText.prefix(bodyCharOffset)) as NSString).length
        let bodyRange = NSRange(location: bodyStart, length: text.length - bodyStart)

        // 6. Fragment handling. `fragment(of:)` returns `LinkFragment?` — the
        // "no fragment" case is unwrapped explicitly with `guard let`, rather
        // than switching on the optional itself with a `case nil:` arm. The
        // two are semantically identical, but SourceKit's Swift 6 checker
        // reports a spurious "value can never be nil" against the `case nil:`
        // spelling; unwrapping first sidesteps that reading entirely, without
        // hiding any real non-optional-ness (the type really is optional —
        // `LinkResolver.fragment(of:)` at LinkResolver.swift:121).
        guard let fragment = LinkResolver.fragment(of: rawTarget) else {
            return capped(slice(text, bodyRange))
        }
        switch fragment {
        case .block(let id):
            guard let anchor = model.blockAnchors.first(where: { $0.id == id }) else {
                let opening = slice(text, NSRange(location: bodyRange.location,
                                                   length: min(bodyRange.length, 200)))
                return .missingFragment(opening, id)
            }
            let range = blockRange(in: text, containing: anchor.offset)
            return capped(slice(text, range))

        case .heading(let heading):
            guard let entry = model.outline.first(where: { $0.text == heading }) else {
                let opening = slice(text, NSRange(location: bodyRange.location,
                                                   length: min(bodyRange.length, 200)))
                return .missingFragment(opening, heading)
            }
            let range = headingRange(in: text, outline: model.outline, entry: entry)
            return capped(slice(text, range))
        }
    }

    /// Slices the block containing `offset`: from the blank line before it
    /// to the blank line after it, using `NSString` ranges throughout so a
    /// CRLF document is measured in UTF-16 units, never `Character`s.
    private static func blockRange(in text: NSString, containing offset: Int) -> NSRange {
        let length = text.length
        let start = boundaryBefore(text, from: offset)
        let end = boundaryAfter(text, from: offset, length: length)
        return NSRange(location: start, length: end - start)
    }

    /// Walks backward from `offset` to the start of the enclosing block: the
    /// character right after the nearest blank line, or the start of text.
    private static func boundaryBefore(_ text: NSString, from offset: Int) -> Int {
        guard offset > 0, let blank = lastBlankLineEnd(text, before: offset) else {
            return 0
        }
        return blank
    }

    /// Finds the end (i.e. the position right after) of the blank line
    /// nearest to, but before, `position` — or `nil` if there is none.
    private static func lastBlankLineEnd(_ text: NSString, before position: Int) -> Int? {
        // Scan backward line by line.
        var cursor = position
        while cursor > 0 {
            let lineRange = text.lineRange(for: NSRange(location: max(0, cursor - 1), length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && lineRange.location < position {
                return lineRange.location + lineRange.length
            }
            if lineRange.location == 0 { break }
            cursor = lineRange.location
        }
        return nil
    }

    /// Walks forward from `offset` to the end of the enclosing block: the
    /// start of the nearest following blank line, or the end of text.
    private static func boundaryAfter(_ text: NSString, from offset: Int, length: Int) -> Int {
        var cursor = offset
        while cursor < length {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && lineRange.location > offset {
                return lineRange.location
            }
            let next = lineRange.location + lineRange.length
            if next <= cursor { break }
            cursor = next
        }
        return length
    }

    /// Slices from `entry`'s offset to the next outline entry whose level is
    /// `<=` its own, or to the end of text.
    private static func headingRange(in text: NSString, outline: [OutlineEntry], entry: OutlineEntry) -> NSRange {
        let start = entry.utf16Offset
        let sorted = outline.sorted { (lhs: OutlineEntry, rhs: OutlineEntry) -> Bool in
            lhs.utf16Offset < rhs.utf16Offset
        }
        var index: Int?
        for (candidateIndex, candidate) in sorted.enumerated() {
            let sameOffset = candidate.utf16Offset == entry.utf16Offset
            let sameText = candidate.text == entry.text
            if sameOffset && sameText {
                index = candidateIndex
                break
            }
        }
        guard let index else {
            return NSRange(location: start, length: text.length - start)
        }
        var end = text.length
        let later = sorted[(index + 1)...]
        for entryAfter in later {
            if entryAfter.level <= entry.level {
                end = entryAfter.utf16Offset
                break
            }
        }
        // Trim a single trailing newline so the slice doesn't carry the
        // start-of-next-block blank line into its own content.
        var length = end - start
        while length > 0, text.character(at: start + length - 1) == 0x0A || text.character(at: start + length - 1) == 0x0D {
            length -= 1
        }
        return NSRange(location: start, length: length)
    }

    /// A trimmed (no leading/trailing newline) `NSString` slice.
    private static func slice(_ text: NSString, _ range: NSRange) -> String {
        var location = range.location
        var length = range.length
        // Trim trailing newlines.
        while length > 0, isNewline(text.character(at: location + length - 1)) {
            length -= 1
        }
        // Trim leading newlines.
        while length > 0, isNewline(text.character(at: location)) {
            location += 1
            length -= 1
        }
        return text.substring(with: NSRange(location: location, length: length))
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }

    /// Applies `byteCap`, cutting at the last newline at or before the cap.
    private static func capped(_ slice: String) -> TransclusionContent {
        let bytes = Array(slice.utf8)
        guard bytes.count > byteCap else { return .content(slice) }
        var cut = byteCap
        // Find the last newline at or before `cut`, measured in UTF-8 bytes.
        while cut > 0, bytes[cut - 1] != UInt8(ascii: "\n") {
            cut -= 1
        }
        if cut == 0 { cut = byteCap }
        let cutData = Data(bytes[0..<cut])
        let truncatedSlice = String(data: cutData, encoding: .utf8) ?? slice
        return .truncated(truncatedSlice)
    }
}
