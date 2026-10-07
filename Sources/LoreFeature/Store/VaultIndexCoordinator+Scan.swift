import Foundation

extension VaultIndexCoordinator {
    /// Pure, off-actor: every engine-openable file under `root`, loaded and
    /// reduced to its index payload. No index access.
    ///
    /// Files no SPECIFIC engine claims are loaded by `AttachmentEngine`: type
    /// `attachment`, empty plaintext, the filename (with extension) as title.
    /// Empty plaintext is the point — an attachment row must never match a
    /// full-text search for content nobody parsed.
    /// The ONE walk of "what counts as a document under `root`", shared by
    /// `scanVault` and `scanFingerprints`. Both need the exact same answer —
    /// a copy that drifts is exactly how the fast path fires when it should
    /// not (see `scanFingerprints`'s doc comment) — so this is the single
    /// place the skip rules are read from — see `VaultWalk`.
    /// Callers get back canonical URLs only; every per-file cost (loading,
    /// parsing, `attributesOfItem`) is theirs to pay or skip.
    nonisolated private static func walkDocumentFiles(at root: URL) -> [URL] {
        // The skip and allow rules live in `VaultWalk` — one place for files
        // and directories alike, so the sidebar and the index never disagree.
        VaultWalk.walk(root).files
    }

    nonisolated static func scanVault(at root: URL) -> [IndexEntry] {
        // CANONICAL ON WRITE, part 1: the enumerator builds every URL it yields
        // by appending to the URL it was given, so canonicalizing the root ONCE
        // here makes every `IndexEntry.url` below canonical — without a
        // `realpath(3)` per file. `activate` already stores a canonical
        // `vaultRoot`, so in production this is a no-op; it is here because
        // `scanVault` is also called directly (tests, `rebuild()`) and the
        // invariant must not depend on which door the caller came through.
        let root = Self.canonical(root)
        let entries = Self.walkDocumentFiles(at: root).compactMap(Self.loadEntry)
        // Resolution is a second pass because a link can point at any document
        // in the vault, including one the enumerator has not reached yet.
        //
        // CANONICAL ON WRITE, part 2: `LinkResolver` returns one of the URLs it
        // was given, and every `entry.url` here is canonical (part 1) — so every
        // `ResolvedLink.targetPath`, and therefore every `links.target_path`
        // row, is canonical too. That is what makes `backlinks`,
        // `inboundLinks` and `inboundLinkCount` truthful.
        return resolve(
            entries,
            against: entries.map {
                (url: $0.url, title: $0.payload.title, aliases: $0.payload.aliases)
            })
    }

    /// Links resolved against `documents` — the whole vault's titles and aliases.
    nonisolated static func resolve(
        _ entries: [IndexEntry],
        against documents: [(url: URL, title: String, aliases: [String])]
    )
        -> [IndexEntry]
    {
        let resolver = LinkResolver(documents: documents)
        return entries.map { entry in
            IndexEntry(
                url: entry.url, type: entry.type, payload: entry.payload,
                updated: entry.updated,
                resolvedLinks: entry.payload.links.map {
                    // RAW for rewriting, DECODED for resolution: a
                    // markdown link written `[t](Design%20Doc.md)` must
                    // be stored exactly as authored (the rewriter has to
                    // find that text in the file) while resolving as
                    // `Design Doc.md`. See `DocumentLink.resolutionTarget`.
                    ResolvedLink(
                        rawTarget: $0.rawTarget,
                        targetPath: resolver.resolve($0.resolutionTarget),
                        isEmbed: $0.isEmbed,
                        syntax: $0.syntax)
                },
                isEditable: entry.isEditable, byteSize: entry.byteSize,
                isTruncated: entry.isTruncated)
        }
    }

    /// One file, loaded and reduced to its index payload, links unresolved.
    /// `nil` when a specific engine claims the file but fails to load it.
    nonisolated static func loadEntry(_ url: URL) -> IndexEntry? {
        // File mtime is DELIBERATELY authoritative for `updated`, and
        // supersedes markdown's frontmatter `updated:` value, which the
        // pre-M0 scan used. Two reasons: it is uniform across document
        // types (plaintext has no frontmatter to read), and the
        // frontmatter field is day-granularity, so a whole day's notes
        // tie and `ORDER BY updated DESC` sorts them arbitrarily. This
        // changes sidebar ordering for vaults where the two disagree.
        // Probe: an mtime that cannot be read is "now"; the load below decides.
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let updated = values?.contentModificationDate ?? Date()

        // Resolution is total (`EngineRegistry.engine(for:)` never returns
        // nil), so there is no unclaimed branch any more: a file no
        // specific engine claims loads as an attachment, which indexes its
        // filename and size and nothing else.
        let engineType = EngineRegistry.engine(for: url)
        // An engine that claims a file but fails to LOAD it is left out, as
        // before: that is a real error, so it is logged and the scan goes on.
        // `AttachmentEngine.load` cannot fail, so a load failure now
        // means a specific engine rejected a file it claimed.
        guard let engine = Log.store.orNil("load \(url.lastPathComponent)", { try engineType.load(url) })
        else { return nil }
        // Captured ONCE: `indexPayload` re-runs a full markdown parse plus
        // link scan on markdown documents, so comparing before/after by
        // calling it twice would double that cost for every document in
        // the vault. See `DocumentEngine.indexTitle`'s comment on the same
        // cost, and the `is_truncated` note on `LoreIndex.schemaVersion`.
        var payload = engine.indexPayload
        let uncappedByteCount = payload.plaintext.utf8.count
        payload.plaintext = Self.capped(payload.plaintext)
        // OR'd with the engine's own report: PDFEngine and RichTextEngine
        // cap their text before `indexPayload` returns it, so the
        // before/after comparison above cannot see their truncation — see
        // `DocumentEngine.isContentTruncated`.
        let isTruncated =
            payload.plaintext.utf8.count < uncappedByteCount
            || engine.isContentTruncated
        // Probe: a size that cannot be read is recorded as 0; nothing reads it as truth.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? Int) ?? 0
        return IndexEntry(
            url: url, type: engineType.identifier,
            payload: payload, updated: updated,
            isEditable: engine.isEditable, byteSize: byteSize,
            isTruncated: isTruncated)
    }

    /// The edits-only rescan: re-index `paths` (canonical, all already in the
    /// index) and return the refreshed rows — or `nil` to demand a full
    /// rebuild. A changed title or alias can change how links in OTHER notes
    /// resolve, so any such change (or a file that no longer loads) bails;
    /// a pure content edit cannot, so only the edited files' own links need
    /// resolving, against the vault as the index already knows it.
    nonisolated static func reindexEdited(
        _ paths: [String], known: [IndexRow],
        in index: LoreIndex
    ) -> [IndexRow]? {
        let byPath = Dictionary(known.map { ($0.path.path, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [IndexEntry] = []
        for path in paths {
            guard let entry = loadEntry(URL(fileURLWithPath: path)),
                let old = byPath[path],
                old.title == entry.payload.title, old.aliases == entry.payload.aliases
            else { return nil }
            entries.append(entry)
        }
        let documents = known.map { (url: $0.path, title: $0.title, aliases: $0.aliases) }
        do {
            for entry in resolve(entries, against: documents) { try index.upsert(entry) }
            return try index.all()
        } catch {
            return nil
        }
    }

    /// The same walk `scanVault` does (via `walkDocumentFiles`, so the skip
    /// rules cannot drift between the two), reduced to `(canonical path) ->
    /// (mtime, size)`. No `load`, no `indexPayload` — that is the entire
    /// point: this is the cheap half, run to decide whether the expensive
    /// half (`scanVault`) is needed at all.
    nonisolated static func scanFingerprints(at root: URL) -> [String: DocumentFingerprint] {
        let root = Self.canonical(root)
        var out: [String: DocumentFingerprint] = [:]
        for url in Self.walkDocumentFiles(at: root) {
            // Probes: an unreadable stat fingerprints as now/0, which can only
            // miss the indexed value and so force the full rescan — the answer.
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let updated = values?.contentModificationDate ?? Date()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteSize = (attributes?[.size] as? Int) ?? 0
            out[url.path] = DocumentFingerprint(
                updatedEpoch: updated.timeIntervalSince1970, byteSize: byteSize)
        }
        return out
    }

    /// Upper bound on the indexed text of a single document.
    ///
    /// `scanVault` holds every loaded payload resident until `replaceAll`
    /// applies them in one transaction, so without a cap total rescan memory
    /// is the size of the vault's indexable content. That was tolerable when
    /// only `.md` was scanned; `PlainTextEngine` claims `log`, `csv` and
    /// `json`, where single files run to hundreds of megabytes. Searching the
    /// first megabyte of a giant log is the right trade — holding the whole
    /// corpus in RAM is not. Truncation affects the INDEX ONLY; nothing here
    /// touches what is written back to disk.
    nonisolated static let maxIndexedPlaintextBytes = 1_048_576

    /// Truncates to at most `maxIndexedPlaintextBytes` UTF-8 bytes, cutting on
    /// a scalar boundary so the result is never a mangled half-character.
    nonisolated static func capped(_ text: String) -> String {
        guard text.utf8.count > maxIndexedPlaintextBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxIndexedPlaintextBytes))
        // Walk back to the last lead byte (anything that is not a 10xxxxxx
        // continuation). If the sequence it starts would run past the cut, the
        // scalar is incomplete — drop it whole.
        var i = bytes.count - 1
        while i >= 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0 {
            let lead = bytes[i]
            let width = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4))
            if i + width > bytes.count { bytes.removeSubrange(i...) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `FileManager`'s enumerator (in `scanVault`) hands back paths resolved
    /// via `realpath(3)` — on macOS `/tmp` and `/var` are themselves symlinks
    /// into `/private`, and `URL.resolvingSymlinksInPath()` deliberately
    /// leaves those three roots alone (Apple's documented exception). Without
    /// matching that resolution here, a caller-constructed URL under either
    /// path (any vault under `/tmp`, and every test vault) would never match
    /// a stored row and silently return no backlinks.
    ///
    /// Internal (not private) since Task 7: `LoreStore`'s rename planner must
    /// source the vault root, the rename source AND the destination through
    /// THIS function. `LinkRewriter` computes vault-relative targets by
    /// comparing path COMPONENTS, so mixing a canonical root
    /// (`/private/tmp/v`) with a raw destination (`/tmp/v/x.md`) fails the
    /// prefix match and drops every edit silently — a clean-looking rename
    /// that breaks every inbound link.
    ///
    /// `realpath(3)` fails on a path that does not exist yet, in which case it
    /// returns `url` untouched — so a caller canonicalizing a rename
    /// DESTINATION must canonicalize its existing parent directory and
    /// re-append the last component (see `LoreStore.canonicalizingDestination`).
    /// `nonisolated` because the invariant is enforced off the main actor too:
    /// `scanVault` runs in a detached task, and `LoreIndex` (a `Sendable` type
    /// used from that task) routes every stored path through here.
    nonisolated static func canonical(_ url: URL) -> URL {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    /// Pure, off-actor-safe: every directory under `root`, vault-relative,
    /// minus everything `VaultWalk` prunes — the same rules `scanVault`
    /// applies to files. `nonisolated` so it can run inside
    /// `performBackgroundRebuild`'s detached task without a main-actor hop —
    /// see that method and `directoryPaths`'s own doc comment for why it must.
    nonisolated static func scanDirectories(under root: URL) -> [String] {
        VaultWalk.walk(Self.canonical(root)).directories
    }
}
