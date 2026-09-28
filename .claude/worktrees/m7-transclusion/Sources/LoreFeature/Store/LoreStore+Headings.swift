import Foundation

/// Headings of a linked document, for `[[Doc#…]]` completion.
///
/// ## Why this reads the file
///
/// The index stores a document's title, tags, aliases, plaintext and links —
/// but NOT its outline. So answering "what headings does Design have" means
/// loading and parsing that document, which is real work on a path the user
/// reaches by typing.
///
/// Two things keep that honest:
///
///  - it only runs once a `#` has been typed inside a `[[…]]`, which is a
///    deliberate, rare keystroke rather than something every character
///    triggers;
///  - the result is cached per document, so filtering the list afterwards —
///    which IS per-keystroke — re-parses nothing.
///
/// Persisting outlines in the index would remove the parse entirely and is the
/// better long-term answer; it needs a schema bump and a rebuild, which is a
/// larger change than this feature justifies on its own.
/// A document's headings, and the target that provably reaches THAT document.
public struct HeadingCompletions: Equatable, Sendable {
    /// What to write before the `#` — resolver-verified, so the finished link
    /// cannot land on a namesake in another folder.
    public let insertTarget: String
    public let headings: [String]
}

extension LoreStore {

    /// Headings in the document `name` refers to, filtered by `prefix`.
    ///
    /// Empty when the name resolves to nothing, or to a document with no
    /// headings — both of which are ordinary while the name is still being
    /// typed, and neither of which is an error.
    public func headingCompletions(inDocumentNamed name: String,
                                   matching prefix: String) -> HeadingCompletions? {
        guard let url = resolveLink(name) else { return nil }
        // The VERIFIED target, not the typed name.
        //
        // Two notes can share a title in different folders. `resolveLink`
        // picks one by preference and this offers ITS headings — so inserting
        // the typed name would write a link that may later resolve to the
        // OTHER one, which does not have the heading. `linkTarget(for:)` is
        // the same guarantee the document-completion path already uses: a
        // target that resolves back to this row and not to a namesake.
        let target = rows.first { Self.pathKey($0.path) == Self.pathKey(url) }
            .map { linkTarget(for: $0) } ?? name
        let headings = cachedOutline(for: url)
        let trimmed = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            return HeadingCompletions(insertTarget: target, headings: headings)
        }
        // Substring, not prefix: headings are sentences, and the words worth
        // typing are often not the first ones ("Rollback" in "Deployment and
        // rollback").
        return HeadingCompletions(insertTarget: target,
                                  headings: headings.filter {
                                      $0.lowercased().contains(trimmed)
                                  })
    }

    /// The outline of `url`, parsed at most once per document.
    ///
    /// One entry, not a dictionary: completion is a conversation about ONE
    /// document at a time, and a growing cache of every outline ever consulted
    /// would hold parsed copies of documents the user has moved on from.
    private func cachedOutline(for url: URL) -> [String] {
        let key = Self.pathKey(url)
        if headingCacheKey == key { return headingCache }
        let headings = ((try? EngineRegistry.load(url)) as? MarkdownEngine)?
            .outline.map(\.text) ?? []
        headingCacheKey = key
        headingCache = headings
        return headings
    }

    /// Drops the cached outline.
    ///
    /// Called when the vault changes underneath it. The cache is otherwise
    /// only ever wrong for as long as one completion session lasts — a
    /// heading added to another document while this one is being typed into
    /// is not worth a file watcher.
    func invalidateHeadingCache() {
        headingCacheKey = nil
        headingCache = []
    }
}
