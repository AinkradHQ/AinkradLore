import SwiftUI
import AinkradAppKit

struct NoteListView: View {
    @Bindable var store: LoreStore
    @Binding var query: String
    @Binding var selected: IndexRow?
    let theme: HostTheme
    let onSelect: (IndexRow) -> Void
    let onNew: () -> Void
    /// Rename / move / trash, shared with `FolderTreeView`. Owns the
    /// confirmation dialog, the preview sheet and — new in Task 10 — the
    /// VISIBLE refusal when a delete is declined.
    let ops: SidebarOperations
    /// Lifted to `LoreRootView` so it can decide whether an active tag filter
    /// should force the flat list even while the sidebar is in tree mode.
    @Binding var activeTag: String?
    /// Set by the search field's ↓ to hand the keyboard to this list. A
    /// one-shot request, consumed here — the same shape as
    /// `DocumentPane.panelRequest`, and for the same reason: the field cannot
    /// reach into this view's focus state directly.
    @Binding var focusRequest: Bool?
    @Environment(\.ainkradTypography) private var typo

    /// Which row the KEYBOARD is on. Deliberately separate from `selected`,
    /// which is the open document: arrowing through a list must not open every
    /// document it passes over.
    @State private var focusedIndex: Int?
    @FocusState private var listFocused: Bool

    /// Search results with their excerpts, when a query is active.
    ///
    /// Empty while browsing: `snippet()` is only meaningful against a MATCH,
    /// and asking for hits with no query would return the whole vault with a
    /// leading fragment of each document as its "excerpt" — noise dressed up
    /// as relevance.
    private var hits: [SearchHit] {
        guard !query.isEmpty else { return [] }
        return store.searchHits(query)
    }

    private var visible: [IndexRow] {
        // The default-hidden filter applies to BROWSING (`store.rows`) only,
        // never to `store.search(query)`. A search result is something the
        // owner explicitly asked for by typing a query — surfacing it is the
        // whole point of searching, and silently omitting `client_secret_…
        // .json` from a search for "client_secret" because it is an
        // attachment would be far more surprising than showing it. Browsing
        // is where a `.zip` reads as clutter; searching is where it reads as
        // "found it".
        var base = query.isEmpty
            ? DocumentVisibility.visibleRows(store.rows, showAllFiles: store.showAllFiles)
            : store.search(query)
        if let tag = activeTag { base = base.filter { $0.tags.contains(tag) } }
        return base
    }

    /// True when the reason the list looks empty is specifically that every
    /// row got hidden by the default filter — not "no notes exist" and not
    /// "the search/tag found nothing". Fix round 1, Minor 5: without this,
    /// a folder holding only a `.zip` and a `.json` read as "No matches"
    /// with the magnifying-glass icon, which implies a bad search rather
    /// than a setting the owner can flip. Scoped to the plain-browse case
    /// (`query` empty, no tag filter) because that is the only case where
    /// `DocumentVisibility` is even consulted — see `visible` above.
    private var allVisibleRowsAreHiddenByDefault: Bool {
        query.isEmpty && activeTag == nil && !store.showAllFiles
            && !store.rows.isEmpty
            && DocumentVisibility.visibleRows(store.rows, showAllFiles: false).isEmpty
    }

    /// Whether the reason this list has nothing to show is that the vault is
    /// still being read, rather than that it is empty.
    ///
    /// A `static` on the view, not a computed property, for the reason
    /// `LoreRootView.emptyState(for:)` already documents: SwiftUI views are
    /// only smoke-testable in this project, so the decision the branch is
    /// built from is asserted directly.
    ///
    /// Requires a vault: with none open there is nothing to index, and the
    /// `noVault` empty state (owned by `LoreRootView`) is the correct answer.
    static func isStillIndexing(_ store: LoreStore) -> Bool {
        store.vaultRoot != nil && store.isIndexing
    }

    var body: some View {
        // The search field and the "+" button used to live HERE, which meant
        // neither existed in tree mode — this view is not even mounted then.
        // They are now in `LoreRootView`'s sidebar header, above the mode
        // picker, so both are reachable in both modes. Tag chips stay here: they
        // are a flat-list filter by nature (a tag cuts across folders, so
        // filtering the tree by one leaves a scaffold of empty branches), and
        // `LoreRootView` already forces the flat list whenever a tag is active.
        VStack(spacing: AinkradSpacing.sm) {
            if !store.allTags.isEmpty {
                // Wrapping, not horizontally scrolling — see `TagChipRow`. The
                // separate "Clear" chip went with the scroll: an active tag is
                // now always visible, so clearing it means clicking it again.
                TagChipRow(tags: store.allTags, counts: store.tagCounts,
                           activeTag: $activeTag, theme: theme)
                    .padding(.vertical, 2)
            }

            if visible.isEmpty && NoteListView.isStillIndexing(store) {
                // An empty sidebar during the first scan of a large vault is
                // indistinguishable from an empty vault — and the copy the
                // empty case shows ("No notes yet · Press ⌘N") is actively
                // wrong advice while the rows are still arriving. Gated on
                // `visible.isEmpty` so a rescan of a vault that already has
                // rows never blanks the list the user is reading.
                VStack(spacing: AinkradSpacing.sm) {
                    AinkradSpinner(size: 20)
                    Text("Indexing vault…")
                        .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Indexing vault")
            } else if visible.isEmpty {
                AinkradEmptyState(
                    icon: store.rows.isEmpty ? "tray"
                        : allVisibleRowsAreHiddenByDefault ? "eye.slash" : "magnifyingglass",
                    title: store.rows.isEmpty ? "No notes yet"
                        : allVisibleRowsAreHiddenByDefault ? "Files are hidden" : "No matches",
                    message: store.rows.isEmpty
                        ? "Press ⌘N to capture your first note."
                        : allVisibleRowsAreHiddenByDefault
                            ? "Every file here is hidden by \"Show all files\" in Settings."
                            : "Try a different search or tag filter.",
                    actionTitle: store.rows.isEmpty ? "New note"
                        : allVisibleRowsAreHiddenByDefault ? "Show all files" : nil,
                    action: store.rows.isEmpty ? onNew
                        : allVisibleRowsAreHiddenByDefault ? { store.setShowAllFiles(true) } : nil)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // The result COUNT. Without it, "did my search
                            // find three things or thirty" needs scrolling to
                            // answer — and a count is also the only signal
                            // that a query narrowed anything at all.
                            if !query.isEmpty {
                                Text(visible.count == 1 ? "1 result"
                                                        : "\(visible.count) results")
                                    .font(AinkradFontResolver.font(.caption, typography: typo))
                                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.secondaryText))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 2)
                                    .accessibilityLabel(
                                        "\(visible.count) results for \(query)")
                            }
                            ForEach(Array(visible.enumerated()), id: \.element.path) { index, row in
                                LoreSidebarRow.document(
                                    row: row, depth: 0,
                                    isSelected: selected?.path == row.path,
                                    subtitle: subtitle(for: row),
                                    attributedSubtitle: snippet(for: row),
                                    emptyTitleFallback: "Untitled",
                                    onTap: { selected = row; onSelect(row) })
                                    .loreDraggableDocument(row)
                                    // A focus ring DISTINCT from selection.
                                    // They mean different things — "the
                                    // keyboard is here" versus "this is the
                                    // open document" — and drawing them the
                                    // same way makes ↓ look like it is opening
                                    // documents it has not opened.
                                    .overlay {
                                        if focusedIndex == index {
                                            ChamferShape(cut: LoreMetrics.chamfer)
                                                .strokeBorder(theme.tokens.accentPrimary,
                                                              lineWidth: 1.5)
                                        }
                                    }
                                    .id(row.path)
                                    .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops, store: store))
                            }
                        }
                    }
                    // Keeps a keyboard-moved focus on screen. Without this ↓
                    // walks the focus ring straight out of the viewport and
                    // the list appears to stop responding.
                    .onChange(of: focusedIndex) { _, index in
                        guard let index, visible.indices.contains(index) else { return }
                        proxy.scrollTo(visible[index].path, anchor: .bottom)
                    }
                }
            }
        }
        .padding(AinkradSpacing.md)
        // The list itself is focusable, so ↑/↓ reach it once the user has
        // arrowed down out of the search field.
        .focusable()
        .focused($listFocused)
        .onMoveCommand { direction in
            switch direction {
            case .down: moveFocus(.down)
            case .up: moveFocus(.up)
            default: break
            }
        }
        // Return opens the focused row. `onMoveCommand`/`onKeyPress` are the
        // only route: a `keyboardShortcut(.defaultAction)` claim here would be
        // dispatched globally and steal Return from every text field on the
        // surface.
        .onKeyPress(.return) {
            guard let index = focusedIndex, visible.indices.contains(index) else {
                return .ignored
            }
            let row = visible[index]
            selected = row
            onSelect(row)
            return .handled
        }
        // The focused row must survive a re-rank: after typing another letter
        // the list is a different list, and an index held across that change
        // points at a different document — the one thing keyboard navigation
        // must never do is open something other than what is highlighted.
        .onChange(of: visible.map(\.path)) { _, paths in
            focusedIndex = LoreListNavigation.reconciled(previous: focusedPath, ids: paths)
        }
        .onChange(of: focusRequest) { _, requested in
            guard requested != nil else { return }
            focusRequest = nil
            listFocused = true
            focusedIndex = LoreListNavigation.move(.down, from: nil, count: visible.count)
        }
    }

    /// The tag line, shown while BROWSING. Replaced by the matched excerpt
    /// once a query is active: with both, a result row would carry two
    /// subtitles and the more useful one would be second.
    private func subtitle(for row: IndexRow) -> String? {
        guard query.isEmpty, !row.tags.isEmpty else { return nil }
        return row.tags.map { "#\($0)" }.joined(separator: " ")
    }

    /// The matched excerpt for a row, with the matches emphasised.
    ///
    /// Nil for a title-only match — the title is already the row's headline,
    /// so repeating it underneath says nothing.
    private func snippet(for row: IndexRow) -> AttributedString? {
        guard let snippet = hits.first(where: { $0.row.path == row.path })?.snippet
        else { return nil }
        return snippet.attributed { run in
            run.inlinePresentationIntent = .stronglyEmphasized
            run.foregroundColor = theme.tokens.accentPrimary
        }
    }

    /// The path of the focused row, held so a re-ranked list can be reconciled
    /// by IDENTITY rather than by position.
    private var focusedPath: URL? {
        guard let focusedIndex, visible.indices.contains(focusedIndex) else { return nil }
        return visible[focusedIndex].path
    }

    private func moveFocus(_ direction: LoreListNavigation.Direction) {
        focusedIndex = LoreListNavigation.move(direction, from: focusedIndex,
                                               count: visible.count)
    }
}
