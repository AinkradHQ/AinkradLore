import Foundation

extension VaultIndexCoordinator {
    /// Synchronous rescan. Kept for tests and for callers that must observe the
    /// result immediately; production paths use `startBackgroundRebuild`.
    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        let oldRows = rows
        try index.replaceAll(with: Self.scanVault(at: root))
        rows = try index.all()
        directoryPaths = Self.scanDirectories(under: root)
        // Same persistence as the background rebuild's completion — see
        // `performBackgroundRebuild`'s matching comment. Without this, a
        // vault indexed only via the synchronous `rebuild()` (as every test
        // harness does) never gets its directory set on disk, and a fresh
        // process's fast path can never fire for it.
        try? index.setIndexedDirectories(Set(directoryPaths))
        notifyChangedPaths(from: oldRows, to: rows)
    }

    public func search(_ query: String) -> [IndexRow] {
        let keyword = (try? index?.search(query)) ?? []
        return keyword + semanticRows(for: query, excluding: Set(keyword.map(\.path.path)))
    }

    /// Search with an excerpt per hit — see `LoreIndex.searchHits`.
    public func searchHits(_ query: String) -> [SearchHit] {
        let keyword = (try? index?.searchHits(query)) ?? []
        return keyword
            + semanticRows(for: query, excluding: Set(keyword.map(\.row.path.path)))
            .map { SearchHit(row: $0, snippet: nil) }
    }

    func linkNeighbours(of url: URL) -> [String: Int] {
        (try? index?.linkNeighbours(of: url)) ?? [:]
    }

    func backlinkRows(to url: URL) -> [IndexRow] {
        (try? index?.backlinks(to: Self.canonical(url))) ?? []
    }

    /// Every (file, rawTarget) pair pointing at `url` — the raw material for a
    /// rename's change set. Canonicalized like every other index lookup.
    ///
    /// The RESULT is canonicalized too, not just the lookup argument.
    /// `links.source_path` is stored with whatever spelling the row carried when
    /// it was written, and `indexDocument` writes the caller's URL verbatim — so
    /// a document indexed outside a full rescan can be stored `/var/...` while
    /// everything downstream of a rename compares against `/private/var/...`.
    /// Every consumer of this function keys dictionaries and sets by these
    /// paths and matches them against canonical session URLs; handing back two
    /// spellings makes those lookups miss, which in this codebase has meant an
    /// edit silently dropped or a dirty tab's file written anyway. One spelling
    /// out of here is what stops that at the source.
    func inboundLinks(to url: URL) -> [(
        sourceFile: URL, rawTarget: String,
        syntax: LinkSyntax
    )] {
        let links = (try? index?.inboundLinks(to: Self.canonical(url))) ?? []
        return links.map {
            (
                sourceFile: Self.canonical($0.sourceFile),
                rawTarget: $0.rawTarget, syntax: $0.syntax
            )
        }
    }
    func unresolvedLinks(from url: URL) -> [UnresolvedLink] {
        (try? index?.unresolvedLinks(from: Self.canonical(url))) ?? []
    }
    /// A resolver over the CURRENT index rows, for link clicks, completion
    /// and embed rendering. Cached against `rows`'s identity — see
    /// `cachedResolver`'s doc comment for why this matters — and rebuilt
    /// lazily the first time it is asked for after `rows` changes.
    func currentResolver() -> LinkResolver {
        if let cachedResolver { return cachedResolver }
        let resolver = LinkResolver(
            documents: rows.map {
                (url: $0.path, title: $0.title, aliases: $0.aliases)
            })
        cachedResolver = resolver
        return resolver
    }

    /// `createFolder`'s own notification that it just created `path`
    /// (vault-relative) directly on disk, bypassing both `rows` (folders are
    /// never index rows) and the watcher. `FolderWatcher` WOULD see this
    /// (its `FSEventStream` is recursive, so a create inside a subfolder
    /// fires `onChange` too — see `directoryPaths`'s own doc comment), but
    /// only after FSEvents' coalescing latency and a full
    /// `startBackgroundRebuild()`; this is a synchronous, exact, cheap
    /// substitute for a change whose entire content this method's caller
    /// already knows precisely, without waiting on the watcher at all.
    /// Idempotent (checks `contains` first) so a redundant call costs
    /// nothing beyond that check.
    func noteDirectoryCreated(_ path: String) {
        guard !directoryPaths.contains(path) else { return }
        directoryPaths.append(path)
    }

    /// The trash counterpart to `noteDirectoryCreated`, same reasoning: tells
    /// `directoryPaths` directly that `path` (vault-relative) is gone from
    /// disk, rather than relying on `rows`/the watcher to notice. Removes
    /// `path` itself AND every entry beneath it (`path + "/…"`) — trashing a
    /// folder takes every subfolder inside it with it, and each of those was
    /// its own `directoryPaths` entry (an empty one, most likely — exactly the
    /// case `noteDirectoryCreated` exists to surface — so leaving it behind
    /// after the folder is gone is the same "ghost node" bug in reverse).
    /// Called from `LoreStore.applyTrashFolder` — see its own call site.
    func noteDirectoryRemoved(_ path: String) {
        let prefix = path + "/"
        directoryPaths.removeAll { $0 == path || $0.hasPrefix(prefix) }
    }

    /// The rename counterpart: `from` (and everything beneath it) becomes
    /// `to`, in place, preserving every subfolder entry a naive
    /// remove-then-rediscover would lose — folder rename already knows the
    /// exact rewrite from the move it just performed, so there is no need to
    /// re-walk disk to find empty subfolders again. Called from
    /// `LoreStore.apply(_: FolderRenamePlan)` — see its own call site.
    func noteDirectoryRenamed(from: String, to: String) {
        let prefix = from + "/"
        directoryPaths = directoryPaths.map { entry in
            if entry == from { return to }
            if entry.hasPrefix(prefix) { return to + "/" + entry.dropFirst(prefix.count) }
            return entry
        }
        // `from` itself might not have been a `directoryPaths` entry (e.g. it
        // held only indexed documents, no empty subfolders of its own) — the
        // map above would then leave `to` absent entirely. Appended
        // unconditionally-but-deduped so the renamed folder is always
        // representable, the same guarantee `noteDirectoryCreated` gives a
        // brand new folder.
        if !directoryPaths.contains(to) { directoryPaths.append(to) }
    }

    /// Index one document after a save, without a whole-vault rescan.
    ///
    /// Resolves this document's own outbound links immediately, against the
    /// current `rows` plus the document being indexed — so a note saved with
    /// a new link shows that link's backlink without waiting for a full
    /// rescan. Built from `rows` rather than a fresh scan, so it does not pay
    /// for a whole-vault walk on every save.
    func indexDocument(_ engine: any DocumentEngine, at url: URL) throws {
        guard let index else { throw LoreError.noVault }
        // CANONICAL ON WRITE, part 3: this was THE hole. `indexDocument` upserted
        // the caller's URL verbatim, so a save routed through a `/tmp`-spelled
        // URL wrote a non-canonical `documents.path` AND non-canonical
        // `links.target_path` rows pointing at it — after which every read
        // (which canonicalizes) matched nothing for that document, silently.
        // Canonicalizing here means the `LinkResolver` below, the upserted row
        // and the resolved link targets are all one spelling.
        let url = Self.canonical(url)
        let type = type(of: engine).identifier
        // Capped here too: `scanVault` already caps every payload it writes,
        // but `indexDocument` — the per-save path — did not, so saving a large
        // document wrote its uncapped text straight into the index.
        var payload = engine.indexPayload
        let uncappedByteCount = payload.plaintext.utf8.count
        payload.plaintext = Self.capped(payload.plaintext)
        let isTruncated =
            payload.plaintext.utf8.count < uncappedByteCount
            || engine.isContentTruncated
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? Int) ?? 0
        // Exclude the STALE row for this same document (if it already exists in
        // `rows`): otherwise its old title/alias keys would stay resolvable
        // until the next full rescan, alongside the fresh keys appended below.
        //
        // Both sides are canonical: `rows` come from `LoreIndex`, which stores
        // only canonical paths, and `url` was canonicalized above. Compared raw
        // (as it was) the filter failed to exclude a row spelled differently
        // from the incoming URL, and the old title/alias stayed resolvable.
        var documents = rows.filter { $0.path != url }
            .map { (url: $0.path, title: $0.title, aliases: $0.aliases) }
        documents.append((url: url, title: payload.title, aliases: payload.aliases))
        let resolver = LinkResolver(documents: documents)
        let resolvedLinks = payload.links.map {
            // Raw for rewriting, decoded for resolution — as in `resolve(_:)`.
            ResolvedLink(
                rawTarget: $0.rawTarget,
                targetPath: resolver.resolve($0.resolutionTarget),
                isEmbed: $0.isEmbed,
                syntax: $0.syntax)
        }
        try index.upsert(
            IndexEntry(
                url: url, type: type, payload: payload,
                updated: Date(), resolvedLinks: resolvedLinks,
                isEditable: engine.isEditable, byteSize: byteSize,
                isTruncated: isTruncated))
        // One row re-read, not the whole index: `updated` is now, so it sorts
        // first under `all()`'s `ORDER BY updated DESC`.
        rows.removeAll { $0.path == url }
        if let row = try index.row(at: url) { rows.insert(row, at: 0) }
        startEmbedding()  // re-embeds just this note; the rest are current
        // The per-save path — the one that fires when the SAME file is open
        // (and saved) in another split pane, not only when an external tool
        // writes it behind the store's back. `url` is already known exactly,
        // no diff needed.
        notifyExternalChange(to: url)
    }

    func removeFromIndex(_ url: URL) throws {
        guard let index else { throw LoreError.noVault }
        let canonical = Self.canonical(url)
        try index.remove(path: url)
        rows.removeAll { $0.path == canonical }
    }

    /// True once a vault is active — the store's `noVault` guard.
    var hasIndex: Bool { index != nil }
}
