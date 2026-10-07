import Foundation

/// A link after resolution: what the author wrote, and what it points at.
///
/// Both halves are stored. `targetPath` drives backlinks and navigation;
/// `rawTarget` is what rename rewriting must find and replace, so that a link
/// written `[[design]]` is rewritten `[[new-name]]` rather than being silently
/// normalized to a full path.
struct ResolvedLink: Sendable, Equatable {
    let rawTarget: String
    let targetPath: URL?
    let isEmbed: Bool
    /// Which syntax the link was written in. Stored, not inferred: every
    /// percent-encoding decision downstream (resolution, rename rewriting, and
    /// "create the note this dead link names") is conditional on it, and the
    /// raw target alone cannot tell you — `100%20off` is an encoded space in a
    /// markdown link and a literal `%20` in a wikilink. Inferring it separately
    /// at each consumer is exactly the drift that produced these bugs.
    let syntax: LinkSyntax
    init(
        rawTarget: String, targetPath: URL?, isEmbed: Bool,
        syntax: LinkSyntax = .wikilink
    ) {
        self.rawTarget = rawTarget
        self.targetPath = targetPath
        self.isEmbed = isEmbed
        self.syntax = syntax
    }
}

/// One outbound link that resolved to nothing, with the syntax it was written
/// in. A bare `String` was not enough for the "Create note" affordance: the
/// name to create is the percent-DECODED target for a markdown link and the
/// verbatim one for a wikilink.
struct UnresolvedLink: Sendable, Equatable, Hashable, Identifiable {
    let rawTarget: String
    let syntax: LinkSyntax
    var id: String { "\(syntax == .markdown ? "m" : "w"):\(rawTarget)" }
    init(rawTarget: String, syntax: LinkSyntax) {
        self.rawTarget = rawTarget
        self.syntax = syntax
    }
}

/// One document's contribution to the index: where it lives, which engine
/// claims it, and the payload that engine produced.
struct IndexEntry: Sendable {
    let url: URL
    let type: String
    let payload: IndexPayload
    let updated: Date
    let resolvedLinks: [ResolvedLink]
    let isEditable: Bool
    let byteSize: Int
    /// True when `payload.plaintext` was cut short by
    /// `VaultIndexCoordinator.capped` (or an engine's own equivalent cap).
    /// Without it a partially-indexed document is indistinguishable from one
    /// indexed whole — see `LoreIndex.schemaVersion`'s `7:` note.
    let isTruncated: Bool
    init(
        url: URL, type: String, payload: IndexPayload, updated: Date,
        resolvedLinks: [ResolvedLink] = [],
        isEditable: Bool = true, byteSize: Int = 0, isTruncated: Bool = false
    ) {
        self.url = url
        self.type = type
        self.payload = payload
        self.updated = updated
        self.resolvedLinks = resolvedLinks
        self.isEditable = isEditable
        self.byteSize = byteSize
        self.isTruncated = isTruncated
    }
}

struct IndexRow: Equatable, Sendable {
    let path: URL
    let id: String
    let title: String
    let tags: [String]
    let aliases: [String]
    let updated: Date
    let type: String
    let properties: [FrontmatterPair]
    let isEditable: Bool
    let byteSize: Int
    let isTruncated: Bool

    // Explicit init (rather than the implicit memberwise one) so existing
    // fixtures across the test suite that predate `isEditable`/`byteSize`/
    // `isTruncated` keep compiling — defaults match `IndexEntry`'s.
    init(
        path: URL, id: String, title: String, tags: [String], aliases: [String],
        updated: Date, type: String, properties: [FrontmatterPair],
        isEditable: Bool = true, byteSize: Int = 0, isTruncated: Bool = false
    ) {
        self.path = path
        self.id = id
        self.title = title
        self.tags = tags
        self.aliases = aliases
        self.updated = updated
        self.type = type
        self.properties = properties
        self.isEditable = isEditable
        self.byteSize = byteSize
        self.isTruncated = isTruncated
    }
}

/// A document's cheap identity for the unchanged-vault fast path: mtime plus
/// size, nothing parsed.
///
/// `updatedEpoch` is `timeIntervalSince1970`, a raw `Double` — DELIBERATELY
/// NOT a `Date`. `documents.updated` is stored as that same raw double (see
/// `Self.write`), and reconstructing a `Date` from it on the read side
/// (`Date(timeIntervalSince1970:)`) is a LOSSY round-trip: `Date` compares by
/// `timeIntervalSinceReferenceDate`, which shifts the value by 978307200
/// seconds and back through IEEE-754 — not guaranteed to return the same
/// bits. Two fingerprints that print identically then compared unequal,
/// silently disabling the fast path on every launch. Comparing the stored
/// double directly, unconverted, is exact.
struct DocumentFingerprint: Equatable, Sendable {
    let updatedEpoch: Double
    let byteSize: Int
    init(updatedEpoch: Double, byteSize: Int) {
        self.updatedEpoch = updatedEpoch
        self.byteSize = byteSize
    }
}
