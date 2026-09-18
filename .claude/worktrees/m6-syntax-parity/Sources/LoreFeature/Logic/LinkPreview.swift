import Foundation

/// The opening of a document, for the hover preview.
///
/// Pure and file-free: the caller reads the bytes, this decides what of them is
/// worth showing. That split is what makes the interesting decisions — where
/// frontmatter ends, what counts as the first real prose, how much is enough —
/// testable without a vault on disk.
enum LinkPreview {

    /// How much text a preview shows.
    ///
    /// Enough to recognise the document, not enough to read it instead of
    /// opening it. A preview long enough to be a substitute for the note is a
    /// preview people stop trusting to be complete.
    static let characterBudget = 280

    /// The preview text for a document's raw contents.
    ///
    /// Skips frontmatter and the title heading, because both are already known
    /// at the point of hovering: the link says the title, so repeating it as
    /// the preview's first line answers nothing. What the reader wants is the
    /// first sentence they have NOT already seen.
    static func excerpt(from contents: String) -> String {
        // Through the SAME `bodyOffset` the editor and the indexer use, so a
        // preview can never disagree with them about where frontmatter ends.
        var body = String(contents.dropFirst(Frontmatter.bodyOffset(in: contents)))
        body = strippingLeadingHeading(body)
        let collapsed = body
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > characterBudget else { return collapsed }
        // Cut at a WORD boundary, not mid-word: a preview ending "the imple…"
        // reads as corruption rather than as truncation.
        let clipped = collapsed.prefix(characterBudget)
        let lastSpace = clipped.lastIndex(of: " ") ?? clipped.endIndex
        return String(clipped[..<lastSpace]) + "…"
    }

    /// Drops a leading ATX heading line, if there is one.
    private static func strippingLeadingHeading(_ text: String) -> String {
        let trimmed = text.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix("#") else { return String(trimmed) }
        guard let newline = trimmed.firstIndex(where: { $0.isNewline }) else { return "" }
        return String(trimmed[trimmed.index(after: newline)...])
    }
}
