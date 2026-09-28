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

    /// Test seam only: incremented once per full rescan actually performed
    /// (i.e. every time the unchanged-vault fast path did NOT fire). No
    /// production reader — it exists because there was no other clean way to
    /// assert "a rebuild was skipped" without asserting on timing.
    var rebuildsPerformedForTesting = 0
    /// Rescans that took the edits-only path (`reindexEdited`) instead.
    var incrementalRebuildsForTesting = 0

    /// Open editors' subscriptions to "a file changed on disk", keyed by the
    /// token `registerExternalChangeHandler` handed back — see that method.
    /// This is the SAME sink `LoreStore`/`EditorContext` route the watcher's
    /// and every save's changes through already; a transcluded embed rides
    /// it rather than a second watcher of its own.
    private var externalChangeHandlers: [UUID: (URL) -> Void] = [:]

    /// Subscribes to every file-changed notification this coordinator raises
    /// — from a watcher-driven rescan (`performBackgroundRebuild`, `rebuild`)
    /// or a single document being (re-)indexed after a save
    /// (`indexDocument`). Returns a token; the caller MUST pass it to
    /// `unregisterExternalChangeHandler` when it tears down, or `handler` —
    /// and everything it captures — outlives whatever registered it.
    func registerExternalChangeHandler(_ handler: @escaping (URL) -> Void) -> UUID {
        let token = UUID()
        externalChangeHandlers[token] = handler
        return token
    }

    /// Pairs with `registerExternalChangeHandler` — see its doc comment.
    func unregisterExternalChangeHandler(_ token: UUID) {
        externalChangeHandlers.removeValue(forKey: token)
    }

    private func notifyExternalChange(to url: URL) {
        for handler in externalChangeHandlers.values { handler(url) }
    }

    /// Tells every registered handler about each path whose `updated` (mtime)
    /// differs between `oldRows` and `newRows` — the diff a whole-vault
    /// rescan needs to turn "the index refreshed" into "THESE paths changed",
    /// since `performBackgroundRebuild`/`rebuild` replace `rows` wholesale
    /// rather than editing it in place.
    private func notifyChangedPaths(from oldRows: [IndexRow], to newRows: [IndexRow]) {
        guard !externalChangeHandlers.isEmpty else { return }
        var oldByPath: [URL: Date] = [:]
        oldByPath.reserveCapacity(oldRows.count)
        for row in oldRows { oldByPath[row.path] = row.updated }
        for row in newRows where oldByPath[row.path] != row.updated {
            notifyExternalChange(to: row.path)
        }
    }

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
        // The paint is the first thing the background rebuild does, off the
        // main actor — reading every row here ran inside a SwiftUI `body`.
        rows = []
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

    /// Test seam only: the underlying index, for tests that need to read
    /// `fingerprints()` directly rather than through the coordinator.
    var indexForTesting: LoreIndex? { index }

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
        // First rebuild after `activate`: paint from what the index already
        // holds, so a reopen shows the vault before the disk is checked.
        if rows.isEmpty {
            let painted = await Task.detached(priority: .userInitiated) {
                (try? index.all()) ?? []
            }.value
            guard self.index === index else { return }   // shut down meanwhile
            if rows.isEmpty { rows = painted }
        }
        // Cheap pass first: if the vault is identical to what is indexed, the
        // whole scan below is wasted work. Measured on a 1547-note vault: the
        // full rescan burns 50-105% CPU for 45-60s, on EVERY launch, and on a
        // relaunch with no edits every byte of it is thrown away.
        //
        // Any difference at all -- added, removed, or modified -- falls through
        // to the unchanged full rebuild. That is deliberate: a changed title or
        // alias can change how links in OTHER notes resolve, so partial
        // re-indexing is not safe without re-resolving the graph.
        //
        // The directory set is compared too, not just file fingerprints: an
        // EMPTY directory created or removed touches no file's mtime/size, so
        // file fingerprints alone would call that vault "unchanged" and skip
        // the rescan that the directory set needs to notice it.
        //
        // Compared against `index.indexedDirectories()` — a PERSISTED set —
        // rather than the in-memory `directoryPaths`. `directoryPaths` starts
        // empty in every new process, so comparing against it made this fast
        // path unfireable at launch, the one case it exists for. See
        // `LoreIndex.indexedDirectories()`'s doc comment.
        //
        // `try? index.indexedDirectories()` flattens (Swift auto-flattens
        // `try?` over an already-Optional return since SE-0230): both a throw
        // and a genuine `nil` ("never recorded") collapse to `nil` here, and
        // the `if let` below fails to bind either way — so "never recorded"
        // correctly does NOT take the fast path.
        if let indexed = try? index.fingerprints(),
           let indexedDirectories = try? index.indexedDirectories() {
            let (onDisk, onDiskDirectories) = await Task.detached(priority: .utility) {
                (Self.scanFingerprints(at: root), Set(Self.scanDirectories(under: root)))
            }.value
            if onDisk == indexed && onDiskDirectories == indexedDirectories {
                // Cheap-pass hit: nothing on disk differs. Publish the
                // directory set to the in-memory property anyway — a fresh
                // process has an empty one, and the sidebar's folder tree
                // reads it.
                directoryPaths = Array(indexedDirectories)
                return
            }
            // Edits only — same files, same folders, some contents changed: the
            // common case (an agent or editor rewriting notes). Re-index just
            // those files instead of re-parsing the whole vault.
            if Set(onDisk.keys) == Set(indexed.keys), onDiskDirectories == indexedDirectories {
                let changed = onDisk.compactMap { indexed[$0.key] == $0.value ? nil : $0.key }
                let known = rows
                let updated = await Task.detached(priority: .utility) {
                    Self.reindexEdited(changed, known: known, in: index)
                }.value
                if let updated {
                    incrementalRebuildsForTesting += 1
                    notifyChangedPaths(from: rows, to: updated)
                    rows = updated
                    directoryPaths = Array(indexedDirectories)
                    return
                }
            }
        }
        rebuildsPerformedForTesting += 1
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
            // The sidebar shows `lastRebuildError` while Lore is open; the feed
            // keeps it afterwards, which is when the user notices search is
            // returning stale results and has no idea why.
            onRescanFailure?(reason)
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
        if let refreshed {
            // Diffed BEFORE `rows` is overwritten — see `notifyChangedPaths`.
            // This is the watcher's own path: a genuine external edit (a
            // self-write's echo is already dropped by `suppressWatcherUntil`
            // before `startBackgroundRebuild` is ever called) reaching every
            // editor that asked to hear about it, with no keystroke required.
            notifyChangedPaths(from: rows, to: refreshed.rows)
            rows = refreshed.rows
            directoryPaths = refreshed.directories
            // Persisted alongside the in-memory publish above: the next
            // PROCESS's first rebuild needs this on disk, not just in this
            // instance's memory. `try?` — losing this write costs one extra
            // full rebuild next launch, not correctness.
            try? index.setIndexedDirectories(Set(refreshed.directories))
        }
    }

    /// What one background rescan produced — the refreshed vault, or why it
    /// could not be read. A two-case result rather than an optional, so the
    /// failure carries its reason instead of being erased to "nothing".
    /// Called when a background rescan fails. Set by `LoreStore` so the
    /// coordinator does not have to know what a notification is.
    var onRescanFailure: ((String) -> Void)?

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
        return resolve(entries, against: entries.map {
            (url: $0.url, title: $0.payload.title, aliases: $0.payload.aliases)
        })
    }

    /// Links resolved against `documents` — the whole vault's titles and aliases.
    nonisolated static func resolve(_ entries: [IndexEntry],
                                    against documents: [(url: URL, title: String, aliases: [String])])
        -> [IndexEntry] {
        let resolver = LinkResolver(documents: documents)
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
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
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
        guard let engine = try? engineType.load(url) else { return nil }
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
        return IndexEntry(url: url, type: engineType.identifier,
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
    nonisolated static func reindexEdited(_ paths: [String], known: [IndexRow],
                                          in index: LoreIndex) -> [IndexRow]? {
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
    /// minus everything `VaultWalk` prunes — the same rules `scanVault`
    /// applies to files. `nonisolated` so it can run inside
    /// `performBackgroundRebuild`'s detached task without a main-actor hop —
    /// see that method and `directoryPaths`'s own doc comment for why it must.
    nonisolated static func scanDirectories(under root: URL) -> [String] {
        VaultWalk.walk(Self.canonical(root)).directories
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
        // One row re-read, not the whole index: `updated` is now, so it sorts
        // first under `all()`'s `ORDER BY updated DESC`.
        rows.removeAll { $0.path == url }
        if let row = try index.row(at: url) { rows.insert(row, at: 0) }
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
