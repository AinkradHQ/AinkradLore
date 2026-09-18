import Foundation

// Where a document's BODY starts, in the original text's own coordinates.
//
// Its own file only because `Frontmatter.swift` sits within a few lines of the
// project's 500-line ceiling and this is new material, not a change to the
// parser. It is still `Frontmatter`, and it still goes through
// `splitLines`/`closingFenceIndex`, because a second opinion about what
// counts as frontmatter is exactly what must not exist.
extension Frontmatter {
    /// The CHARACTER offset in `text` at which the body begins — past the BOM
    /// and the `---` block. Zero when there is no frontmatter.
    ///
    /// For `LinkRewriter`, which sees whole files from disk rather than the
    /// already-split `Note.body` the link scanner is fed. Built on the SAME
    /// `splitLines`/`closingFenceIndex` the parser uses, so "what counts as
    /// frontmatter" has one definition: a rewriter with its own `---` detector
    /// would drift, and the drift would show up as a `[[link]]` written in a
    /// property being rewritten (or a real one not being).
    public static func bodyOffset(in text: String) -> Int {
        let layout = splitLines(text)
        guard let close = closingFenceIndex(layout) else { return 0 }
        var offset = layout.bom ? 1 : 0
        for line in layout.lines[0...close] { offset += line.count + layout.ending.count }
        return min(offset, text.count)
    }
}
