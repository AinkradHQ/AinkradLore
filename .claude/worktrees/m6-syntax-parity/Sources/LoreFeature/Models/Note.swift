import Foundation

public struct FrontmatterPair: Equatable, Sendable {
    public let key: String
    public let rawValue: String
    public init(key: String, rawValue: String) { self.key = key; self.rawValue = rawValue }
}

public struct Note: Identifiable, Equatable, Sendable {
    public let path: URL
    public var id: String
    public var title: String
    public var tags: [String]
    /// Alternate names this document answers to, from frontmatter `aliases`.
    ///
    /// Read only — `aliases` is deliberately UNMODELLED for serialization (see
    /// `Frontmatter.modelledKeys`), so it is never patched back onto disk. It
    /// is exposed here purely for indexing and resolution.
    public var aliases: [String]
    public var created: Date
    public var updated: Date
    public var body: String
    /// The unmodelled `key: value` pairs, flattened to one line each.
    ///
    /// DERIVED, read-only-in-spirit: it feeds `IndexPayload.properties` so
    /// property views can query them. It is NOT used to write the file — see
    /// `rawFrontmatter` — so the two cannot disagree about what lands on disk.
    public var extra: [FrontmatterPair]

    /// The document's original frontmatter block, verbatim, without its `---`
    /// fences. `nil` when the file had no frontmatter at all.
    ///
    /// This is the source of truth for serialization: `Frontmatter.serialize`
    /// patches modelled keys into this text instead of re-emitting a block from
    /// the model, so everything Lore does not model survives a save intact.
    public var rawFrontmatter: String?

    /// The line ending the file was written with, `"\n"` or `"\r\n"`.
    ///
    /// Carried so a CRLF document — Windows-authored vaults, sync clients, git
    /// checkouts with `core.autocrlf` — is re-emitted with the endings it
    /// arrived with. Normalising them would rewrite every line of the file,
    /// which is its own kind of corruption.
    public var lineEnding: String

    /// Whether the file began with a U+FEFF byte order mark.
    ///
    /// Carried for the same reason as `lineEnding`: PowerShell redirects, older
    /// Notepad and several exporters emit one, and a BOM shifts the opening
    /// `---` fence so the frontmatter is not recognised at all. Stripped by
    /// `Frontmatter.parse`, restored by `Frontmatter.serialize`.
    ///
    /// IN THE PRODUCT THIS IS ALWAYS `false`: all three read sites
    /// (`MarkdownEngine.load`, `LoreStore.load`, `LoreNoteOperations`) use
    /// `String(contentsOf:encoding:.utf8)`, which consumes the BOM before
    /// `parse` ever sees it, so a BOM-prefixed file loses its 3-byte mark on
    /// save. This path is currently exercised only by tests, which call `parse`
    /// directly. That is a deliberate, signed-off trade: swapping the most
    /// safety-critical reads in the product to manual decoding is not worth a
    /// cosmetic 3-byte fix. Nothing else about the file is affected — the
    /// fence is still found, and no property or body text is lost.
    public var hasByteOrderMark: Bool

    /// The exact prefix `serialize` must put back before the opening fence.
    public var leadingMark: String { hasByteOrderMark ? "\u{FEFF}" : "" }

    public init(path: URL, id: String, title: String, tags: [String],
                aliases: [String] = [],
                created: Date, updated: Date, body: String, extra: [FrontmatterPair] = [],
                rawFrontmatter: String? = nil, lineEnding: String = "\n",
                hasByteOrderMark: Bool = false) {
        self.path = path; self.id = id; self.title = title; self.tags = tags
        self.aliases = aliases
        self.created = created; self.updated = updated; self.body = body
        self.extra = extra; self.rawFrontmatter = rawFrontmatter
        self.lineEnding = lineEnding; self.hasByteOrderMark = hasByteOrderMark
    }
}
