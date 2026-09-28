import Foundation

// Trash-backed deletion — the ONLY deletion path in Lore. The legacy
// `LoreStore.delete(_:)`, a permanent `removeItem` whose two callers each
// reached it with a live "a debounced autosave recreates the deleted file"
// defect, is gone: a permanent-delete path with a known resurrection bug has
// no business outliving the milestone that added a safe one.
//
// Lives in its own file so `LoreStore.swift` and the two rename files all stay
// under the 500-line ceiling.
extension LoreStore {

    /// Moves `row`'s file to the macOS Trash.
    ///
    /// Returns how many documents currently link to it, so the caller (Task
    /// 10's UI) can warn before the user confirms. Those inbound links are
    /// deliberately NOT rewritten: an unresolved link to a deleted note is the
    /// correct outcome, and is how the user later finds what broke.
    ///
    /// NEVER falls back to `removeItem` on failure — a network volume or an
    /// external drive with no `.Trashes` throws `trashFailed` instead. Quietly
    /// doing something less safe (a permanent delete) than the user asked for
    /// (a recoverable one) is its own bug, so this stops before touching the
    /// file.
    ///
    /// ## A tab with UNSAVED edits refuses the delete
    ///
    /// A dirty tab is flushed first, so the unsaved text lands in the Trash
    /// with the rest of the file and a Trash restore recovers exactly what the
    /// user last saw. But that flush can REFUSE — the session was already in
    /// `conflict` (someone else edited the file), or `guardWritable` rejects a
    /// read-only document. The first cut ignored that (`try? saveNow()`) and
    /// then force-closed the tab unconditionally, which meant: the file was
    /// trashed carrying STALE content, and the only holder of the user's edits
    /// was destroyed in the same breath. Silently, and with no channel to say
    /// so — `trash` returns an `Int`.
    ///
    /// So a still-dirty session REFUSES the delete, throwing `unsavedEdits`.
    /// The session is left open, dirty, and with its `conflict` intact so the
    /// user can resolve it (reload, overwrite, or save a copy) and delete
    /// again. Deleting is not urgent enough to justify destroying text the user
    /// has never seen saved — and unlike the flush-and-delete outcome, this one
    /// is recoverable by doing nothing.
    ///
    /// Every check runs BEFORE any tab is closed and before the file is
    /// touched, and the tabs close only AFTER `trashItem` actually succeeds —
    /// so any refusal, at either stage, leaves the store exactly as it found
    /// it: file present, tab open.
    @discardableResult
    public func trash(_ row: IndexRow) throws -> Int {
        guard coordinator.hasIndex else { throw LoreError.noVault }
        // `DocumentSession` never canonicalizes the URL it was opened with, so
        // a tab opened via `open(url:)` with a caller-supplied path must be
        // matched canonically or `trash` deletes the file out from under it.
        let path = VaultIndexCoordinator.canonical(row.path)
        let inbound = inboundLinkCount(to: path)
        let sessions = tabs.filter { VaultIndexCoordinator.canonical($0.url) == path }

        // Refuse first, mutate second.
        for session in sessions where session.isDirty {
            if !session.isReadOnly { try? session.saveNow() }
            guard !session.isDirty else {
                throw LoreError.unsavedEdits(
                    path,
                    session.conflict
                        ? "it has unsaved edits that cannot be saved because the file was "
                        + "also changed outside Lore. Resolve the conflict in the open tab "
                        + "(reload, overwrite, or save a copy), then delete it again."
                        : "it has unsaved edits that could not be saved. Resolve the open "
                        + "tab, then delete it again.")
            }
        }

        // Disarming pending saves happens BEFORE the trash: a debounced
        // autosave firing after the file is trashed would recreate the very
        // file the user just deleted — the exact defect Task 7 found and fixed
        // for rename. It is also harmless if the trash then fails; the session
        // is still open and still holds its (clean) text.
        for session in sessions { session.cancelPendingSave() }

        // Our own mutation. Without this the watcher wakes and queues a
        // whole-vault rescan on top of the targeted `removeFromIndex` below.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        // `resultingItemURL` — where macOS ACTUALLY put the file, which is not
        // derivable from the original path (the Trash de-duplicates names by
        // appending a timestamp). This used to be `nil`, which is the single
        // reason undoing a delete looked like it needed a store redesign: with
        // the destination in hand, the reversal is a `moveItem` and a re-index.
        var restored: NSURL?
        do {
            try FileManager.default.trashItem(at: row.path, resultingItemURL: &restored)
        } catch {
            throw LoreError.trashFailed(row.path, error.localizedDescription)
        }

        // Tabs close only once the file is REALLY gone. Closing them first
        // meant a `trashItem` failure — a network volume with no `.Trashes`, a
        // permissions refusal — left the user reading "nothing was deleted"
        // while the tab they had open had vanished. No text was lost (a dirty
        // session is refused or flushed above), but a UI that lies about what
        // happened is how a user stops trusting the ones that don't.
        for session in sessions { _ = closeTab(session, force: true) }
        // One spelling is enough, and it must be THIS one — `path`, canonicalized
        // at the top of this function, BEFORE `trashItem` moved the file.
        //
        // Not because `remove(path:)` canonicalizes its argument: by here the
        // file is gone, `realpath(3)` fails on a vanished path, and `canonical`
        // then returns its argument untouched. Passing `row.path` would reach
        // SQLite spelled raw and match no row — a silent ghost entry. The
        // previous dual-spelling calls were a workaround for `indexDocument`
        // storing the caller's URL verbatim; that hole is closed, but the
        // ordering here is load-bearing on its own. Canonicalize before you
        // delete, never after.
        try? coordinator.removeFromIndex(path)
        forgetOpenMTime(path)
        // Armed only on the success path, and only when macOS told us where the
        // file went. A `nil` `resultingItemURL` (documented as possible) means
        // we cannot find the file again, so we offer no undo rather than an
        // undo button that fails when pressed.
        lastTrash = (restored as URL?).map {
            TrashUndo(original: path, trashed: $0, name: row.path.lastPathComponent)
        }
        if let armed = lastTrash { expireUndo(armed) }
        return inbound
    }

    /// How long ⌘Z stays claimed after a delete.
    ///
    /// Matched to the toast that ADVERTISES the undo: the offer and the way to
    /// take it must not outlive each other in either direction. A user who
    /// reads "Press ⌘Z to undo", looks away, and presses ⌘Z a minute later
    /// deserves to have it work — but the cost of leaving it armed is far
    /// worse than that miss, because ⌘Z in a text editor means "undo my
    /// typing". An indefinitely-armed record turns every later ⌘Z in the open
    /// document into a file restore, which is both surprising and destructive
    /// of the edit the user actually wanted reversed.
    static let undoWindow: TimeInterval = 3

    /// Disarms `record` once the undo window closes.
    ///
    /// Compares before clearing, so a SECOND delete arriving inside the first
    /// one's window does not have its fresh record wiped by the older timer —
    /// the comparison is the whole reason this takes the record as a
    /// parameter rather than just nilling `lastTrash`.
    private func expireUndo(_ record: TrashUndo) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.undoWindow * 1_000_000_000))
            guard let self, self.lastTrash == record else { return }
            self.lastTrash = nil
        }
    }

    /// Puts the last trashed file back, and re-indexes it.
    ///
    /// Reverses `trash(_:)`'s file move and its index removal — and NOTHING
    /// else. In particular it does not reopen the tab `trash` closed: the tab
    /// was closed clean (a dirty one refuses the delete outright), so nothing
    /// is lost by leaving it shut, and silently reopening tabs is a surprise
    /// the user did not ask for. The file is back where it was and the sidebar
    /// shows it again, which is what "undo the delete" means.
    ///
    /// Inbound links need no repair: `trash` deliberately never rewrote them,
    /// so they still name this file and simply resolve again the moment it
    /// exists.
    ///
    /// Consumes the record whether or not it succeeds — a failed restore has
    /// already told the user why, and leaving a stale record armed invites a
    /// second press that fails the same way.
    public func undoTrash() throws {
        guard let undo = lastTrash else { return }
        lastTrash = nil
        // Refuse before moving anything: the original name may be taken again.
        guard !FileManager.default.fileExists(atPath: undo.original.path) else {
            throw LoreError.restoreBlocked(undo.original)
        }
        // Our own mutation, same as `trash` — without this the watcher wakes
        // and queues a whole-vault rescan on top of the targeted re-index.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        do {
            try FileManager.default.moveItem(at: undo.trashed, to: undo.original)
        } catch {
            throw LoreError.restoreFailed(undo.original, error.localizedDescription)
        }
        // Through `EngineRegistry`, not `MarkdownEngine`: an attachment, a PDF
        // and a rich-text file are all trashable, so the restore must index
        // whatever the file actually is rather than assume markdown.
        if let engine = try? EngineRegistry.load(undo.original) {
            try? coordinator.indexDocument(engine, at: undo.original)
        }
    }
}
