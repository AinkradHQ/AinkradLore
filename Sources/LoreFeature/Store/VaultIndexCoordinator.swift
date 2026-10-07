import Foundation
import NaturalLanguage
import Observation

/// Owns the vault's derived state: the SQLite index, the folder watcher, and
/// the rescan lifecycle. Extracted from `LoreStore` unchanged — every comment
/// below records a real bug the code around it fixes.
@MainActor
@Observable
final class VaultIndexCoordinator {
    /// `didSet` drops the cached resolver below — see `currentResolver()`.
    /// Every reassignment site (background rebuild, `activate`, `shutdown`,
    /// `indexDocument`, the rename/trash paths) already goes through THIS
    /// property, so one `didSet` covers every invalidation point without
    /// hunting down each call site by hand.
    var rows: [IndexRow] = [] {
        didSet { cachedResolver = nil }
    }
    private(set) var vaultRoot: URL?
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
    var directoryPaths: [String] = []

    private let indexPath: URL
    private(set) var index: LoreIndex?
    private var watcher: FolderWatcher?
    /// `currentResolver()`'s cache. `LinkResolver.init` builds a dictionary
    /// from every row plus a `sortByPreference` sort per key — cheap once per
    /// vault change, ruinous per call. `EmbedRendering.applyEmbeds` calls
    /// `resolveEmbedTarget` — which reaches `currentResolver()` — once per
    /// `![[…]]` span on every full editor render, i.e. on every keystroke;
    /// without this cache a note with N embeds in an M-row vault rebuilt N
    /// whole-vault resolvers per keypress. Dropped, not refreshed, on
    /// invalidation: the next call rebuilds it lazily, exactly once.
    var cachedResolver: LinkResolver?
    /// While `Date() < suppressWatcherUntil`, `FolderWatcher` callbacks are
    /// ignored — see `save(_:overwritingExternalChanges:)`.
    private var suppressWatcherUntil: Date = .distantPast
    /// A background rescan is in flight.
    ///
    /// Module-readable rather than `private`: this is the ONLY signal the
    /// UI has that a vault is still being read. Kept private, a first-run user
    /// opening a large vault saw an empty sidebar — indistinguishable from an
    /// empty vault — for as long as the scan took.
    var isRebuilding = false
    /// Why the last background rescan failed, or nil if it succeeded.
    ///
    /// `performBackgroundRebuild` used to `return nil` on a throw and tell
    /// nobody: a vault that could not be indexed looked exactly like a vault
    /// with nothing in it. Cleared at the START of each attempt, so it only
    /// ever describes the most recent one.
    var lastRebuildError: String?
    /// A vault change arrived while a rescan was running — run once more after.
    var rebuildRequestedAgain = false

    /// Test seam only: incremented once per full rescan actually performed
    /// (i.e. every time the unchanged-vault fast path did NOT fire). No
    /// production reader — it exists because there was no other clean way to
    /// assert "a rebuild was skipped" without asserting on timing.
    // Semantic search state — see `VaultIndexCoordinator+Semantic.swift`.
    // Ignored by Observation: search reads (and caches into) these while a
    // view body is rendering, and a tracked write there would re-render it.
    @ObservationIgnored var embeddings: [String: [Float]] = [:]
    @ObservationIgnored var isEmbedding = false
    @ObservationIgnored var embeddingModel: NLEmbedding?
    @ObservationIgnored var vocabulary: NLEmbedding?
    @ObservationIgnored var lastQueryNearest: (query: String, limit: Int, nearest: [(String, Float)])?

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

    func notifyExternalChange(to url: URL) {
        for handler in externalChangeHandlers.values { handler(url) }
    }

    /// Tells every registered handler about each path whose `updated` (mtime)
    /// differs between `oldRows` and `newRows` — the diff a whole-vault
    /// rescan needs to turn "the index refreshed" into "THESE paths changed",
    /// since `performBackgroundRebuild`/`rebuild` replace `rows` wholesale
    /// rather than editing it in place.
    func notifyChangedPaths(from oldRows: [IndexRow], to newRows: [IndexRow]) {
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

    init(indexPath: URL) {
        self.indexPath = indexPath
    }

    func activate(root: URL) throws {
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
    func shutdown() {
        watcher = nil
        rebuildRequestedAgain = false
        index = nil
        embeddings = [:]
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

    /// Called when a background rescan fails. Set by `LoreStore` so the
    /// coordinator does not have to know what a notification is.
    var onRescanFailure: ((String) -> Void)?
}
