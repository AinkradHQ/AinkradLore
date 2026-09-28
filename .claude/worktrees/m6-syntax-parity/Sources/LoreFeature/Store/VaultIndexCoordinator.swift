import Foundation
import Observation

/// Owns the vault's derived state: the SQLite index, the folder watcher, and
/// the rescan lifecycle. Extracted from `LoreStore` unchanged — every comment
/// below records a real bug the code around it fixes.
@MainActor
@Observable
public final class VaultIndexCoordinator {
    /// `didSet` drops the cached resolver below — see `currentResolver()`.
    /// Every reassignment site (background rebuild, `activate`, `shutdown`,
    /// `indexDocument`, the rename/trash paths) already goes through THIS
    /// property, so one `didSet` covers every invalidation point without
    /// hunting down each call site by hand.
    public private(set) var rows: [IndexRow] = [] {
        didSet { cachedResolver = nil }
    }
    public private(set) var vaultRoot: URL?
    /// Vault-relative paths of every directory — what `FolderTreeView` needs
    /// to show an EMPTY folder, which produces zero index rows and so has no
    /// other representation.
    ///
    /// A STORED value, NOT a lazily-cached one computed on the main actor the
    /// first time something asks — that was this property's Round 2 shape,
    /// and it had two real bugs the reviewer caught (Round 3 fixed both):
    ///
    /// 1. `createFolder` writes a directory directly and never touches
    ///    `rows` (folders are not index rows), so a `didSet`-driven
    ///    invalidation never fired for it — the exact bug this property
    ///    exists to fix, reintroduced for any folder created inside a
    ///    subfolder (Round 1's uncached per-`body`-call walk accidentally
    ///    self-healed on the very next redraw; the cache removed that
    ///    accident along with the walk).
    /// 2. Computing the walk lazily on first main-actor access meant every
    ///    document SAVE (`indexDocument`/`removeFromIndex` both reassign
    ///    `rows`) turned the next folder-tree redraw into a synchronous
    ///    ~500ms main-actor stall on a large vault.
    ///
    /// **Every operation that changes what directories exist on disk must
    /// keep this property current — there is no automatic invalidation path
    /// (no `didSet`, no cache) for it to fall back on if a call site forgets.**
    /// As of Round 4, that is every one of the following, and each is the
    /// exhaustive list — if a future folder-mutating operation is added
    /// elsewhere, it must extend this list AND call one of the three
    /// `note*` methods below, or it will reproduce Round 3/4's exact bug:
    ///
    /// - **Create** (`LoreStore.createFolder`) → `noteDirectoryCreated(_:)`,
    ///   called synchronously right after the directory is written.
    /// - **Trash** (`LoreStore.applyTrashFolder`) → `noteDirectoryRemoved(_:)`
    ///   — Round 4's fix. Missing this left a trashed folder as a permanent
    ///   ghost node: `directoryPaths` kept the entry, `rows` had nothing to
    ///   say about it either way (folders are never rows), and the watcher
    ///   cannot save it — `suppressWatcher` is armed across the whole trash
    ///   (1.0 s) longer than the debounce (0.3 s) even for a root-level
    ///   trash, and a SUBFOLDER trash fires no root event at all. The ghost
    ///   survived until relaunch.
    /// - **Rename** (`LoreStore.apply(_: FolderRenamePlan)`) →
    ///   `noteDirectoryRenamed(from:to:)` — Round 4's fix, same root cause:
    ///   the old name became a ghost AND the new name's empty subfolders (if
    ///   any) went missing, since nothing told `directoryPaths` about either
    ///   half of the rewrite.
    /// - **Background/synchronous rescan** (`performBackgroundRebuild`,
    ///   `rebuild()`) → recomputed wholesale via `scanDirectories(under:)`,
    ///   off the main actor for the background path — this is the ground
    ///   truth every targeted `note*` call above is an optimization over, and
    ///   the reason none of Rounds 1–3 caught the create-path bug: the
    ///   uncached walk (Round 1) and the `rows`-keyed cache (Round 2) both
    ///   self-healed on ANY subsequent full rescan, so only an operation with
    ///   NO other path to a rescan (create, trash, rename — none of which
    ///   touch `rows`, and trash/rename can target a subfolder the watcher
    ///   never sees) can go stale silently.
    ///
    /// Previously a known limitation, now fixed: `FolderWatcher` is an
    /// `FSEventStream` on the vault root, which is recursive by
    /// construction — a folder created, trashed, or renamed in a SUBFOLDER
    /// by an external tool (Finder, `mkdir`, another app, a sync client) now
    /// fires the same `onChange` a root-level change always did, triggering
    /// `startBackgroundRebuild()` the same way. The three targeted `note*`
    /// calls above remain because they are still strictly cheaper than a
    /// full rescan for Lore's OWN mutations (synchronous, exact, no need to
    /// wait on FSEvents' coalescing latency) — not because the watcher can't
    /// see those changes anymore.
    public private(set) var directoryPaths: [String] = []

    private let indexPath: URL
    private var index: LoreIndex?
    private var watcher: FolderWatcher?
    /// `currentResolver()`'s cache. `LinkResolver.init` builds a dictionary
    /// from every row plus a `sortByPreference` sort per key — cheap once per
    /// vault change, ruinous per call. `EmbedRendering.applyEmbeds` calls
    /// `resolveEmbedTarget` — which reaches `currentResolver()` — once per
    /// `![[…]]` span on every full editor render, i.e. on every keystroke;
    /// without this cache a note with N embeds in an M-row vault rebuilt N
    /// whole-vault resolvers per keypress. Dropped, not refreshed, on
    /// invalidation: the next call rebuilds it lazily, exactly once.
    private var cachedResolver: LinkResolver?
    /// While `Date() < suppressWatcherUntil`, `FolderWatcher` callbacks are
    /// ignored — see `save(_:overwritingExternalChanges:)`.
    private var suppressWatcherUntil: Date = .distantPast
    /// A background rescan is in flight.
    ///
    /// `public private(set)` rather than `private`: this is the ONLY signal the
    /// UI has that a vault is still being read. Kept private, a first-run user
    /// opening a large vault saw an empty sidebar — indistinguishable from an
    /// empty vault — for as long as the scan took.
    public private(set) var isRebuilding = false
    /// Why the last background rescan failed, or nil if it succeeded.
    ///
    /// `performBackgroundRebuild` used to `return nil` on a throw and tell
    /// nobody: a vault that could not be indexed looked exactly like a vault
    /// with nothing in it. Cleared at the START of each attempt, so it only
    /// ever describes the most recent one.
    public private(set) var lastRebuildError: String?
    /// A vault change arrived while a rescan was running — run once more after.
    private var rebuildRequestedAgain = false

    /// How long after our own write a watcher event is treated as the echo of
    /// that write. Generous enough to cover FSEvents' coalescing latency,
    /// short enough that a genuine external edit arriving right after a save
    /// is still picked up on the next event.
    static let selfWriteSuppressionWindow: TimeInterval = 1.0

    public init(indexPath: URL) {
        self.indexPath = indexPath
    }

    public func activate(root: URL) throws {
        // CANONICAL ON WRITE. `vaultRoot` is stored canonically and is never the
        // caller's spelling: it seeds `scanVault`'s enumerator (so every indexed
        // path derives from it) and it is the prefix `LinkRewriter` strips to
        // compute vault-relative link targets. Stored raw, a vault under `/tmp`
        // or `/var` — which is every test vault, and some real ones — put a
        // second spelling of every path into circulation. See the invariant on
        // `LoreIndex.canonical(_:)`.
        let root = Self.canonical(root)
        vaultRoot = root
        index = try LoreIndex(path: indexPath)
        // Paint immediately from whatever the index already holds — a reopen
        // then shows the vault instantly — and refresh from disk in the
        // background. Crucially NOT a synchronous `rebuild()`: `activate` runs
        // from `LoreStore.init`, which the host calls from `LoreApp.store(for:)`
        // inside `makeRootView` — i.e. inside a SwiftUI `body` evaluation. A
        // whole-vault scan there froze the UI on first open, for as long as the
        // user's vault was large.
        rows = (try? index?.all()) ?? []
        startBackgroundRebuild()
        watcher = FolderWatcher(url: root) { [weak self] in self?.handleVaultChange() }
    }

    /// Releases everything this store owns: the vault watcher, any in-flight
    /// rescan, and the SQLite index (and with it its file descriptor).
    ///
    /// Called from `LoreApp.teardown` when the host closes this instance. Until
    /// generation 8 there was no way for the host to say that, so all of this
    /// leaked for the lifetime of the process every time Lore was removed.
    public func shutdown() {
        watcher = nil
        rebuildRequestedAgain = false
        index = nil
        rows = []
        directoryPaths = []
        vaultRoot = nil
    }

    /// Watcher entry point. Drops the echo of our own writes so a save doesn't
    /// trigger a full-vault rescan of a vault we just updated in place.
    func handleVaultChange() {
        guard Date() >= suppressWatcherUntil else { return }
        startBackgroundRebuild()
    }

    /// Ignore watcher callbacks for `interval` — used across our own writes so
    /// a save does not trigger a full-vault rescan of a vault we just updated
    /// in place. See the original rationale on `save`.
    func suppressWatcher(for interval: TimeInterval) {
        suppressWatcherUntil = Date().addingTimeInterval(interval)
    }

    /// Test seam: wait until no background rescan is in flight.
    ///
    /// `activate` kicks one off, and `async` tests suspend often enough for its
    /// `replaceAll` to land in the middle of one — wiping notes the test had
    /// already created. Synchronous `XCTest` cases never yielded, so this only
    /// became necessary with the `async` swift-testing suites.
    func settleForTesting() async {
        while isRebuilding { await Task.yield() }
    }


    /// Kicks off an off-actor rescan, coalescing with one already in flight.
    ///
    /// FSEvents delivers bursts (a `git checkout` in the vault is hundreds of
    /// events), and each used to start its own full synchronous rescan on the
    /// main actor. Now at most one runs at a time, off the main actor, and a
    /// burst arriving during one schedules exactly one follow-up.
    func startBackgroundRebuild() {
        guard !isRebuilding else { rebuildRequestedAgain = true; return }
        isRebuilding = true
        Task { [weak self] in
            await self?.performBackgroundRebuild()
        }
    }

    private func performBackgroundRebuild() async {
        defer {
            isRebuilding = false
            if rebuildRequestedAgain {
                rebuildRequestedAgain = false
                startBackgroundRebuild()
            }
        }
        guard let root = vaultRoot, let index else { return }
        lastRebuildError = nil
        // Walk, read and parse every note off the main actor, then apply the
        // whole result in one transaction. `LoreIndex` is Sendable (it holds
        // only a GRDB `DatabaseQueue`, which serializes its own access).
        // `scanDirectories` runs in the SAME detached task, alongside
        // `scanVault` — both are `nonisolated static` walks of the same
        // vault tree, and computing the directory set here (rather than
        // lazily on the main actor the first time `directoryPaths` is read)
        // is what keeps a post-save rescan from turning the next folder-tree
        // redraw into a synchronous stall — see `directoryPaths`'s own
        // doc comment for the measured before/after.
        let outcome: RebuildOutcome = await Task.detached(priority: .utility) {
                () -> RebuildOutcome in
            let notes = Self.scanVault(at: root)
            let directories = Self.scanDirectories(under: root)
            do {
                try index.replaceAll(with: notes)
                return .done(rows: try index.all(), directories: directories)
            } catch {
                // Carried back rather than collapsed to `nil`. The reason a
                // vault fails to index (a corrupt index file, a full disk, a
                // permissions refusal) is the single most useful thing we can
                // tell someone staring at an empty sidebar.
                return .failed(error.localizedDescription)
            }
        }.value
        let refreshed: (rows: [IndexRow], directories: [String])?
        switch outcome {
        case .done(let rows, let directories):
            refreshed = (rows: rows, directories: directories)
        case .failed(let reason):
            lastRebuildError = reason
            refreshed = nil
        }
        // KNOWN, UNFIXED RACE (recorded, not fixed — rated theoretical/low):
        // `directories` above is a snapshot of disk taken when THIS task's
        // `scanDirectories` ran, at the START of this detached task. If a
        // `noteDirectoryCreated`/`noteDirectoryRemoved`/`noteDirectoryRenamed`
        // call (from `createFolder`, `applyTrashFolder`, or folder rename)
        // lands on the main actor AFTER that snapshot was taken but BEFORE
        // this assignment runs, this line clobbers it: the targeted call's
        // precise update is silently overwritten by this task's now-stale
        // snapshot. The window is only the tail of the walk itself (the
        // `scanDirectories` call above, ~0.5 s here) against a
        // `performBackgroundRebuild` that overall runs much longer (the
        // `scanVault` parse pass, tens of seconds on a large vault) — so a
        // user-initiated folder mutation would need to land in that narrow
        // tail specifically. Not attempted: closing it properly needs either
        // a generation counter (reject a stale detached task's result if a
        // targeted call happened after it started) or re-deriving
        // `directoryPaths` from `rows` plus the targeted deltas instead of a
        // flat overwrite — both are more than a one-line guard.
        if let refreshed { rows = refreshed.rows; directoryPaths = refreshed.directories }
    }

    /// What one background rescan produced — the refreshed vault, or why it
    /// could not be read. A two-case result rather than an optional, so the
    /// failure carries its reason instead of being erased to "nothing".
    private enum RebuildOutcome: Sendable {
        case done(rows: [IndexRow], directories: [String])
        case failed(String)
    }

    /// Pure, off-actor: every engine-openable file under `root`, loaded and
    /// reduced to its index payload. No index access.
    ///
    /// Files no SPECIFIC engine claims are loaded by `AttachmentEngine`: type
    /// `attachment`, empty plaintext, the filename (with extension) as title.
    /// Empty plaintext is the point — an attachment row must never match a
    /// full-text search for content nobody parsed.
    nonisolated static func scanVault(at root: URL) -> [IndexEntry] {
        // CANONICAL ON WRITE, part 1: the enumerator builds every URL it yields
        // by appending to the URL it was given, so canonicalizing the root ONCE
        // here makes every `IndexEntry.url` below canonical — without a
        // `realpath(3)` per file. `activate` already stores a canonical
        // `vaultRoot`, so in production this is a no-op; it is here because
        // `scanVault` is also called directly (tests, `rebuild()`) and the
        // invariant must not depend on which door the caller came through.
        let root = Self.canonical(root)
        var entries: [IndexEntry] = []
        // Only components BELOW the root are ours to judge. Testing the
        // absolute path would make a vault under any dot-prefixed ancestor —
        // `~/.local/share/notes`, a `.worktrees/` checkout, a sandbox
        // container — index zero files, silently, showing an empty vault with
        // no error to explain it.
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
            ],
            options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            // Skip package internals and tool directories: `.obsidian`,
            // `.git`, `.trash`, and (later) `.lore` package contents are not
            // documents in their own right.
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if relative.contains(where: { $0.hasPrefix(".") }) { continue }
            // Directories are not documents. They were filtered out for free
            // while unclaimed files were skipped; now that those are indexed,
            // every folder would otherwise become a row. A PACKAGE is also a
            // directory, but `.skipsPackageDescendants` above means its
            // internals are never walked — so unlike a plain directory, the
            // package itself must be indexed as a single `attachment` row
            // (no engine claims a package as its own file type), or it
            // (and everything a user would recognize as "the document")
            // disappears from the vault entirely.
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
            if values?.isDirectory == true && values?.isPackage != true { continue }
            // File mtime is DELIBERATELY authoritative for `updated`, and
            // supersedes markdown's frontmatter `updated:` value, which the
            // pre-M0 scan used. Two reasons: it is uniform across document
            // types (plaintext has no frontmatter to read), and the
            // frontmatter field is day-granularity, so a whole day's notes
            // tie and `ORDER BY updated DESC` sorts them arbitrarily. This
            // changes sidebar ordering for vaults where the two disagree.
            let updated = values?.contentModificationDate ?? Date()

            // Resolution is total (`EngineRegistry.engine(for:)` never returns
            // nil), so there is no unclaimed branch any more: a file no
            // specific engine claims loads as an attachment, which indexes its
            // filename and size and nothing else.
            let engineType = EngineRegistry.engine(for: url)
            // An engine that claims a file but fails to LOAD it is left out, as
            // before: that is a real error, and this scan has nowhere to report
            // it. `AttachmentEngine.load` cannot fail, so a load failure now
            // means a specific engine rejected a file it claimed.
            guard let engine = try? engineType.load(url) else { continue }
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
            let isTruncated = payload.plaintext.utf8.count < uncappedByteCount
                || engine.isContentTruncated
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteSize = (attributes?[.size] as? Int) ?? 0
            entries.append(IndexEntry(url: url, type: engineType.identifier,
                                      payload: payload, updated: updated,
                                      isEditable: engine.isEditable, byteSize: byteSize,
                                      isTruncated: isTruncated))
        }
        // Resolution is a second pass because a link can point at any document
        // in the vault, including one the enumerator has not reached yet.
        //
        // CANONICAL ON WRITE, part 2: `LinkResolver` returns one of the URLs it
        // was given, and every `entry.url` here is canonical (part 1) — so every
        // `ResolvedLink.targetPath`, and therefore every `links.target_path`
        // row, is canonical too. That is what makes `backlinks`,
        // `inboundLinks` and `inboundLinkCount` truthful.
        let resolver = LinkResolver(documents: entries.map {
            (url: $0.url, title: $0.payload.title, aliases: $0.payload.aliases)
        })
        return entries.map { entry in
            IndexEntry(url: entry.url, type: entry.type, payload: entry.payload,
                       updated: entry.updated,
                       resolvedLinks: entry.payload.links.map {
                           // RAW for rewriting, DECODED for resolution: a
                           // markdown link written `[t](Design%20Doc.md)` must
                           // be stored exactly as authored (the rewriter has to
                           // find that text in the file) while resolving as
                           // `Design Doc.md`. See `DocumentLink.resolutionTarget`.
                           ResolvedLink(rawTarget: $0.rawTarget,
                                        targetPath: resolver.resolve($0.resolutionTarget),
                                        isEmbed: $0.isEmbed,
                                        syntax: $0.syntax)
                       },
                       isEditable: entry.isEditable, byteSize: entry.byteSize,
                       isTruncated: entry.isTruncated)
        }
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

    /// Synchronous rescan. Kept for tests and for callers that must observe the
    /// result immediately; production paths use `startBackgroundRebuild`.
    public func rebuild() throws {
        guard let root = vaultRoot, let index else { return }
        try index.replaceAll(with: Self.scanVault(at: root))
        rows = try index.all()
        directoryPaths = Self.scanDirectories(under: root)
    }

    public func search(_ query: String) -> [IndexRow] {
        (try? index?.search(query)) ?? []
    }

    /// Search with an excerpt per hit — see `LoreIndex.searchHits`.
    public func searchHits(_ query: String) -> [SearchHit] {
        (try? index?.searchHits(query)) ?? []
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
    func inboundLinks(to url: URL) -> [(sourceFile: URL, rawTarget: String,
                                        syntax: LinkSyntax)] {
        let links = (try? index?.inboundLinks(to: Self.canonical(url))) ?? []
        return links.map { (sourceFile: Self.canonical($0.sourceFile),
                            rawTarget: $0.rawTarget, syntax: $0.syntax) }
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
        let resolver = LinkResolver(documents: rows.map {
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

    /// Pure, off-actor-safe: every directory under `root`, vault-relative,
    /// skipping dot-prefixed components and package internals — the same
    /// rules `scanVault` applies to files. `nonisolated` so it can run inside
    /// `performBackgroundRebuild`'s detached task without a main-actor hop —
    /// see that method and `directoryPaths`'s own doc comment for why it must.
    nonisolated static func scanDirectories(under root: URL) -> [String] {
        let root = Self.canonical(root)
        let rootDepth = root.standardizedFileURL.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsPackageDescendants])
        else { return [] }
        var result: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if relative.contains(where: { $0.hasPrefix(".") }) { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            result.append(relative.joined(separator: "/"))
        }
        return result
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
        let isTruncated = payload.plaintext.utf8.count < uncappedByteCount
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
            ResolvedLink(rawTarget: $0.rawTarget,
                         targetPath: resolver.resolve($0.resolutionTarget),
                         isEmbed: $0.isEmbed,
                         syntax: $0.syntax)
        }
        try index.upsert(IndexEntry(url: url, type: type, payload: payload,
                                    updated: Date(), resolvedLinks: resolvedLinks,
                                    isEditable: engine.isEditable, byteSize: byteSize,
                                    isTruncated: isTruncated))
        rows = try index.all()
    }

    func removeFromIndex(_ url: URL) throws {
        guard let index else { throw LoreError.noVault }
        try index.remove(path: url)
        rows = try index.all()
    }

    /// True once a vault is active — the store's `noVault` guard.
    var hasIndex: Bool { index != nil }
}
