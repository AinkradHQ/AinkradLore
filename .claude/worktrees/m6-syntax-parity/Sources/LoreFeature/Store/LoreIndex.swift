import Foundation
import GRDB

/// A link after resolution: what the author wrote, and what it points at.
///
/// Both halves are stored. `targetPath` drives backlinks and navigation;
/// `rawTarget` is what rename rewriting must find and replace, so that a link
/// written `[[design]]` is rewritten `[[new-name]]` rather than being silently
/// normalized to a full path.
public struct ResolvedLink: Sendable, Equatable {
    public let rawTarget: String
    public let targetPath: URL?
    public let isEmbed: Bool
    /// Which syntax the link was written in. Stored, not inferred: every
    /// percent-encoding decision downstream (resolution, rename rewriting, and
    /// "create the note this dead link names") is conditional on it, and the
    /// raw target alone cannot tell you — `100%20off` is an encoded space in a
    /// markdown link and a literal `%20` in a wikilink. Inferring it separately
    /// at each consumer is exactly the drift that produced these bugs.
    public let syntax: LinkSyntax
    public init(rawTarget: String, targetPath: URL?, isEmbed: Bool,
                syntax: LinkSyntax = .wikilink) {
        self.rawTarget = rawTarget; self.targetPath = targetPath; self.isEmbed = isEmbed
        self.syntax = syntax
    }
}

/// One outbound link that resolved to nothing, with the syntax it was written
/// in. A bare `String` was not enough for the "Create note" affordance: the
/// name to create is the percent-DECODED target for a markdown link and the
/// verbatim one for a wikilink.
public struct UnresolvedLink: Sendable, Equatable, Hashable, Identifiable {
    public let rawTarget: String
    public let syntax: LinkSyntax
    public var id: String { "\(syntax == .markdown ? "m" : "w"):\(rawTarget)" }
    public init(rawTarget: String, syntax: LinkSyntax) {
        self.rawTarget = rawTarget; self.syntax = syntax
    }
}

/// One document's contribution to the index: where it lives, which engine
/// claims it, and the payload that engine produced.
public struct IndexEntry: Sendable {
    public let url: URL
    public let type: String
    public let payload: IndexPayload
    public let updated: Date
    public let resolvedLinks: [ResolvedLink]
    public let isEditable: Bool
    public let byteSize: Int
    /// True when `payload.plaintext` was cut short by
    /// `VaultIndexCoordinator.capped` (or an engine's own equivalent cap).
    /// Without it a partially-indexed document is indistinguishable from one
    /// indexed whole — see `LoreIndex.schemaVersion`'s `7:` note.
    public let isTruncated: Bool
    public init(url: URL, type: String, payload: IndexPayload, updated: Date,
                resolvedLinks: [ResolvedLink] = [],
                isEditable: Bool = true, byteSize: Int = 0, isTruncated: Bool = false) {
        self.url = url; self.type = type; self.payload = payload; self.updated = updated
        self.resolvedLinks = resolvedLinks
        self.isEditable = isEditable; self.byteSize = byteSize
        self.isTruncated = isTruncated
    }
}

public struct IndexRow: Equatable, Sendable {
    public let path: URL
    public let id: String
    public let title: String
    public let tags: [String]
    public let aliases: [String]
    public let updated: Date
    public let type: String
    public let properties: [FrontmatterPair]
    public let isEditable: Bool
    public let byteSize: Int
    public let isTruncated: Bool

    // Explicit init (rather than the implicit memberwise one) so existing
    // fixtures across the test suite that predate `isEditable`/`byteSize`/
    // `isTruncated` keep compiling — defaults match `IndexEntry`'s.
    public init(path: URL, id: String, title: String, tags: [String], aliases: [String],
                updated: Date, type: String, properties: [FrontmatterPair],
                isEditable: Bool = true, byteSize: Int = 0, isTruncated: Bool = false) {
        self.path = path; self.id = id; self.title = title; self.tags = tags
        self.aliases = aliases; self.updated = updated; self.type = type
        self.properties = properties
        self.isEditable = isEditable; self.byteSize = byteSize; self.isTruncated = isTruncated
    }
}

/// `@unchecked Sendable`: the only stored property is a GRDB `DatabaseQueue`,
/// which serializes every access internally and is safe to use from any thread.
/// This is what lets `LoreStore` run a whole-vault rebuild off the main actor.
public final class LoreIndex: @unchecked Sendable {
    /// Internal, not private: the search reads live in `LoreIndex+Search.swift`
    /// and Swift's `private` is file-scoped. Still closed outside the module,
    /// and `LoreIndex` remains the only type that touches it.
    let dbQueue: DatabaseQueue

    /// Bump whenever the schema changes. On mismatch the file is deleted and
    /// rebuilt from disk — safe precisely because the index is derived state,
    /// so there is no migration SQL to get wrong.
    ///
    /// 4: every stored path is CANONICAL (see `Self.canonical`). A version-3
    /// index may hold rows written under a non-canonical spelling; there is no
    /// migration to write, because the whole file is discarded and rebuilt
    /// canonically on the next `activate`.
    ///
    /// 5: `links.syntax`. A version-4 index cannot supply it, and defaulting
    /// every existing row to `wikilink` would silently mis-handle every
    /// percent-encoded markdown link until the next full rescan — so the file
    /// is discarded and rebuilt, which is what a version bump already does.
    ///
    /// 6: M2a replaced the hand-written link scanner with the swift-markdown
    /// AST, and link EXTRACTION changed with it — two accepted ADDs (escaped
    /// backticks and unmatched backtick runs no longer suppress) and four
    /// accepted regressions (link rot inside unclosable indented blocks). A
    /// version-5 index therefore holds an M1 link graph while the code answers
    /// M2a, and `LinkRewriter` reads that index when renaming. Discard and
    /// rebuild — the mechanism this constant exists for.
    ///
    /// 7: M3 added `documents.is_editable` and `documents.byte_size`. A v6
    /// index has neither, and every row in it predates the read-only engines —
    /// so its `type` column holds `unclaimed` for files that are now `pdf`,
    /// `richtext` or `attachment`. Discard and rebuild.
    /// 8: M6 added `blocks`, storing `^block-id` anchors so `[[Note#^id]]`
    /// can resolve. A v7 index has no such rows for any note. Discard and
    /// rebuild — the mechanism this constant exists for.
    static let schemaVersion: Int32 = 8

    public init(path: URL) throws {
        // Probe the existing file's version in its own scope and CLOSE it
        // before deleting: unlinking a database file while a connection is
        // still open on it is an SQLite API violation ("vnode unlinked while
        // in use"), which libsqlite3 logs loudly and which leaves the reopened
        // handle pointing at a file nobody can reach.
        //
        // ANY failure to open, probe or close the existing file counts as
        // stale. The index is entirely derived state, so a corrupt or
        // truncated file must cost exactly one rescan — never the vault. Left
        // as a thrown error it propagates out of `activate`, and the user gets
        // a plugin that permanently refuses to open their notes because a
        // cache file went bad.
        if FileManager.default.fileExists(atPath: path.path) {
            var stale = true
            do {
                let probe = try DatabaseQueue(path: path.path)
                let version = try probe.read { db in
                    try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                }
                try probe.close()
                stale = version != Self.schemaVersion
            } catch {
                stale = true
            }
            if stale { Self.recreate(at: path) }
        }
        dbQueue = try DatabaseQueue(path: path.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS documents(
                    path TEXT PRIMARY KEY, id TEXT, title TEXT, tags TEXT,
                    aliases TEXT, updated DOUBLE, plaintext TEXT, type TEXT,
                    properties TEXT,
                    is_editable INTEGER NOT NULL DEFAULT 1,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    is_truncated INTEGER NOT NULL DEFAULT 0);
            """)
            // Standalone FTS5 index keyed by the same rowid as `documents` (NOT
            // external-content: external-content tables corrupt on the manual
            // INSERT/DELETE we do in upsert/remove).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
                USING fts5(title, plaintext);
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS links(
                    source_path TEXT NOT NULL,
                    raw_target  TEXT NOT NULL,
                    target_path TEXT,
                    is_embed    INTEGER NOT NULL DEFAULT 0,
                    syntax      TEXT NOT NULL DEFAULT 'wikilink');
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_target ON links(target_path);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS links_by_source ON links(source_path);
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS blocks(
                    source_path TEXT NOT NULL,
                    block_id    TEXT NOT NULL,
                    offset      INTEGER NOT NULL);
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS blocks_by_id ON blocks(source_path, block_id);
            """)
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    /// Deletes the index file and its sidecars. Non-throwing on purpose: a
    /// missing file is the desired end state, so nothing here is an error the
    /// caller could act on.
    private static func recreate(at path: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: path.path + suffix)
        }
    }

    // MARK: - The canonical-path invariant

    /// **INVARIANT: every path stored in, or looked up from, this index is
    /// canonical** — `realpath(3)`-resolved, via `VaultIndexCoordinator.canonical`.
    /// That covers `documents.path`, `links.source_path` and
    /// `links.target_path`, and every read argument below.
    ///
    /// This is the LAST line of defence, not the only one: `activate`,
    /// `scanVault` and `indexDocument` all canonicalize upstream so that the
    /// in-memory `rows` (and every `LinkResolver` built from them) carry one
    /// spelling too. Enforcing it here as well is what makes the invariant a
    /// property of the STORE rather than a discipline every future write path
    /// has to remember.
    ///
    /// Why it has to be an invariant: macOS exposes the same file as both
    /// `/tmp/x` and `/private/tmp/x`, and `URL.resolvingSymlinksInPath()`
    /// deliberately leaves `/tmp`, `/var` and `/etc` alone (Apple's documented
    /// exception). Storing one spelling and comparing against the other makes
    /// an exact-match SQL predicate silently return nothing — which in this
    /// milestone has meant an empty backlinks pane, an under-reported
    /// "N notes link here" warning before a delete, and a rename that dropped
    /// every edit. All three looked like "there is nothing to do".
    ///
    /// **If you add a write path to this file, route its paths through here.**
    ///
    /// ## The one place the guarantee does NOT hold
    ///
    /// `realpath(3)` fails on a path that does not exist, and this function then
    /// returns the argument's path untouched — deliberately, because a rename
    /// DESTINATION never exists yet. The consequence is that the symmetric
    /// read/remove guarantee above applies only to a file that still exists: a
    /// `remove(path:)` (or any read) issued with a RAW spelling AFTER the file has
    /// been deleted, trashed or moved cannot be canonicalized, will not match the
    /// canonical row, and will silently no-op — leaving a ghost row. So
    /// canonicalize BEFORE the mutation and pass that value afterwards; see
    /// `LoreStore.trash`, which does exactly this and says why.
    private static func canonical(_ url: URL) -> String {
        VaultIndexCoordinator.canonical(url).path
    }

    // MARK: - Property encoding

    // ASCII unit/record separators rather than JSON: property values are raw
    // YAML source text that may contain quotes, braces, and newlines, and
    // separators that cannot appear in a single-line YAML scalar are simpler
    // and cheaper than escaping. M5 replaces this with typed columns when
    // views need to query properties.

    private static func encode(_ properties: [FrontmatterPair]) -> String {
        properties.map { "\($0.key)\u{1F}\($0.rawValue)" }.joined(separator: "\u{1E}")
    }

    /// Known lossy edge: a property whose key or value literally contains
    /// U+001F or U+001E is dropped rather than mis-split. Unreachable today —
    /// `Frontmatter.parse` yields single-line, whitespace-trimmed scalars, and
    /// neither separator can appear in one — and M5's typed columns remove the
    /// encoding entirely.
    private static func decode(_ raw: String) -> [FrontmatterPair] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\u{1E}").compactMap { field in
            let parts = field.components(separatedBy: "\u{1F}")
            guard parts.count == 2 else { return nil }
            return FrontmatterPair(key: parts[0], rawValue: parts[1])
        }
    }

    // MARK: - Writes

    public func upsert(_ entry: IndexEntry) throws {
        try dbQueue.write { db in
            try Self.write(entry, into: db)
        }
    }

    private static func write(_ entry: IndexEntry, into db: Database) throws {
        // The canonical-path invariant is enforced HERE, at the single function
        // every `documents` and `links` row passes through (`upsert` and
        // `replaceAll` both delegate to it). See `canonical(_:)` above.
        //
        // COST, stated because it is paid inside the write transaction: one
        // `realpath(3)` per document plus one per resolved link. A whole-vault
        // `replaceAll` therefore pays thousands of them — which is exactly what
        // `scanVault` canonicalizes its root ONCE to avoid, and those entries
        // arrive here already canonical, so every call below is a redundant
        // syscall on the hot rebuild path.
        //
        // Kept anyway, on purpose. The failures this invariant prevents are
        // SILENT (an empty backlinks pane, an under-reported "N notes link here"
        // before a delete, a rename that drops every edit), and `upsert` — the
        // per-save path that was the live hole — has no upstream root to
        // canonicalize once. A backstop that only the caller can be trusted to
        // apply is not a backstop. `realpath` on a warm dentry cache is a few
        // microseconds against a transaction already doing several SQL statements
        // per row; if a rebuild ever profiles hot here, cache by parent directory
        // rather than removing the enforcement.
        let path = canonical(entry.url)
        try db.execute(sql: """
            INSERT INTO documents(path,id,title,tags,aliases,updated,plaintext,type,properties,
                                   is_editable,byte_size,is_truncated)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                id=excluded.id, title=excluded.title, tags=excluded.tags,
                aliases=excluded.aliases,
                updated=excluded.updated, plaintext=excluded.plaintext,
                type=excluded.type, properties=excluded.properties,
                is_editable=excluded.is_editable, byte_size=excluded.byte_size,
                is_truncated=excluded.is_truncated;
        """, arguments: [path, entry.payload.id ?? path, entry.payload.title,
                         entry.payload.tags.joined(separator: ","),
                         entry.payload.aliases.joined(separator: ","),
                         entry.updated.timeIntervalSince1970,
                         entry.payload.plaintext, entry.type,
                         encode(entry.payload.properties),
                         entry.isEditable, entry.byteSize, entry.isTruncated])
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                       arguments: [path])
        try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
        try db.execute(sql: "INSERT INTO documents_fts(rowid,title,plaintext) VALUES(?,?,?)",
                       arguments: [rowid, entry.payload.title, entry.payload.plaintext])
        try db.execute(sql: "DELETE FROM links WHERE source_path = ?",
                       arguments: [path])
        for link in entry.resolvedLinks {
            try db.execute(sql: """
                INSERT INTO links(source_path, raw_target, target_path, is_embed, syntax)
                VALUES(?,?,?,?,?);
            """, arguments: [path, link.rawTarget,
                             link.targetPath.map(canonical), link.isEmbed ? 1 : 0,
                             link.syntax.rawValue])
        }
        try db.execute(sql: "DELETE FROM blocks WHERE source_path = ?",
                       arguments: [path])
        for anchor in entry.payload.blocks {
            try db.execute(sql: """
                INSERT INTO blocks(source_path, block_id, offset)
                VALUES(?,?,?);
            """, arguments: [path, anchor.id, anchor.offset])
        }
    }

    /// Replaces the whole index with `entries`, in a SINGLE write transaction.
    ///
    /// `rebuild` used to call `upsert` per note and then `remove` per stale
    /// row — one SQLite transaction each. A vault with a few thousand notes
    /// meant a few thousand transactions, every one of them an fsync, all on
    /// the main actor. Batching them into one transaction is most of why a
    /// rescan is now fast enough to be unnoticeable.
    public func replaceAll(with entries: [IndexEntry]) throws {
        try dbQueue.write { db in
            // Canonical, because that is the spelling `Self.write` stores: a raw
            // keep-set would fail to match the row it just wrote and prune it
            // again in the same transaction.
            let keep = Set(entries.map { Self.canonical($0.url) })
            for entry in entries {
                try Self.write(entry, into: db)
            }
            // Prune rows whose backing file is gone.
            let stale = try String.fetchAll(db, sql: "SELECT path FROM documents")
                .filter { !keep.contains($0) }
            for path in stale {
                let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                               arguments: [path])
                try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM documents WHERE path=?", arguments: [path])
                try db.execute(sql: "DELETE FROM links WHERE source_path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM blocks WHERE source_path = ?", arguments: [path])
            }
        }
    }

    public func remove(path url: URL) throws {
        let path = Self.canonical(url)
        try dbQueue.write { db in
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM documents WHERE path=?",
                                           arguments: [path])
            try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM documents WHERE path=?", arguments: [path])
            try db.execute(sql: "DELETE FROM links WHERE source_path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM blocks WHERE source_path = ?", arguments: [path])
        }
    }

    // MARK: - Reads

    public func all() throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM documents ORDER BY updated DESC").map(Self.row)
        }
    }

    /// Internal for the same reason as `dbQueue` — the search reads map their
    /// result rows through it.
    static func row(_ r: Row) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: r["path"]),
                 id: r["id"], title: r["title"],
                 tags: (r["tags"] as String).split(separator: ",").map(String.init),
                 aliases: (r["aliases"] as String).split(separator: ",").map(String.init),
                 updated: Date(timeIntervalSince1970: r["updated"]),
                 type: r["type"],
                 properties: decode(r["properties"]),
                 isEditable: r["is_editable"] ?? true,
                 byteSize: r["byte_size"] ?? 0,
                 isTruncated: r["is_truncated"] ?? false)
    }

    // MARK: - Links

    /// Documents containing a link that resolves to `target`.
    public func backlinks(to target: URL) throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT d.* FROM documents d
                JOIN links l ON l.source_path = d.path
                WHERE l.target_path = ?
                ORDER BY d.updated DESC;
            """, arguments: [Self.canonical(target)]).map(Self.row)
        }
    }

    /// Every (file, rawTarget) pair pointing at `target`.
    ///
    /// Distinct from `backlinks(to:)`, which returns one row per SOURCE
    /// DOCUMENT: a rename must rewrite every individual link, so a document
    /// linking twice with two different spellings (`[[Design]]` and
    /// `[[Projects/Design.md]]`) has to yield two rows here, not one.
    public func inboundLinks(to target: URL) throws
        -> [(sourceFile: URL, rawTarget: String, syntax: LinkSyntax)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT source_path, raw_target, syntax FROM links
                WHERE target_path = ?;
            """, arguments: [Self.canonical(target)]).map { r in
                let source: String = r["source_path"]
                let raw: String = r["raw_target"]
                return (sourceFile: URL(fileURLWithPath: source), rawTarget: raw,
                        syntax: Self.syntax(r["syntax"]))
            }
        }
    }

    /// A stored `links.syntax` value. Anything unrecognised reads as
    /// `.wikilink`, the syntax that applies NO percent-decoding — the choice
    /// that treats a target verbatim rather than transforming it on a guess.
    private static func syntax(_ raw: String?) -> LinkSyntax {
        raw.flatMap(LinkSyntax.init(rawValue:)) ?? .wikilink
    }

    /// This document's outbound links that resolve to nothing. A normal state:
    /// it is how a link to a not-yet-written note behaves.
    public func unresolvedLinks(from source: URL) throws -> [UnresolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT raw_target, syntax FROM links
                WHERE source_path = ? AND target_path IS NULL;
            """, arguments: [Self.canonical(source)]).map { r in
                UnresolvedLink(rawTarget: r["raw_target"], syntax: Self.syntax(r["syntax"]))
            }
        }
    }

    public func outgoingLinks(from source: URL) throws -> [ResolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT raw_target, target_path, is_embed, syntax FROM links
                WHERE source_path = ?;
            """, arguments: [Self.canonical(source)]).map { r in
                ResolvedLink(rawTarget: r["raw_target"],
                             targetPath: (r["target_path"] as String?).map {
                                 URL(fileURLWithPath: $0)
                             },
                             isEmbed: (r["is_embed"] as Int) == 1,
                             syntax: Self.syntax(r["syntax"]))
            }
        }
    }

    // MARK: - Blocks

    /// Where a block anchor sits, or `nil` if that document has no such
    /// anchor. Used to resolve `[[Note#^id]]`.
    public func blockOffset(inDocumentAt path: String, id: String) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT offset FROM blocks WHERE source_path = ? AND block_id = ? LIMIT 1;
            """, arguments: [path, id])
        }
    }
}
