import SwiftUI
import AinkradAppKit

/// Performs what `LoreCommand` merely describes.
///
/// Split from the catalog so the catalog can stay a pure, `Hashable` value —
/// see `LoreCommand`'s own doc comment. This half owns the store, the sidebar
/// operations, and the handful of view-level bindings a command needs to
/// reach (which panel is open, whether the import sheet is up), and it is the
/// ONE place a command's effect is written down.
///
/// Every action here routes through machinery that already exists — a command
/// is a new way to REACH an operation, never a second implementation of it.
/// `newNote` goes through `SidebarOperations.createDocument` (which reports a
/// refusal rather than swallowing it), `closeDocument` through
/// `store.closeTab`'s refusable path, `undoDelete` through
/// `ops.undoLastTrash`. A command that reimplemented any of those would be a
/// second copy of a decision that was reviewed once.
@MainActor
struct LoreCommandRunner {
    let store: LoreStore
    let ops: SidebarOperations
    /// Opens the import sheet. Held as a closure because the sheet's state
    /// lives in `LoreRootView`, not here.
    let beginImport: () -> Void
    /// Opens the linked-mentions slideover. Same reasoning as `beginImport`:
    /// the presentation state lives in the view.
    let showMentions: () -> Void
    /// Opens the palette in the given mode.
    let openPalette: (LorePaletteMode) -> Void
    /// Called after a command that should move focus back to the document.
    let dismissPalette: () -> Void

    /// The context the palette and the shortcut bindings both judge
    /// availability against.
    var context: LoreCommands.Context {
        LoreCommands.Context(hasVault: store.vaultRoot != nil,
                             hasDocument: store.selectedTab != nil,
                             canUndoDelete: store.canUndoTrash,
                             canGoBack: store.canGoBack,
                             canGoForward: store.canGoForward)
    }

    /// Runs `id`, or does nothing if it is not currently available.
    ///
    /// The availability re-check is not belt-and-braces: a shortcut is bound
    /// for as long as its view is mounted, and the palette can be showing a
    /// list built one keystroke ago. Re-asking at the moment of execution is
    /// what keeps "the command was available when I drew it" from becoming
    /// "the command ran when it could not".
    func run(_ id: LoreCommand.ID) {
        guard let command = LoreCommands.all.first(where: { $0.id == id }),
              LoreCommands.isAvailable(command, in: context) else { return }
        dismissPalette()
        switch id {
        case .newNote:
            // Through `ops`, which surfaces the reason when a create cannot
            // happen — the defect `NoVaultTests` exists to prevent.
            if let path = ops.createDocument() { store.open(url: path) }
        case .newFolder:
            if let root = store.vaultRoot { ops.beginNewFolder(in: root) }
        case .chooseVault:
            ops.beginChooseVault()
        case .importNotes:
            beginImport()
        case .toggleSidebar:
            store.setSidebarCollapsed(!store.sidebarCollapsed)
        case .closeDocument:
            // `closeTab` is REFUSABLE and its false return is the data-loss
            // guard — routed through the same helper the close button uses so
            // the refusal dialog appears here too.
            if let session = store.selectedTab { requestClose(session) }
        case .saveNow:
            saveNow()
        case .undoDelete:
            ops.undoLastTrash()
        case .rebuildIndex:
            store.rebuildInBackground()
        case .toggleShowAllFiles:
            store.setShowAllFiles(!store.showAllFiles)
        // ⌘⇧O opens the headings as a filterable JUMP PALETTE, not a panel.
        // The glanceable half of the outline is the always-present spine rail;
        // the keyboard half is this. Neither is a slideover any more.
        case .toggleOutline:
            openPalette(.headings)
        case .toggleBacklinks:
            showMentions()
        case .commandPalette:
            openPalette(.commands)
        case .quickOpen:
            openPalette(.documents)
        case .goBack:
            store.goBack()
        case .goForward:
            store.goForward()
        case .zoomIn:
            store.zoomEditor(by: 1)
        case .zoomOut:
            store.zoomEditor(by: -1)
        case .zoomReset:
            store.resetEditorZoom()
        case .toggleSplit:
            // Toggle, not "open": pressing it again with a split up is the
            // obvious way to close one, and the alternative is a command that
            // only ever adds a pane.
            if store.isSplit { store.closeSecondaryPane() }
            else { store.splitCurrentDocument() }
        // Routed through the responder chain rather than a held reference —
        // see `LoreFind`. A no-op when focus is not in a text view, which is
        // the right answer: ⌘F in the sidebar is not a request to search a
        // document the user is not looking at.
        case .findInDocument:
            LoreFind.perform(.showFindInterface)
        case .findNext:
            LoreFind.perform(.nextMatch)
        case .findPrevious:
            LoreFind.perform(.previousMatch)
        case .replaceInDocument:
            LoreFind.perform(.showReplaceInterface)
        // Same responder-chain dispatch as find, and a no-op when focus is
        // outside a text view — see `LoreFormatting`.
        case .formatBold: LoreFormatting.perform(.bold)
        case .formatItalic: LoreFormatting.perform(.italic)
        case .formatCode: LoreFormatting.perform(.inlineCode)
        case .formatLink: LoreFormatting.perform(.link)
        case .formatBulletList: LoreFormatting.perform(.bulletList)
        case .formatTaskList: LoreFormatting.perform(.taskList)
        case .formatQuote: LoreFormatting.perform(.quote)
        case .headingLevel1: LoreFormatting.perform(.heading1)
        case .headingLevel2: LoreFormatting.perform(.heading2)
        case .headingLevel3: LoreFormatting.perform(.heading3)
        case .headingBody: LoreFormatting.perform(.body)
        }
    }

    /// ⌘S. Autosave already debounces every edit to disk, so this is not what
    /// makes the work safe — it is what lets someone who does not trust an
    /// invisible autosave ask for the write NOW and see the header say so.
    ///
    /// A conflict is left to the banner rather than reported here: it has
    /// three resolutions and a toast cannot offer a choice.
    private func saveNow() {
        guard let session = store.selectedTab, !session.isReadOnly else { return }
        try? session.saveNow()
    }

    /// Routes a close through the refusal path, so unsaved work that cannot be
    /// flushed raises the same "Close anyway?" question the tab's own button
    /// does instead of silently keeping the document open.
    private func requestClose(_ session: DocumentSession) {
        if !store.closeTab(session) { ops.refusedClose = session }
    }
}

/// What the palette is currently listing.
enum LorePaletteMode: Hashable {
    /// ⌘K — run a command.
    case commands
    /// ⌘P — open a document by name.
    case documents
    /// ⌘⇧O — jump to a heading in the open document.
    case headings
}
