import SwiftUI
import AppKit
import AinkradAppKit

struct LoreRootView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @State private var query = ""
    @State private var selected: IndexRow?
    @State private var activeTag: String?
    /// The file the user most recently asked to open. `LoreStore.openError` is
    /// only cleared by the next SUCCESSFUL open, so it can outlive the click
    /// that produced it; gating the fallback viewer on this makes sure a stale
    /// error never shadows a document that opened perfectly well.
    @State private var attempted: URL?
    /// Rename / move / trash for both sidebar modes. Created here so the two
    /// sidebars share one state machine and one set of modals.
    @State private var ops: SidebarOperations
    /// Non-nil while the import sheet is up. Built per presentation, so a
    /// finished import cannot leave its report showing the next time the sheet
    /// opens — the coordinator's whole lifetime is one import.
    @State private var importing: ImportCoordinator?
    /// Non-nil while the command palette is up, carrying which list it shows.
    @State private var palette: LorePaletteMode?
    /// The open document's headings and its scroll handler, published upward by
    /// `DocumentPane` so ⌘⇧O can jump without this view re-parsing the
    /// document — `MarkdownEngine.outline` is a full AST parse.
    @State private var outline: [OutlineEntry] = []
    @State private var jumpToOffset: ((Int) -> Void)?
    /// Set when ↓ is pressed in the search field, handing the keyboard to the
    /// results list. `NoteListView` consumes and clears it.
    @State private var listFocusRequest: Bool?
    /// A request to show the linked-mentions slideover, raised by the document
    /// actions menu or ⌘⇧B. `DocumentPane` consumes it.
    @State private var mentionsRequest = false
    /// Whether the document's ⋯ menu is open. Lives here because the header
    /// bar is too short to host it without clipping — the pane renders it.
    @State private var showingActions = false
    /// How much of the editor area the FIRST pane takes, 0…1.
    ///
    /// Session state, not persisted — decision 2.4: a split is a working
    /// arrangement for a task rather than a preference, so neither the split
    /// nor its proportions survive a relaunch.
    @State private var splitFraction: CGFloat = 0.5
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradTypography) private var typo

    init(store: LoreStore, theme: HostTheme) {
        self.store = store
        self.theme = theme
        _ops = State(initialValue: SidebarOperations(store: store))
    }

    /// Everything a command needs in order to run, assembled once.
    ///
    /// Rebuilt per render rather than stored: it is a bundle of references and
    /// closures over this view's own state, so a cached copy would capture a
    /// stale `importing`/`palette` binding — and its `context` must be read at
    /// the moment a command runs, not at the moment it was drawn.
    private var runner: LoreCommandRunner {
        LoreCommandRunner(
            store: store,
            ops: ops,
            beginImport: {
                if let root = store.vaultRoot {
                    importing = ImportCoordinator(vaultRoot: root)
                }
            },
            // Linked mentions are summoned, not resident — see
            // `DocumentMentionsList`. ⌘⇧B and the document's actions menu
            // raise the same request.
            showMentions: { mentionsRequest = true },
            openPalette: { palette = $0 },
            dismissPalette: { palette = nil })
    }

    /// A filtered tree of mostly-empty branches is worse than a list, so an
    /// active search or tag filter always wins over the persisted tree
    /// preference — the tree is only shown when nothing is filtering it.
    private var effectiveSidebarMode: LoreStore.SidebarMode {
        (query.isEmpty && activeTag == nil) ? store.sidebarMode : .all
    }

    var body: some View {
        HStack(spacing: 0) {
            if !store.sidebarCollapsed {
                sidebar
                    .frame(width: store.sidebarWidth)
                    // Surface hierarchy: the sidebar is CHROME and sits on
                    // `surface`, the editor is CONTENT and stays on
                    // `background`. Every one of these was `background`
                    // before, which is why the window read as one
                    // undifferentiated field with a list floating in it —
                    // `surface` went entirely unused in the app.
                    .background(theme.tokens.surface)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarResizeHandle(width: store.sidebarWidth, theme: theme) { width in
                    store.setSidebarWidth(width)
                }
            }
            content
            // Attached HERE, not at the root, on purpose: `loreSidebarOperations`
            // already owns a `.sheet` on the root view, and two `.sheet`
            // modifiers on the same view are unreliable on macOS — with the
            // failure mode being a dialog that silently never appears (see
            // `SidebarOperationsPresentation`).
            .sheet(item: $importing) { coordinator in
                ImportEntryView(coordinator: coordinator, theme: theme,
                                onClose: { importing = nil })
            }
        }
        .background(theme.tokens.background)
        .environment(\.ainkradTheme, theme.tokens)
        // Mounted ONCE, at the surface root, so every toast in Lore stacks in
        // the same corner regardless of which view raised it. Must sit ABOVE
        // `loreSidebarOperations` below, whose `LoreNoticeBridge` reads the
        // center this injects.
        .ainkradToastHost()
        // Every shortcut in the app, bound from ONE list. Replaces the
        // hand-placed overlays that used to sit at each command's point of
        // use — see `LoreCommandShortcuts`, including why availability gates
        // the binding itself rather than just the action.
        .loreCommandShortcuts(runner)
        // An OVERLAY, not a `.sheet`. Two reasons, and the first is a hard
        // constraint: `loreSidebarOperations` below already owns a `.sheet` on
        // this same view, and two `.sheet` modifiers on one view are
        // unreliable on macOS — the failure mode being a dialog that silently
        // never appears (see `SidebarOperationsPresentation`). The second is
        // that a command palette is not a document-modal question; it is a
        // transient surface over the work, which is what an overlay reads as.
        .overlay {
            if let mode = palette {
                LorePalette(mode: mode, store: store, runner: runner, theme: theme,
                            outline: outline,
                            onDismiss: { palette = nil },
                            onJumpToOffset: { jumpToOffset?($0) })
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : AinkradMotion.materialize, value: palette)
        // Attached at the surface ROOT: `ainkradConfirmDialog` dims and centers
        // within the view it modifies, so attaching it to the 280pt sidebar
        // would scope a destructive confirmation to a narrow column.
        .loreSidebarOperations(ops, theme: theme)
        // A rename, a move or a delete makes a held `IndexRow` stale — its path
        // no longer names a file. Dropped when the row set changes, so the
        // sidebar cannot keep a selection pointing at something that is gone
        // (and `content` cannot keep showing a fallback for it).
        .onChange(of: store.rows.count) { _, _ in
            if let row = selected, !store.rows.contains(where: { $0.path == row.path }) {
                selected = nil
            }
            if let url = attempted, !store.rows.contains(where: { $0.path == url }) {
                attempted = nil
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            // Search and quick-capture live ABOVE the mode picker, outside
            // both sidebars. They used to live inside `NoteListView`, which
            // is not mounted in tree mode — so in tree mode the user could
            // not search and could not create a note at all. Typing a query
            // still swings the sidebar to the flat list (see
            // `effectiveSidebarMode`); the point is that the field exists to
            // type into either way.
            HStack(spacing: AinkradSpacing.sm) {
                AinkradSearchField(text: $query, placeholder: "Search notes")
                    // ↓ hands the keyboard to the results. Without this, the
                    // only way from a typed query to the note it found was the
                    // mouse — which is the whole reason a search field that
                    // filters a list is not a search surface.
                    .onMoveCommand { direction in
                        if direction == .down { listFocusRequest = true }
                    }
                    // Esc clears the query rather than dismissing anything:
                    // `onExitCommand` is scoped to the focused view, so this
                    // only fires while the caret is in the field, and clearing
                    // is what Esc means in a search box.
                    .onExitCommand { query = "" }
                // Folder creation belongs to Folders mode only — "All
                // notes" (`NoteListView`) has no folder affordances at
                // all, by design. Gated on `effectiveSidebarMode` rather
                // than `store.sidebarMode` so an active search/tag filter
                // (which silently forces the flat list — see
                // `effectiveSidebarMode`) hides this too: it would
                // otherwise sit above a list that is not the tree, next to
                // rows it cannot affect.
                if effectiveSidebarMode == .tree, let root = store.vaultRoot {
                    AinkradIconButton(systemName: "folder.badge.plus",
                                     tooltip: "New Folder") {
                        ops.beginNewFolder(in: root)
                    }
                    // A tooltip is not a label: it needs a pointer to hover,
                    // so VoiceOver got nothing but the SF Symbol name for all
                    // three of these buttons.
                    .accessibilityLabel("New folder")
                }
                if let root = store.vaultRoot {
                    AinkradIconButton(systemName: "square.and.arrow.down",
                                     tooltip: "Import…") {
                        importing = ImportCoordinator(vaultRoot: root)
                    }
                    .accessibilityLabel("Import notes")
                }
                AinkradIconButton(systemName: "plus", action: quickCapture)
                    .accessibilityLabel("New note")
            }
            .padding(.horizontal, AinkradSpacing.md)
            .padding(.top, AinkradSpacing.md)

            // Bound to the EFFECTIVE mode, not the persisted preference.
            //
            // An active search or tag filter silently forces the flat list
            // (see `effectiveSidebarMode`), and the picker used to go on
            // showing "Folders" as selected the whole time — a control
            // reporting a state the app is visibly not in. Now it reports what
            // is on screen, and choosing "Folders" while filtering CLEARS the
            // filter rather than doing nothing, because that is the only way
            // the tree could actually appear.
            AinkradSegmentedPicker(
                items: [LoreStore.SidebarMode.tree, .all],
                selection: Binding(
                    get: { effectiveSidebarMode },
                    set: { mode in
                        if mode == .tree { query = ""; activeTag = nil }
                        store.setSidebarMode(mode)
                    })
            ) { mode in mode == .tree ? "Folders" : "All notes" }
            .padding(.horizontal, AinkradSpacing.md)
            // Says WHY the tree is unavailable, rather than leaving the user
            // to infer it from a picker that moved on its own.
            if store.sidebarMode == .tree && effectiveSidebarMode == .all {
                Text("Showing matches across all folders.")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.secondaryText))
                    .padding(.horizontal, AinkradSpacing.md)
            }

            SidebarPinnedSection(store: store, theme: theme, selected: $selected,
                                    onSelect: openRow, ops: ops)

            if effectiveSidebarMode == .tree {
                FolderTreeView(store: store, theme: theme, selected: $selected,
                              onSelect: openRow, ops: ops)
            } else {
                NoteListView(store: store, query: $query, selected: $selected, theme: theme,
                            onSelect: openRow, onNew: quickCapture, ops: ops,
                            activeTag: $activeTag, focusRequest: $listFocusRequest)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = store.openError, failure.url == attempted {
            emptyStateChrome { DocumentErrorCard(url: failure.url,
                                                 message: "Lore couldn't open this document.",
                                                 theme: theme) }
        } else if let primary = store.pane.session {
            // One column, or two. Each owns its own header, actions menu and
            // mentions slideover — see `DocumentPaneColumn`.
            //
            // One `GeometryReader` around the pair, with an explicit width on
            // the first column: the divider is a point wide and knows nothing
            // about the space it is dividing, so the proportion has to be
            // resolved where the total width is known.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if let secondary = store.secondaryPane?.session {
                        column(primary, isSecondary: false)
                            .frame(width: max(0, (geometry.size.width - 1) * splitFraction))
                        SplitDivider(fraction: $splitFraction, theme: theme)
                        column(secondary, isSecondary: true)
                            .frame(maxWidth: .infinity)
                    } else {
                        column(primary, isSecondary: false)
                    }
                }
            }
        } else {
            emptyStateChrome { emptyState }
        }
    }

    private func column(_ session: DocumentSession, isSecondary: Bool) -> some View {
        DocumentPaneColumn(
            store: store, session: session, theme: theme, ops: ops,
            isFocused: store.focusIsSecondary == isSecondary,
            isSplit: store.isSplit,
            onFocus: { store.focusPane(secondary: isSecondary) },
            onOutlineChange: { outline = $0 },
            onScrollHandler: { jumpToOffset = $0 },
            // The SAME `activeTag` the sidebar's `TagChipRow`/`NoteListView`
            // already filter on — a tag clicked in the editor does exactly
            // what one clicked in the sidebar does.
            onTagClick: { tag in activeTag = tag },
            mentionsRequest: $mentionsRequest)
    }

    /// The header still renders with no document open: it carries the sidebar
    /// toggle, and hiding that would make a collapsed sidebar unrecoverable
    /// except by a shortcut nobody has been told about.
    @ViewBuilder private func emptyStateChrome<Content: View>(
        @ViewBuilder _ body: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            DocumentHeaderBar(session: nil, store: store, theme: theme,
                              row: nil, ops: ops, showingActions: $showingActions)
            body()
        }
    }

    @ViewBuilder private var emptyState: some View {
            switch Self.emptyState(for: store) {
        case .noVault:
            // Offering "New note" here was the whole bug: with no vault the
            // click could not succeed, and the copy told the user to press
            // ⌘N — advice guaranteed to do nothing. The first-run state has
            // exactly one useful action, so it is the only one offered.
            AinkradEmptyState(
                icon: "folder.badge.questionmark",
                title: "No vault open",
                message: "Lore keeps your notes in a folder on disk. "
                    + "Choose the folder that holds them to get started.",
                actionTitle: "Choose vault…",
                action: ops.beginChooseVault)
        case .noDocument:
            AinkradEmptyState(
                icon: "book.closed",
                title: "No document open",
                message: "Select a document from the list, or press ⌘N to capture a new one.",
                actionTitle: "New note",
                action: quickCapture)
        }
    }

    /// Which empty state the pane is in.
    ///
    /// A `static` on the view, not a computed property, because SwiftUI views
    /// are only smoke-testable in this project — this is the value the branch
    /// above is built from, and `NoVaultTests` asserts it directly.
    enum EmptyState: Equatable { case noVault, noDocument }

    static func emptyState(for store: LoreStore) -> EmptyState {
        store.vaultRoot == nil ? .noVault : .noDocument
    }

    private func openRow(_ row: IndexRow) {
        selected = row
        attempted = row.path
        // ⌥ opens BESIDE what is showing rather than replacing it — "put this
        // next to what I am reading", which is the gesture split view exists
        // for and would otherwise cost splitting first and then opening.
        //
        // Read from `NSEvent` rather than a SwiftUI modifier: the declarative
        // alternative (`modifierKeyAlternate`) is macOS 15 and this targets
        // 14. Read at the moment of the click, so a modifier held after the
        // fact cannot change where an earlier click landed.
        if NSEvent.modifierFlags.contains(.option) {
            store.openInSecondaryPane(url: row.path)
        } else {
            store.open(row)
        }
    }

    /// Create-and-open. The failure path goes through `ops.message` rather than
    /// `try?` — see `SidebarOperations.createDocument`, which is where the
    /// reason for the failure is turned into a sentence.
    private func quickCapture() {
        guard let path = ops.createDocument() else { return }
        attempted = path
        store.open(url: path)
        selected = store.rows.first { $0.path == path }
    }
}

/// Testable core of the list's delete affordance (which moved off the old
/// `NoteEditorPane` when that view was deleted).
///
/// Goes through `store.trash(_:)`, which owns the whole destructive sequence:
/// flushing or REFUSING on a tab with unsaved edits, cancelling the debounced
/// autosave (which would otherwise recreate the file the user just deleted),
/// closing the tab, moving the file to the Trash rather than unlinking it, and
/// dropping it from the index.
///
/// This function used to do the tab handling itself, matching `$0.url ==
/// row.path` — a raw-versus-canonical comparison that silently found nothing
/// for a tab opened with a non-canonical URL, leaving exactly the resurrection
/// defect `trash` was written to close. It has no business owning that logic
/// twice.
///
/// RETURNS the refusal rather than swallowing it, and nil on success.
///
/// This was `try? store.trash(row)`. `trash` REFUSES when an open tab still
/// holds unsaved edits it could not flush — so the user pressed Delete, the file
/// stayed, and nothing said why: a silent no-op indistinguishable from a broken
/// button. `trashFailed` (a volume with no `.Trashes`) was equally invisible.
/// `SidebarOperations.confirmTrash` puts the returned sentence in front of the
/// user, and the sentence for `unsavedEdits` carries the way out.
@MainActor
@discardableResult
func deleteDocument(_ row: IndexRow, in store: LoreStore) -> String? {
    do {
        _ = try store.trash(row)
        return nil
    } catch let error as LoreError {
        return SidebarOperations.describe(error, row: row)
    } catch {
        return "“\(row.path.lastPathComponent)” could not be moved to the Trash: "
            + error.localizedDescription
    }
}
