import Foundation

extension VaultIndexCoordinator {
    /// Kicks off an off-actor rescan, coalescing with one already in flight.
    ///
    /// FSEvents delivers bursts (a `git checkout` in the vault is hundreds of
    /// events), and each used to start its own full synchronous rescan on the
    /// main actor. Now at most one runs at a time, off the main actor, and a
    /// burst arriving during one schedules exactly one follow-up.
    func startBackgroundRebuild() {
        guard !isRebuilding else {
            rebuildRequestedAgain = true
            return
        }
        isRebuilding = true
        Task { [weak self] in
            await self?.performBackgroundRebuild()
        }
    }

    private func performBackgroundRebuild() async {
        defer {
            isRebuilding = false
            startEmbedding()
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
            guard self.index === index else { return }  // shut down meanwhile
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
            let indexedDirectories = try? index.indexedDirectories()
        {
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
    private enum RebuildOutcome: Sendable {
        case done(rows: [IndexRow], directories: [String])
        case failed(String)
    }
}
