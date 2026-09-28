import Foundation
import AppKit
import Observation

/// The state machine behind the sidebar's rename / move / trash affordances,
/// shared by BOTH sidebar modes (flat list and folder tree) so neither grows
/// its own copy of a destructive flow.
///
/// Deliberately a plain observable object rather than view state: SwiftUI is
/// only smoke-testable in this project, and the behaviour that matters here is
/// not layout. Three things in particular are asserted directly against this
/// type in `SidebarOperationsTests`:
///
///  - a plan carrying a `refusal` produces a preview that CANNOT be confirmed;
///  - a refused trash produces a visible `message` instead of vanishing;
///  - a move outside the vault root is refused before any plan is built.
@MainActor
@Observable
final class SidebarOperations {

    /// What a name prompt is currently naming.
    enum NameTarget: Equatable {
        case document(URL)
        case folder(URL)
        /// A NEW folder about to be created inside the associated parent —
        /// distinct from `.folder`, which names an EXISTING folder being
        /// renamed, because the two need different verbs and different store
        /// calls on confirm.
        case newFolder(URL)
    }

    /// The plan a preview is showing, kept so `confirm()` applies exactly the
    /// plan the user reviewed — never a freshly recomputed one. Recomputing at
    /// confirm time would silently re-read the plan-time mtime baselines, which
    /// is precisely what makes the "changed on disk" guard tautological.
    private enum Pending {
        case document(RenamePlan, isMove: Bool)
        case folder(FolderRenamePlan)
        case trashFolder(FolderTrashPlan)
    }

    private let store: LoreStore
    private var pending: Pending?

    /// Non-nil while the name prompt is up.
    var nameTarget: NameTarget?
    var nameText: String = ""
    /// Non-nil while the confirmation sheet is up.
    var preview: RenamePreview?
    /// Non-nil once the reviewed plan has been applied; the sheet reports it.
    var report: RenameReport?
    /// A refusal or failure with no sheet of its own — most importantly a
    /// REFUSED TRASH, which used to be a silent no-op (`try? store.trash(row)`).
    ///
    /// FAILURES ONLY. Successes go to `notice` below: this one is rendered by
    /// `MessageSheet`, whose heading is the literal word "Not done", so a
    /// success routed here told the user "Not done: Created “Projects”." —
    /// which is not merely ugly, it is the opposite of what happened. Both
    /// `commitName`'s create and `confirm`'s folder-trash did exactly that.
    var message: String?
    /// A transient outcome to surface as a toast rather than a modal.
    ///
    /// The split between this and `message` is by WEIGHT, not by success and
    /// failure: anything the user must acknowledge and act on stays a sheet;
    /// anything that is merely worth knowing — including a soft failure the
    /// user cannot do anything about — is a toast that expires on its own.
    /// A modal for "created a folder" interrupts the work it just completed.
    var notice: Notice?

    /// One transient outcome, and how loudly to say it.
    struct Notice: Equatable {
        enum Kind: Equatable { case success, failure }
        let text: String
        let kind: Kind
    }

    /// The row a trash was requested for, awaiting confirmation.
    var pendingTrash: IndexRow?

    /// The session whose close was REFUSED — `closeTab` returned false,
    /// meaning it still holds unsaved work and is still open.
    ///
    /// Lifted here from `TabBarView`'s local `@State` so that ⌘W reaches the
    /// same refusal question whether it was pressed on the tab strip or run as
    /// a command. Left in the view, the command path would have had to either
    /// duplicate the dialog or — far worse — ignore the `false` return, which
    /// is precisely the data-loss bug that return value exists to prevent.
    var refusedClose: DocumentSession?

    /// The sentence explaining why a close was refused.
    ///
    /// Moved here with `refusedClose` for the same reason: one refusal, one
    /// explanation, reachable from every path that can trigger it.
    var refusedCloseMessage: String {
        guard let session = refusedClose else { return "" }
        let name = session.title.isEmpty ? session.url.lastPathComponent : session.title
        if session.conflict {
            return "“\(name)” changed on disk outside Lore, so its unsaved edits couldn't be "
                 + "saved. Close anyway and those edits are lost — or cancel and resolve the "
                 + "conflict in the document."
        }
        if let error = session.lastSaveError {
            return "“\(name)” couldn't be saved: \(error.localizedDescription). "
                 + "Close anyway and its unsaved edits are lost."
        }
        return "“\(name)” still has unsaved changes that couldn't be saved. "
             + "Close anyway and they are lost."
    }

    /// Discards the refused session's unsaved work, at the user's explicit
    /// request.
    func confirmForcedClose() {
        if let session = refusedClose { store.closeTab(session, force: true) }
        refusedClose = nil
    }

    init(store: LoreStore) { self.store = store }

    // MARK: - Rename

    func beginRename(_ row: IndexRow) {
        nameTarget = .document(row.path)
        nameText = row.path.deletingPathExtension().lastPathComponent
    }

    func beginRenameFolder(_ folder: URL) {
        nameTarget = .folder(folder)
        nameText = folder.lastPathComponent
    }

    /// Asks for the name of a new folder inside `parent`. Unlike rename/move,
    /// there is nothing to preview here — creating an empty directory affects
    /// nothing else in the vault — so confirming the name sheet performs the
    /// create directly instead of routing through a plan/preview.
    func beginNewFolder(in parent: URL) {
        nameTarget = .newFolder(parent)
        nameText = ""
    }

    /// Turns the typed name into a PLAN and a preview for the `.document` and
    /// `.folder` (rename) targets — those two never write, a refusal (empty
    /// name, path separator, `..`, escape from the vault, destination exists)
    /// arriving on the plan and rendered instead of a preview. `.newFolder` is
    /// NOT plan-and-preview: it calls `store.createFolder` directly and does
    /// write a real directory immediately (see `beginNewFolder`'s doc comment
    /// on why folder creation skips the plan/preview step the other two use).
    func commitName() {
        guard let target = nameTarget else { return }
        nameTarget = nil
        switch target {
        case .document(let url):
            let plan = store.plan(rename: url, to: nameText)
            pending = .document(plan, isMove: false)
            preview = RenamePreview(document: plan, isMove: false)
        case .folder(let url):
            let plan = store.plan(renameFolder: url, to: nameText)
            pending = .folder(plan)
            preview = RenamePreview(folder: plan)
        case .newFolder(let parent):
            do {
                let created = try store.createFolder(named: nameText, in: parent)
                notice = Notice(text: "Created “\(created.lastPathComponent)”.",
                                kind: .success)
            } catch let error as LoreError {
                message = Self.describeCreateFolder(error)
            } catch {
                message = "The folder could not be created: \(error.localizedDescription)"
            }
        }
    }


    func cancelName() { nameTarget = nil }

    // MARK: - Vault selection

    /// Asks for a vault folder, then opens it.
    ///
    /// Lore's only vault picker used to live in `makeSettingsView`. The Dev
    /// Host renders `makeRootView` and nothing else, so under it there was no
    /// reachable way to select a vault — and every affordance that needs one
    /// (create, search, the whole sidebar) was permanently inert with no
    /// explanation. A first-run action belongs on the surface the user is
    /// actually looking at.
    func beginChooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open vault"
        panel.message = "Choose the folder that holds your notes."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        selectVault(folder)
    }

    /// The testable half: open `folder` as the vault, reporting any failure.
    ///
    /// `LoreSettingsView.pickFolder` did this as `try? store.setVaultRoot(url)`
    /// — so a vault that could not be bookmarked or indexed left the user
    /// looking at an unchanged, empty window with nothing said. Same class of
    /// defect as the swallowed create below, on the step immediately before it.
    func selectVault(_ folder: URL) {
        do {
            try store.setVaultRoot(folder)
            message = nil
        } catch {
            message = "“\(folder.lastPathComponent)” could not be opened as a vault: "
                + error.localizedDescription
        }
    }

    // MARK: - Create

    /// Creates an untitled document and returns its URL, or nil having set
    /// `message` to the reason it could not.
    ///
    /// The reported bug: `LoreRootView.quickCapture` was
    /// `guard let note = try? store.create(title: "") else { return }`. With no
    /// vault open `create` throws `.noVault`, `try?` discarded it, and the
    /// button did nothing — indistinguishable from a dead button, which is
    /// precisely how it was reported. This is the same fix, and the same
    /// reasoning, already written down for delete in `deleteDocument`.
    @discardableResult
    func createDocument() -> URL? {
        do {
            let note = try store.create(title: "")
            message = nil
            return note.path
        } catch let error as LoreError {
            message = Self.describeCreate(error)
            return nil
        } catch {
            message = "The document could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Move

    /// Asks for a destination folder, then previews the move. The panel opens
    /// AT the vault root, but a panel can be navigated anywhere, so the choice
    /// is validated rather than trusted — see `move(_:toFolder:)`.
    func beginMove(_ row: IndexRow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move here"
        panel.directoryURL = store.vaultRoot
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        move(row, toFolder: folder)
    }

    /// The testable half of the move: validate the destination, then plan.
    ///
    /// A destination outside the vault is refused HERE, with a message, rather
    /// than planned: the store would happily move the file, but its inbound
    /// links have no vault-relative path to be rewritten to, so every
    /// explicit-path link to it breaks and the file leaves the index.
    func move(_ row: IndexRow, toFolder folder: URL) {
        // Through `SidebarDrop`, which is also what decides whether a drag
        // HIGHLIGHTS this folder — so a target that lit up cannot then refuse
        // the drop, which would read as the app changing its mind.
        if let rejection = SidebarDrop.rejection(moving: row.path, into: folder,
                                                 root: store.vaultRoot) {
            message = SidebarDrop.describe(rejection, source: row.path, folder: folder)
            return
        }
        let destination = VaultIndexCoordinator.canonical(folder)
        let plan = store.plan(move: row.path, toFolder: destination)
        pending = .document(plan, isMove: true)
        preview = RenamePreview(document: plan, isMove: true)
    }

    // MARK: - Confirming

    /// Applies the reviewed plan. Only reachable when `preview.canConfirm`.
    func confirm() {
        guard let pending, preview?.canConfirm == true else { return }
        switch pending {
        case .document(let plan, let isMove):
            let result = store.apply(plan)
            report = result
            // Only an actual RENAME (basename change) needs the title synced
            // — a plain move to another folder (`isMove`) keeps its name, so
            // its title (already equal to that name) is untouched. Only on
            // full success: a partial rename (e.g. the move itself failed,
            // or the destination was left at the source because of a
            // refusal) must not go patch a title onto a file that never
            // actually got the new name.
            if !isMove, let moved = result.movedTo, result.failed.isEmpty {
                store.syncTitleAfterFileRename(at: moved)
            }
        case .folder(let plan): report = store.apply(plan)
        case .trashFolder(let plan):
            // No `RenameReport` here — `applyTrashFolder` isn't a link
            // rewrite, it's a move-to-Trash, so it reports through `message`
            // exactly like single-document trash's `confirmTrash` does,
            // rather than forcing its result through a report shape built for
            // rewritten/skipped/unchanged files.
            preview = nil
            do {
                let count = try store.applyTrashFolder(plan)
                notice = Notice(
                    text: "Moved “\(plan.folder.lastPathComponent)” to the Trash "
                        + "(\(count) document\(count == 1 ? "" : "s")).",
                    kind: .success)
            } catch let error as LoreError {
                message = Self.describe(error, folder: plan.folder)
            } catch {
                message = "The folder could not be moved to the Trash: "
                    + error.localizedDescription
            }
            self.pending = nil
            return
        }
        self.pending = nil
    }

    /// The user-facing sentence for each way a folder trash can be declined.

    /// Dismisses the sheet in either of its states.
    func dismiss() {
        preview = nil
        report = nil
        pending = nil
    }

    // MARK: - Trash

    /// Asks for confirmation. The inbound-link count is read BEFORE the delete
    /// (afterwards there is nothing to count) and stated when non-zero: those
    /// links are deliberately NOT rewritten, so the user must know they will
    /// stop resolving.
    func requestTrash(_ row: IndexRow) { pendingTrash = row }

    /// Plans a recursive folder trash and shows it through the SAME `.preview`
    /// sheet single/folder rename uses — a destructive, recursive operation
    /// gets the full preview treatment (document count, inbound link count),
    /// not the one-line confirm dialog a single document gets.
    func requestTrashFolder(_ folder: URL) {
        let plan = store.planTrashFolder(folder)
        pending = .trashFolder(plan)
        preview = RenamePreview(trashFolder: plan)
    }

    func trashMessage(for row: IndexRow) -> String {
        let name = row.title.isEmpty ? row.path.lastPathComponent : row.title
        var text = "Move “\(name)” to the Trash?"
        let inbound = store.inboundLinkCount(to: row.path)
        if inbound > 0 {
            text += " \(inbound) note\(inbound == 1 ? "" : "s") link here. "
                + "Their links will stop resolving, and are not rewritten."
        }
        return text
    }

    /// Performs the delete, SURFACING every refusal.
    ///
    /// The previous implementation was `try? store.trash(row)`. `trash` refuses
    /// when a tab still holds unsaved edits it could not flush — so the user
    /// pressed Delete, nothing happened, and nothing said why. A refusal the
    /// user cannot see is indistinguishable from a broken button, and the
    /// obvious next move (press it again, harder) never works.
    func confirmTrash() {
        guard let row = pendingTrash else { return }
        pendingTrash = nil
        let name = row.path.lastPathComponent
        // One implementation, in `deleteDocument`, which the store-level test
        // drives directly. A non-nil return is a REFUSAL and keeps the modal
        // treatment: it names something the user has to resolve before the
        // delete can happen at all.
        if let refusal = deleteDocument(row, in: store) {
            message = refusal
            return
        }
        // The undo hint is conditional on there actually BEING an undo:
        // `trash` only arms `lastTrash` when macOS told it where the file
        // went. Promising ⌘Z when nothing would happen is worse than staying
        // quiet about it.
        notice = Notice(
            text: store.canUndoTrash
                ? "Moved “\(name)” to the Trash. Press ⌘Z to undo."
                : "Moved “\(name)” to the Trash.",
            kind: .success)
    }

    func cancelTrash() { pendingTrash = nil }

    /// Puts back the file the last confirmed trash removed.
    ///
    /// Bound to ⌘Z by `LoreRootView`. A no-op when there is nothing to undo,
    /// so the shortcut is safe to press at any time — and deliberately silent
    /// in that case rather than reporting "nothing to undo", which would turn
    /// an idle keystroke into an interruption.
    func undoLastTrash() {
        guard let pending = store.lastTrash else { return }
        let name = pending.name
        do {
            try store.undoTrash()
            notice = Notice(text: "Restored “\(name)”.", kind: .success)
        } catch let error as LoreError {
            // A refused restore is a MODAL: the file is still in the Trash and
            // the user has a decision to make about the name that now blocks
            // it. That is not toast-weight.
            message = Self.describeRestore(error)
        } catch {
            message = "“\(name)” couldn't be restored: \(error.localizedDescription)"
        }
    }

    /// Whether ⌘Z currently has a delete to reverse.
    var canUndoTrash: Bool { store.canUndoTrash }

    /// The user-facing sentence for each way a delete can be declined. Pure, so
    /// it is asserted directly rather than through a view.

    /// The user-facing sentence for each way undoing a delete can fail.
    ///
}
