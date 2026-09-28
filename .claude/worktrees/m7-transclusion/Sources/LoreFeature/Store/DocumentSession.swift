import Foundation
import Observation

/// One open document: its engine, its dirty state, its autosave, and its
/// conflict resolution.
///
/// The external-change guard used to live in `LoreStore.save` and applied only
/// to notes. It lives here now and applies to every document type, and the
/// three resolutions (reload / overwrite / save a copy) are real operations
/// rather than an error the UI had no affordance for.
@MainActor
@Observable
public final class DocumentSession: Identifiable {
    /// Stable identity, minted once at init. `url` is mutable (see below), so
    /// tab identity (SwiftUI `ForEach`, dictionary keys, etc.) must key off
    /// `id`, never off `url`.
    public let id = UUID()

    /// The file this session writes to. MUTABLE: `resolveBySavingCopy()`
    /// repoints it at the copy (see there). Callers that key tab identity off a
    /// session must follow this value rather than caching it.
    public private(set) var url: URL
    public let engine: any DocumentEngine

    public private(set) var isDirty = false
    public private(set) var conflict = false

    /// The last save failure that was NOT a conflict — disk full, permissions,
    /// a read-only volume, an engine refusing to round-trip. Conflicts have
    /// their own flag and their own three resolutions; everything else used to
    /// vanish into the autosave's `try?` with `isDirty` as the only hint.
    /// Cleared by every successful write and every successful resolution.
    public private(set) var lastSaveError: Error?
    /// When this session last wrote to disk, or nil if it never has.
    ///
    /// Only ever set by `write()`, so it means "bytes reached the file",
    /// never "the user stopped typing".
    public private(set) var lastSavedAt: Date?

    /// True when the engine cannot write this document back faithfully — today
    /// only a `PlainTextEngine` whose bytes failed a strict UTF-8 decode. Such
    /// a session never autosaves and `saveNow()` refuses up front, so a single
    /// keystroke does not turn into one failed write per keystroke.
    public private(set) var isReadOnly: Bool

    /// Bumped on every successful `resolveByReloading()`. The engines' editor
    /// views seed their SwiftUI `@State` from the engine in `.onAppear`, so an
    /// in-place reload would otherwise leave the OLD text on screen — the user
    /// clicks "Reload" and sees nothing change. Views use this as part of their
    /// `.id()` so a reload forces a fresh view.
    public private(set) var reloadGeneration = 0

    private let coordinator: VaultIndexCoordinator
    /// mtime as of the last successful load or save. Detection is mtime-based
    /// and therefore best-effort: a write inside the filesystem's timestamp
    /// granularity can still slip through. A much smaller hole than not
    /// checking at all.
    private var baseline: Date
    private var saveTask: Task<Void, Never>?

    /// Cached `engine.indexTitle`. Reading it from a SwiftUI `body` (a tab
    /// label redraws constantly) would be a per-frame call, so it is refreshed
    /// only where the title can have changed: load, save, reload, adoption.
    ///
    /// `indexTitle`, NOT `indexPayload.title`: the payload is computed, and for
    /// markdown building it costs a full AST parse plus a link scan. Every one
    /// of these four sites wanted a `String`. The save path in particular then
    /// built the payload AGAIN inside `coordinator.indexDocument` — so a
    /// debounced autosave of a large note ran the parser four times on the main
    /// actor. See `DocumentEngine.indexTitle`.
    private var cachedTitle: String

    /// The title as of the last LOAD, RELOAD, or explicit title-sync commit —
    /// deliberately NEVER updated by an ordinary `write()` (which backs both
    /// `saveNow()` and the 500ms debounced autosave that follows every
    /// keystroke via `markChanged()`).
    ///
    /// This exists ONLY for `LoreStore.commitTitleChange`'s no-op guard, and
    /// it has to be a DIFFERENT value from `cachedTitle` for that guard to
    /// work at all. `cachedTitle` tracks the live-typed text within ~500ms
    /// (every autosave refreshes it), so the dominant real gesture — type a
    /// new title, pause a beat, click away — lands the debounced autosave
    /// BEFORE the click-away's commit runs. A guard keyed on `cachedTitle`
    /// would then see the field's text already equal to "the title", call it
    /// a no-op, and never rename the file or rewrite a single link — while
    /// the autosave had already written the NEW title into the OLD filename,
    /// creating the exact divergence this feature exists to prevent, and one
    /// no future commit of that same text could ever repair (whole-branch
    /// review, fix round 2, Critical A). `titleAtLoad` holds still while the
    /// user types and pauses, so a genuine retitle is correctly seen as
    /// "changed" whether the user clicks away in 50ms or 5 seconds.
    private var titleAtLoad: String

    private static let autosaveDelay: Duration = .milliseconds(500)
    /// One policy, one owner: the coordinator decides how long its own watcher
    /// ignores the echo of our writes.
    private static var selfWriteSuppressionWindow: TimeInterval {
        VaultIndexCoordinator.selfWriteSuppressionWindow
    }

    public init(url: URL, engine: any DocumentEngine, coordinator: VaultIndexCoordinator) {
        self.url = url
        self.engine = engine
        self.coordinator = coordinator
        self.baseline = Self.mtime(of: url) ?? .distantPast
        self.cachedTitle = engine.indexTitle
        self.titleAtLoad = engine.indexTitle
        self.isReadOnly = !engine.isEditable
    }

    public static func open(url: URL, coordinator: VaultIndexCoordinator) throws -> DocumentSession {
        let engine = try EngineRegistry.load(url)
        return DocumentSession(url: url, engine: engine, coordinator: coordinator)
    }

    /// `LoreStore.commitTitleChange`'s no-op guard: has the title genuinely
    /// changed since the last load/reload/explicit sync — see `titleAtLoad`'s
    /// own doc comment for why this must NOT be `cachedTitle`.
    public var titleSinceLoad: String { titleAtLoad }

    /// Called by `LoreStore.commitTitleChange` once a rename it initiated has
    /// actually happened (`RenameReport.movedTo != nil`), regardless of
    /// whether the frontmatter write that follows succeeds. Advances the
    /// no-op baseline to `title` so a LATER, unrelated commit is measured
    /// against what was just deliberately synced, not the session's original
    /// load.
    public func noteTitleSynced(_ title: String) {
        titleAtLoad = title
    }

    /// The title as of the last load or save — see `cachedTitle`.
    public var title: String { cachedTitle }

    /// Called by the engine's editor after every user mutation. Debounced, so
    /// typing produces one write per pause rather than one per keystroke.
    public func markChanged() {
        // A read-only document can never be written, so it is never marked
        // dirty either: scheduling an autosave would produce a failed write per
        // typing pause, and a dirty flag nothing can ever clear would make the
        // tab's close-confirmation nag forever on a file that cannot be saved.
        guard !isReadOnly else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            // A conflict is surfaced, never swallowed: the editor's text stays
            // intact until the user chooses a resolution.
            try? self.saveNow()
        }
    }

    /// Disarms a debounced autosave that has not fired yet.
    ///
    /// MUST be called by anything that stops owning this session — closing its
    /// tab, tearing the store down, switching vaults — and BEFORE deleting the
    /// file it points at. Without it the task armed by `markChanged` outlives
    /// the tab: the SwiftUI view, a captured `selectedTab` or a frame still in
    /// flight keeps the session alive for the remaining 500ms, and the save
    /// lands afterwards. On the delete path that RECREATES the file the user
    /// just deleted, containing the content they chose to discard; on the
    /// "Close anyway → those edits are lost" path it silently persists them
    /// anyway, making the dialog a lie.
    ///
    /// Deliberately does NOT clear `isDirty`: the in-memory document really is
    /// unsaved, and callers that want it on disk call `saveNow()` first.
    public func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    public func saveNow() throws {
        try guardWritable()
        if let disk = Self.mtime(of: url), disk > baseline {
            // A conflict is not a `lastSaveError`: it has its own flag and its
            // own three resolutions. Conflating them would make the UI show
            // both a banner and an error for one situation.
            conflict = true
            throw LoreError.externalChange(url)
        }
        try write()
    }

    public func resolveByOverwriting() throws {
        try guardWritable()
        try write()
    }

    /// Session-level write policy, enforced before any engine call. Today only
    /// `PlainTextEngine` self-guards; an engine that did not would otherwise
    /// bypass this entirely.
    private func guardWritable() throws {
        guard isReadOnly else { return }
        let error = EngineError.notRoundTrippable(url)
        lastSaveError = error
        throw error
    }

    public func resolveByReloading() throws {
        let fresh = try EngineRegistry.load(url)
        // The engine is `let`, so reloading copies the fresh contents into the
        // engine this session already owns rather than swapping the object.
        try copyState(from: fresh)
        baseline = Self.mtime(of: url) ?? .distantPast
        cachedTitle = engine.indexTitle
        titleAtLoad = engine.indexTitle
        isReadOnly = !engine.isEditable
        conflict = false
        isDirty = false
        lastSaveError = nil
        reloadGeneration += 1
    }

    /// Writes our version beside the original as `name (Lore copy).ext`,
    /// leaving the on-disk file untouched, and ADOPTS the copy: from here on
    /// this session edits and saves the copy.
    ///
    /// "My version lives here now, and the file I was fighting over is left
    /// alone" is the only reading under which continuing to type is safe. The
    /// alternative — keep pointing at the original — leaves the session
    /// permanently in conflict with a file it will never win against, so every
    /// subsequent autosave fails silently through its `try?` and the user's
    /// ongoing work is persisted nowhere while the tab looks clean.
    @discardableResult
    public func resolveBySavingCopy() throws -> URL {
        try guardWritable()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) (Lore copy).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) (Lore copy \(n)).\(ext)")
            n += 1
        }
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        try engine.save(to: candidate)
        url = candidate
        baseline = Self.mtime(of: candidate) ?? .distantPast
        cachedTitle = engine.indexTitle
        conflict = false
        isDirty = false
        lastSaveError = nil
        try? coordinator.indexDocument(engine, at: candidate)
        return candidate
    }

    /// The document this session edits was renamed or moved on disk. Follow it.
    ///
    /// `url` is already mutable (`resolveBySavingCopy` adoption); this is the
    /// same move for a different reason. The baseline MUST be refreshed too:
    /// it describes the old file, and left stale the session's next save either
    /// sees a "newer" file and raises a phantom conflict, or — worse — sees an
    /// older one and writes over the move. `conflict` is cleared for the same
    /// reason: a banner about a file that no longer exists is not actionable.
    ///
    /// `isDirty` is deliberately NOT cleared: unsaved edits are still unsaved,
    /// they just belong to a file with a new name now.
    /// An UNRESOLVED conflict survives the rename. The externally-edited
    /// content moved along with the file, so the disagreement is still live:
    /// clearing the flag and adopting the moved file's mtime as the baseline
    /// would let this session's next autosave overwrite the other writer's
    /// text silently — the rename would have laundered a conflict into a data
    /// loss. `.distantPast` keeps `saveNow` throwing until the user picks one
    /// of the three resolutions, exactly as before the rename.
    public func adoptRenamed(_ newURL: URL) {
        let unresolvedConflict = conflict && isDirty
        url = newURL
        baseline = unresolvedConflict ? .distantPast
                                      : (Self.mtime(of: newURL) ?? .distantPast)
        conflict = unresolvedConflict
        if !unresolvedConflict { lastSaveError = nil }
    }

    private func write() throws {
        coordinator.suppressWatcher(for: Self.selfWriteSuppressionWindow)
        do {
            try engine.save(to: url)
        } catch {
            // Disk full, permissions, a read-only volume: not a conflict, and
            // previously invisible because the autosave discards this throw.
            lastSaveError = error
            throw error
        }
        baseline = Self.mtime(of: url) ?? .distantPast
        cachedTitle = engine.indexTitle
        isDirty = false
        conflict = false
        lastSaveError = nil
        // Recorded so the UI can distinguish "saved a moment ago" from "never
        // had anything to save". `!isDirty` alone cannot: a freshly opened,
        // untouched document is also not dirty, and reporting "Saved" for it
        // claims a write that never happened.
        lastSavedAt = Date()
        // The file is truth; the index is derived. A failed index write must
        // never make a successful save look like a failure.
        try? coordinator.indexDocument(engine, at: url)
    }

    /// Replaces this session's engine contents with `fresh`'s, via the engine's
    /// own `replaceContents(with:)`.
    ///
    /// Passing `engine` (an `any DocumentEngine`) as the argument to a generic
    /// parameter constrained to `DocumentEngine` implicitly opens the
    /// existential (SE-0352), recovering the concrete type `E`. The inner
    /// closure then checks that `fresh` is that SAME concrete type. A mismatch
    /// means the file changed type under us (a `.md` replaced by a `.pdf` at
    /// the same path) and is an `unsupported` error, exactly as before.
    private func copyState(from fresh: any DocumentEngine) throws {
        func adopt<E: DocumentEngine>(_ mine: E) throws {
            guard let theirs = fresh as? E else { throw EngineError.unsupported(url) }
            mine.replaceContents(with: theirs)
        }
        try adopt(engine)
    }

    private static func mtime(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
