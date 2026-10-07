import Foundation
import GRDB

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
    /// 9: Enhancements E1 — the walk indexes only documents (plus name-only
    /// media rows for embeds) and prunes `node_modules`/`build`/… and
    /// `.gitignore`d paths. A v8 index holds every file under the vault root —
    /// 5.9 GB on one machine. Discard and rebuild.
    static let schemaVersion: Int32 = 9

    /// Every Lore pane opens its own queue on the SAME file, and the embedding
    /// pass writes in the background — so a read can meet another queue's
    /// write lock. Without a busy timeout that read fails at once: the version
    /// probe then counts the index as stale and DELETES it, and the fingerprint
    /// fast path falls through to a full rescan. Wait for the write instead.
    static var configuration: Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        return config
    }

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
                let probe = try DatabaseQueue(path: path.path, configuration: Self.configuration)
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
        dbQueue = try DatabaseQueue(path: path.path, configuration: Self.configuration)
        try dbQueue.write { db in
            try db.execute(
                sql: """
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
            try db.execute(
                sql: """
                        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
                        USING fts5(title, plaintext);
                    """)
            try db.execute(
                sql: """
                        CREATE TABLE IF NOT EXISTS links(
                            source_path TEXT NOT NULL,
                            raw_target  TEXT NOT NULL,
                            target_path TEXT,
                            is_embed    INTEGER NOT NULL DEFAULT 0,
                            syntax      TEXT NOT NULL DEFAULT 'wikilink');
                    """)
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS links_by_target ON links(target_path);
                    """)
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS links_by_source ON links(source_path);
                    """)
            try db.execute(
                sql: """
                        CREATE TABLE IF NOT EXISTS blocks(
                            source_path TEXT NOT NULL,
                            block_id    TEXT NOT NULL,
                            offset      INTEGER NOT NULL);
                    """)
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS blocks_by_id ON blocks(source_path, block_id);
                    """)
            // Single-row table: the directory set as of the last completed
            // rebuild. `CREATE TABLE IF NOT EXISTS`, and NOT tied to
            // `schemaVersion` — an existing database simply lacks the row,
            // which `indexedDirectories()` reads back as `nil` ("never
            // recorded"), forces exactly one full rebuild, and gets
            // populated by it. No migration, no forced reindex for existing
            // users. See `indexedDirectories()`'s doc comment for why this
            // must be persisted at all rather than read from `directoryPaths`.
            try db.execute(
                sql: """
                        CREATE TABLE IF NOT EXISTS vault_directories(
                            id INTEGER PRIMARY KEY CHECK (id = 0),
                            directories TEXT NOT NULL);
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
    static func canonical(_ url: URL) -> String {
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
        try db.execute(
            sql: """
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
                """,
            arguments: [
                path, entry.payload.id ?? path, entry.payload.title,
                entry.payload.tags.joined(separator: ","),
                entry.payload.aliases.joined(separator: ","),
                entry.updated.timeIntervalSince1970,
                entry.payload.plaintext, entry.type,
                encode(entry.payload.properties),
                entry.isEditable, entry.byteSize, entry.isTruncated,
            ])
        let rowid = try Int64.fetchOne(
            db, sql: "SELECT rowid FROM documents WHERE path=?",
            arguments: [path])
        try db.execute(sql: "DELETE FROM documents_fts WHERE rowid=?", arguments: [rowid])
        try db.execute(
            sql: "INSERT INTO documents_fts(rowid,title,plaintext) VALUES(?,?,?)",
            arguments: [rowid, entry.payload.title, entry.payload.plaintext])
        try db.execute(
            sql: "DELETE FROM links WHERE source_path = ?",
            arguments: [path])
        for link in entry.resolvedLinks {
            try db.execute(
                sql: """
                        INSERT INTO links(source_path, raw_target, target_path, is_embed, syntax)
                        VALUES(?,?,?,?,?);
                    """,
                arguments: [
                    path, link.rawTarget,
                    link.targetPath.map(canonical), link.isEmbed ? 1 : 0,
                    link.syntax.rawValue,
                ])
        }
        try db.execute(
            sql: "DELETE FROM blocks WHERE source_path = ?",
            arguments: [path])
        for anchor in entry.payload.blocks {
            try db.execute(
                sql: """
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
                let rowid = try Int64.fetchOne(
                    db, sql: "SELECT rowid FROM documents WHERE path=?",
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
            let rowid = try Int64.fetchOne(
                db, sql: "SELECT rowid FROM documents WHERE path=?",
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

    /// One document's row, or `nil` when it is not indexed.
    public func row(at url: URL) throws -> IndexRow? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM documents WHERE path = ?",
                arguments: [Self.canonical(url)]
            ).map(Self.row)
        }
    }

    /// `(canonical path) -> (updatedEpoch, byteSize)` for every indexed
    /// document. Deliberately NOT `all()`: this reads two columns, not the
    /// full row set with tags/aliases/properties, because it runs on every
    /// activate and is only ever compared, never displayed. `updated` is read
    /// straight out as the raw double `Self.write` stored — NOT reconstructed
    /// into a `Date` — see `DocumentFingerprint.updatedEpoch`'s doc comment
    /// for why that round-trip is lossy and would silently disable the fast
    /// path.
    public func fingerprints() throws -> [String: DocumentFingerprint] {
        try dbQueue.read { db in
            var out: [String: DocumentFingerprint] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT path, updated, byte_size FROM documents")
            for row in rows {
                let path: String = row["path"]
                out[path] = DocumentFingerprint(
                    updatedEpoch: row["updated"],
                    byteSize: row["byte_size"] ?? 0)
            }
            return out
        }
    }

    /// The directory set as of the last completed rebuild.
    ///
    /// Persisted because the fast path must answer "did the vault's directories
    /// change since we last indexed?" across PROCESS BOUNDARIES. The in-memory
    /// `VaultIndexCoordinator.directoryPaths` starts empty in every new process,
    /// so comparing against it made the fast path unfireable at launch — the
    /// exact case it exists for. `nil` means "never recorded" — a fresh
    /// database, one created before this table existed, OR a row this
    /// process cannot decode — which callers must treat as a mismatch, not
    /// as "matches the empty set".
    ///
    /// JSON-encoded, NOT comma-joined like `tags`/`aliases`. Comma-joining is
    /// lossy for directory PATHS specifically: unlike tags, folder names
    /// routinely contain literal commas (e.g. a session folder named
    /// `2026-07-18 sweep — closed #245, shipped #285`), and a comma-joined
    /// round-trip silently splits one such directory into two entries. That
    /// made the stored set permanently unable to equal the scanned set, so
    /// the fast path was permanently dead for any vault with a comma in a
    /// folder name — a real, shipped bug (see the incident this fixes). Do
    /// not "simplify" this back to comma-joining.
    ///
    /// A row this process cannot JSON-decode (e.g. one written by the earlier
    /// comma-joined format) is treated as "never recorded" rather than thrown:
    /// one full rebuild self-heals it into the new format.
    public func indexedDirectories() throws -> Set<String>? {
        try dbQueue.read { db in
            guard
                let raw = try String.fetchOne(
                    db, sql: "SELECT directories FROM vault_directories WHERE id = 0"
                )
            else { return nil }
            guard let data = raw.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            return Set(decoded)
        }
    }

    /// Persists `directories` as the set to compare against on the next
    /// process's first rebuild. See `indexedDirectories()`'s doc comment for
    /// why this is JSON, not comma-joined.
    public func setIndexedDirectories(_ directories: Set<String>) throws {
        let encoded = try JSONEncoder().encode(Array(directories))
        let json = String(decoding: encoded, as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                        INSERT INTO vault_directories(id, directories) VALUES(0, ?)
                        ON CONFLICT(id) DO UPDATE SET directories = excluded.directories;
                    """, arguments: [json])
        }
    }

    /// Internal for the same reason as `dbQueue` — the search reads map their
    /// result rows through it.
    static func row(_ r: Row) -> IndexRow {
        IndexRow(
            path: URL(fileURLWithPath: r["path"]),
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
}
