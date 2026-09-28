import Foundation

/// A folder trash, planned before it is applied.
///
/// Planning is separate from applying for the same reason folder RENAME is: the
/// user gets to see what a destructive, recursive operation will take before it
/// takes it. A folder can hold hundreds of documents and be linked from
/// hundreds more, and "Move to Trash" on a triangle in a sidebar is one
/// mis-click away from every one of them.
public struct FolderTrashPlan: Sendable {
    public let folder: URL
    /// Every indexed document inside the folder, at any depth.
    public let documents: [IndexRow]
    /// How many links from OUTSIDE the folder point into any document inside
    /// it — the count that tells the user what they are about to break. Links
    /// from one soon-to-be-trashed document to another, inside the same
    /// folder, are not counted: both sides are leaving together, so nothing
    /// about that link "breaks" relative to the folder's own contents.
    public let inboundLinkCount: Int
    /// The distinct files OUTSIDE the folder that hold one of those inbound
    /// links — computed once here so `apply` can reindex exactly these files
    /// (and nothing else) instead of the whole vault. See `applyTrashFolder`.
    public let referrers: [URL]
    /// How many open tabs, anywhere under the folder, currently hold unsaved
    /// edits. Surfaced in the preview so the user sees this BEFORE confirming
    /// — `apply` still refuses per-session if a flush fails, same as
    /// `LoreStore.trash`, but a silent refusal after a confirm click reads as
    /// a broken button.
    public let dirtySessionCount: Int
    /// Non-nil when the folder itself cannot be trashed — no vault open, the
    /// target is the vault ROOT itself, or the target resolves outside the
    /// vault entirely (a symlink, or a caller-supplied absolute URL). Shown
    /// INSTEAD of a preview, exactly like `FolderRenamePlan.refusal`.
    public let refusal: String?

    public init(folder: URL, documents: [IndexRow] = [], inboundLinkCount: Int = 0,
                referrers: [URL] = [], dirtySessionCount: Int = 0, refusal: String? = nil) {
        self.folder = folder; self.documents = documents
        self.inboundLinkCount = inboundLinkCount; self.referrers = referrers
        self.dirtySessionCount = dirtySessionCount; self.refusal = refusal
    }
}

extension LoreStore {

    /// Creates a subfolder of `parent`.
    ///
    /// `name` is a single path COMPONENT: separators, `:`, control
    /// characters, and any name that STARTS WITH `.` (which covers `.`, `..`,
    /// `...`, and ordinary dotfiles alike) are REJECTED rather than sanitized.
    /// The leading-dot rejection is not just hygiene: `VaultIndexCoordinator
    /// .scanVault` skips any path component starting with `.`, so a folder
    /// silently accepted with that name would be created, indexed nothing
    /// inside it, and never appear in the sidebar — a folder the user made on
    /// purpose that Lore then acts as if does not exist.
    ///
    /// This is the opposite philosophy from `LoreStore.sanitized(_:)` (Task 9,
    /// attachment filenames) on purpose: an attachment name is usually
    /// machine-generated (a pasted screenshot, a dragged PDF) and the user
    /// never typed it, so silently cleaning up a stray character is invisible
    /// and harmless. A folder name is typed by the user, on purpose, right
    /// now — silently turning "Q1/Reports" into some sanitized stand-in would
    /// create a folder they did not ask for and they would have no reason to
    /// notice the difference until they went looking for the one they thought
    /// they made. A refusal, with a message, is the safer failure here.
    public func createFolder(named name: String, in parent: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControlCharacter = trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !trimmed.isEmpty,
              !trimmed.contains("/"), !trimmed.contains(":"),
              !trimmed.hasPrefix("."), !hasControlCharacter
        else { throw LoreError.invalidName(name) }
        guard let root = vaultRoot,
              parent == root || Self.isContained(parent, in: root)
        else { throw LoreError.outsideVault(parent) }

        // CANONICAL ON WRITE, same discipline `VaultIndexCoordinator` uses
        // throughout: `parent` is trusted only for containment (just
        // checked, symlink-aware, above) — not for SPELLING. A caller that
        // built `parent` from something other than the coordinator's own
        // (already-canonical) `vaultRoot` — a raw `URL` a test or a future
        // caller constructs by hand — would otherwise produce a
        // `destination` spelled inconsistently with `root`, and
        // `vaultRelativePath` below needs both spelled the SAME way (it is a
        // plain string-prefix strip, deliberately not `standardizedFileURL`
        // — see that function's own doc comment for why). `canonical` is
        // `realpath(3)`, which needs `parent` to already exist — guaranteed
        // here, since `parent` is the directory the new folder goes INSIDE,
        // not the folder being created.
        let canonicalParent = VaultIndexCoordinator.canonical(parent)
        let destination = canonicalParent.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path)
        else { throw LoreError.alreadyExists(destination) }

        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false)
        // `coordinator.rows` never gains a row for a directory, and while the
        // watcher's `FSEventStream` DOES see a create inside a subfolder (it
        // is recursive), routing through it would mean waiting on FSEvents'
        // coalescing latency and a full `startBackgroundRebuild()` for a
        // change whose exact content this call already knows. Told directly,
        // with the exact vault-relative path just created, rather than
        // relying on a rescan this call has no reason to trigger. See
        // `VaultIndexCoordinator.noteDirectoryCreated`'s doc comment — this
        // was a real regression (whole-branch review round 3, Critical 1)
        // once `directoryPaths` stopped being an uncached per-render walk
        // that happened to self-heal on the next redraw.
        coordinator.noteDirectoryCreated(Self.vaultRelativePath(destination, under: root))
        return destination
    }

    /// Computes what trashing `folder` would take. Nothing is written.
    ///
    /// Refuses (via `FolderTrashPlan.refusal`) before computing anything else
    /// when there is no vault, the target IS the vault root, or the target
    /// resolves outside the vault: `applyTrashFolder` would otherwise happily
    /// trash the entire vault, or any absolute URL a caller passes in,
    /// because nothing below this line checks containment. The UI's own
    /// guard (the root tree node has no folder menu) is one menu change away
    /// from reaching this with the vault root, so the guard belongs HERE, not
    /// only in the view.
    public func planTrashFolder(_ folder: URL) -> FolderTrashPlan {
        let canonical = VaultIndexCoordinator.canonical(folder)
        guard let root = vaultRoot else {
            return FolderTrashPlan(folder: canonical, refusal: "No vault is open.")
        }
        guard canonical.path != root.path else {
            return FolderTrashPlan(folder: canonical,
                refusal: "The vault's own folder cannot be moved to the Trash.")
        }
        guard Self.isContained(canonical, in: root) else {
            return FolderTrashPlan(folder: canonical,
                refusal: "“\(folder.lastPathComponent)” is outside the vault, "
                    + "so nothing was planned.")
        }

        let prefix = canonical.path.hasSuffix("/") ? canonical.path : canonical.path + "/"
        let documents = rows.filter { $0.path.path.hasPrefix(prefix) }
        let inside = Set(documents.map { $0.path.path })
        var referrers = Set<String>()
        var referrerURLs: [URL] = []
        var inbound = 0
        for row in documents {
            for link in coordinator.inboundLinks(to: row.path)
            where !inside.contains(link.sourceFile.path) {
                inbound += 1
                if referrers.insert(link.sourceFile.path).inserted {
                    referrerURLs.append(link.sourceFile)
                }
            }
        }

        // Every OPEN tab under the folder, not just the indexed ones: a tab on
        // a file that has not been reindexed yet (just created) or on a type
        // the index does not claim is still a tab whose unsaved edits would
        // be lost if the trash proceeded regardless.
        let dirtyCount = tabs.filter { session in
            let path = VaultIndexCoordinator.canonical(session.url).path
            return path.hasPrefix(prefix) && session.isDirty
        }.count

        return FolderTrashPlan(folder: canonical, documents: documents,
                               inboundLinkCount: inbound, referrers: referrerURLs,
                               dirtySessionCount: dirtyCount)
    }

    /// Trashes the folder and everything under it.
    ///
    /// THE ACTUAL INVARIANT is "canonicalize before you mutate", not "remove
    /// before you move". `VaultIndexCoordinator.canonical` is `realpath(3)`
    /// under the hood, which fails on a path that no longer exists and then
    /// returns its argument UNCHANGED — so a canonicalization performed after
    /// the file it names is gone silently keeps whatever spelling the caller
    /// happened to pass in, which may or may not match what is on file.
    ///
    /// `plan.documents[].path` is already canonical — captured once, in
    /// `planTrashFolder`, before any mutation — so the two loops below that
    /// consume it (`coordinator.removeFromIndex(row.path)`,
    /// `forgetOpenMTime(row.path)`) are, empirically, order-INSENSITIVE: their
    /// input never needs to be re-derived from live disk state, so moving
    /// them after `trashItem` does not reproduce a bug (verified directly —
    /// see the task report's "Fix round 1" section for the swapped-order run,
    /// and `FolderOperationsTests.test_orderingRule_canonicalizingAfterTheMoveMissesTheRow`
    /// / `...canonicalizingBeforeTheMoveFindsTheRow` for where reordering
    /// genuinely does flip an outcome).
    ///
    /// What IS order-sensitive in THIS function is anything keyed off a
    /// SESSION's own `url`, because `DocumentSession` never canonicalizes the
    /// URL it was opened with (unlike `IndexRow.path`): the `sessions` filter
    /// just below (subtree containment, via `VaultIndexCoordinator.canonical`)
    /// and `forgetOpenMTime(session.url)` further down both MUST run while
    /// the folder still exists, or `canonical(session.url)` degrades to the
    /// session's raw, possibly non-canonical spelling and either the
    /// containment test or the `openMTimes` key can miss.
    /// `test_trashFolder_forgetsSessionMTimeBeforeTheMoveNotAfter` exercises
    /// this directly.
    ///
    /// Links pointing INTO the folder are deliberately NOT rewritten: there is
    /// no new target to point them at. They become unresolved links — exactly
    /// what `LoreStore.trash` already does for a single document, and for the
    /// same reason: rewriting them would edit files the user did not ask to
    /// touch, to erase a reference they may want to restore from the Trash.
    @discardableResult
    public func applyTrashFolder(_ plan: FolderTrashPlan) throws -> Int {
        guard coordinator.hasIndex else { throw LoreError.noVault }
        // Re-derived independently of `plan.refusal`, the same way `createFolder`
        // checks containment itself rather than trusting a caller to have
        // already planned correctly: a plan is a value, and nothing stops a
        // caller from constructing or replaying a stale/forged one.
        guard let root = vaultRoot else { throw LoreError.noVault }
        guard plan.folder.path != root.path, Self.isContained(plan.folder, in: root)
        else { throw LoreError.outsideVault(plan.folder) }

        let prefix = plan.folder.path.hasSuffix("/") ? plan.folder.path : plan.folder.path + "/"
        // `plan.documents` is also re-validated, not trusted verbatim: the
        // containment check above only re-derives that `plan.folder` itself
        // is legitimate, but a forged plan could pair a legitimate,
        // in-vault `folder` with an arbitrary `documents` list (any row from
        // anywhere in the index). Nothing in that list can move a FILE — only
        // `plan.folder` itself is ever passed to `trashItem` — but an
        // unfiltered list would still remove those rows' index entries and
        // forget their mtime baselines: index-only damage to documents the
        // folder never contained. Filtering to the same subtree prefix used
        // for sessions closes that gap at negligible cost (this list is
        // already small enough to preview).
        let documents = plan.documents.filter { $0.path.path.hasPrefix(prefix) }
        // Derived from the SESSIONS' OWN urls tested for subtree containment,
        // not from `plan.documents`: a tab open on a file the index has not
        // reached yet (created since the last rescan) or on a type the index
        // does not claim is still about to be moved out from under it, and
        // must still be disarmed and closed.
        let sessions = tabs.filter { VaultIndexCoordinator.canonical($0.url).path.hasPrefix(prefix) }

        // Refuse first, mutate second — the same rule `LoreStore.trash`
        // documents at length: a dirty tab whose flush REFUSES (conflicted,
        // read-only-guarded) must stop the whole operation before anything is
        // touched, or the folder moves out from under text the user has never
        // seen saved, taking the only holder of it with it. `force: true`
        // later in this function is safe specifically because every session
        // still open at that point is clean.
        for session in sessions where session.isDirty {
            if !session.isReadOnly { try? session.saveNow() }
            guard !session.isDirty else {
                throw LoreError.unsavedEdits(
                    session.url,
                    session.conflict
                        ? "an open tab under this folder has unsaved edits that cannot be "
                        + "saved because the file was also changed outside Lore. Resolve the "
                        + "conflict in that tab (reload, overwrite, or save a copy), then "
                        + "trash the folder again."
                        : "an open tab under this folder has unsaved edits that could not be "
                        + "saved. Resolve that tab, then trash the folder again.")
            }
        }

        // Disarmed BEFORE the trash: a debounced autosave firing after the
        // move would recreate a file the user just trashed — the exact defect
        // Task 7 found for rename and Task 9's trash guards against, called out
        // again at `DocumentSession.cancelPendingSave`.
        for session in sessions { session.cancelPendingSave() }

        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        // Index rows first, directory second. See the doc comment above.
        for row in documents {
            try? coordinator.removeFromIndex(row.path)
            forgetOpenMTime(row.path)
        }
        // Also for any open session outside `documents` (unindexed type,
        // or created since the last rescan) — its mtime baseline is keyed by
        // its own URL and would otherwise survive pointing at a path that no
        // longer exists, which is exactly how `transferOpenMTime`'s own doc
        // comment says the external-change guard gets disabled for a path
        // that later reappears (e.g. restored from the Trash).
        for session in sessions { forgetOpenMTime(session.url) }

        do {
            try FileManager.default.trashItem(at: plan.folder, resultingItemURL: nil)
        } catch {
            throw LoreError.trashFailed(plan.folder, error.localizedDescription)
        }

        // `coordinator.directoryPaths` has no other path to learn this: the
        // loop above only ever touched INDEXED rows (folders are never
        // rows), and the watcher cannot be relied on either — it is
        // suppressed across this whole call (`suppressWatcher` above) longer
        // than its own debounce, and a trash INSIDE a subfolder fires no
        // root-level event at all regardless. Without this call the trashed
        // folder (and every empty subfolder that was inside it) stays in
        // `directoryPaths` forever, as a ghost node `FolderTreeView` keeps
        // showing for a folder that no longer exists on disk. See
        // `directoryPaths`'s own doc comment for the full list of operations
        // that must make this same call.
        if let root = vaultRoot {
            coordinator.noteDirectoryRemoved(Self.vaultRelativePath(plan.folder, under: root))
        }

        // Tabs close only once the folder is REALLY gone — the same reasoning
        // as single-document trash: a `trashItem` failure must not have
        // already destroyed the tab the user still has open. Every session
        // here is clean (dirty ones already caused a refusal above), so
        // `force` never discards anything.
        for session in sessions { _ = closeTab(session, force: true) }

        // Targeted reindex, NOT a whole-vault `rebuild()`: `removeFromIndex`
        // above only ever touched the TRASHED rows, so every REFERRING
        // document outside the folder — `plan.referrers`, computed once at
        // plan time — still carries a `resolvedLinks` row pointing at a file
        // that is now gone. A whole-vault rescan would fix that too, but it
        // is a synchronous, MainActor-blocking re-walk and re-parse of every
        // file in the vault to fix staleness in a handful of documents.
        // `indexDocument` re-resolves exactly one file's links against the
        // CURRENT `rows` (which the removals above already updated), so a
        // referrer that pointed only into the trashed folder comes back
        // unresolved without touching any file this operation did not
        // already touch. `try?` per file: a referrer that fails to reindex
        // (deleted between plan and apply, unreadable) is recovered by the
        // next natural rescan, and must not fail an operation that already
        // succeeded at trashing the folder.
        for referrer in plan.referrers {
            guard let engine = try? EngineRegistry.load(referrer) else { continue }
            try? coordinator.indexDocument(engine, at: referrer)
        }

        return documents.count
    }
}
