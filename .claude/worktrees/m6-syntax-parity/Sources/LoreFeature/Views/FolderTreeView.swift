import SwiftUI
import AinkradAppKit

/// A folder and everything directly inside it. Pure value built from index
/// rows, so the grouping logic is testable without a view host.
struct FolderNode: Identifiable {
    let id: String
    let name: String
    let children: [FolderNode]
    let documents: [IndexRow]

    /// `directories` is every vault-relative directory path, supplied by the
    /// caller rather than walked here — see
    /// `VaultIndexCoordinator.directoryPaths`'s doc comment. This function
    /// used to walk the filesystem itself on every call, which
    /// `FolderTreeView.body` ran on every SwiftUI redraw (including one
    /// triggered by expanding a folder): 707 ms per call over a ~17,000-object
    /// tree, synchronously on the main actor. `directories` being CACHED by
    /// the caller — not this function doing its own I/O — is what fixes that;
    /// this function itself stays pure and testable with plain arrays.
    static func tree(from rows: [IndexRow], directories: [String], root: URL) -> FolderNode {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var byFolder: [String: [IndexRow]] = [:]
        for row in rows {
            let parts = row.path.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            let folder = parts.dropLast().joined(separator: "/")
            byFolder[folder, default: []].append(row)
        }
        // A folder with nothing inside it (freshly created, or emptied by
        // trashing its last child) produces zero index rows, and zero rows
        // means zero keys in `byFolder` above — the folder simply never
        // becomes a node, `createFolder`'s own success message notwithstanding.
        // `directories` supplies exactly the keys a row-only `byFolder` is
        // missing; every EXISTING key already comes from a row's real path,
        // so this only ever ADDS keys for folders that would otherwise be
        // invisible — it never changes how a non-empty folder is grouped.
        for directory in directories where byFolder[directory] == nil {
            byFolder[directory] = []
        }
        return node(named: "", path: "", byFolder: byFolder)
    }

    private static func node(named name: String, path: String,
                             byFolder: [String: [IndexRow]]) -> FolderNode {
        let childNames = Set(byFolder.keys.compactMap { key -> String? in
            guard key != path else { return nil }
            let prefix = path.isEmpty ? "" : path + "/"
            guard key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
        }).sorted()

        return FolderNode(
            id: path.isEmpty ? "/" : path,
            name: name,
            children: childNames.map {
                node(named: $0, path: path.isEmpty ? $0 : path + "/" + $0, byFolder: byFolder)
            },
            documents: (byFolder[path] ?? []).sorted { $0.title < $1.title })
    }
}

/// Applies a drop target only where there is a real folder to drop into.
///
/// The synthetic root node has no URL (see `folderURL`), and `ViewModifier`
/// has no "do nothing" form that keeps the same view type — hence a modifier
/// that branches internally rather than an `if` at each use site.
private struct OptionalDropTarget: ViewModifier {
    let folder: URL?
    let store: LoreStore
    let ops: SidebarOperations
    let theme: HostTheme

    func body(content: Content) -> some View {
        if let folder {
            content.loreDocumentDropTarget(folder: folder, store: store,
                                           ops: ops, theme: theme)
        } else {
            content
        }
    }
}

/// Folder tree rendering of `store.rows`, an alternative to `NoteListView`'s
/// flat list. Expansion state and the choice between the two views persist
/// via `LoreStore`; see `LoreStore.sidebarMode` / `setExpandedFolders`.
///
/// Rename / move / trash arrive through `ops`, whose menu builders
/// (`loreRowMenuItems`, `loreFolderMenuItems`) are shared with `NoteListView`
/// so a destructive affordance is not defined twice.
struct FolderTreeView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Binding var selected: IndexRow?
    let onSelect: (IndexRow) -> Void
    let ops: SidebarOperations
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let root = store.vaultRoot {
                    // Filtered to the browse-list rows only — `directories`
                    // is passed UNFILTERED below, so a folder holding
                    // nothing but hidden attachments still gets a node (see
                    // `FolderNode.tree`'s own doc comment on why zero rows
                    // does not mean zero folder). Hiding the folder itself
                    // would be a second, silent disappearance on top of the
                    // files' — a folder the owner remembers creating,
                    // vanishing with no explanation, is worse than an empty
                    // folder they can right-click and inspect.
                    outline(FolderNode.tree(
                        from: DocumentVisibility.visibleRows(store.rows,
                                                             showAllFiles: store.showAllFiles),
                        directories: store.directoryPaths,
                        root: root), depth: 0)
                }
                // A filler BELOW every row, not an overlay across the whole
                // ScrollView: `.ainkradContextMenu`'s catcher only lets a
                // right-click through where it is hit-testable, but it still
                // sits ON TOP of whatever it decorates, so putting it on the
                // ScrollView itself would shadow every row's OWN catcher
                // underneath and swallow the row menus this task must
                // preserve. Placed here, after the tree, it only ever
                // occupies the empty space below the last row — exactly the
                // spot with no row to host `loreFolderMenuItems` at all,
                // which is the whole reason a vault with no subfolder yet (or
                // every folder collapsed) had no reachable New Folder.
                if let root = store.vaultRoot {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .contentShape(Rectangle())
                        .ainkradContextMenu(loreRootMenuItems(root: root, ops: ops))
                        // The empty space below the tree IS the vault root as a
                        // drop target — otherwise moving a note back out to the
                        // root would have no gesture at all, since the root has
                        // no row of its own to drop onto.
                        .loreDocumentDropTarget(folder: root, store: store,
                                                ops: ops, theme: theme)
                }
            }
        }
        .onAppear { expanded = store.expandedFolders }
    }

    private func outline(_ node: FolderNode, depth: Int) -> AnyView {
        AnyView(outlineBody(node, depth: depth))
    }

    @ViewBuilder
    private func outlineBody(_ node: FolderNode, depth: Int) -> some View {
        if depth > 0 {
            LoreSidebarRow.folder(
                name: node.name, depth: depth - 1,
                isExpanded: expanded.contains(node.id),
                onToggle: {
                    if expanded.contains(node.id) { expanded.remove(node.id) }
                    else { expanded.insert(node.id) }
                    store.setExpandedFolders(expanded)
                })
                // Only a real folder gets a folder menu. `node.id` is a
                // vault-RELATIVE path, so it is resolved against the live vault
                // root rather than assumed absolute; with no vault there is no
                // folder to rename and the menu is simply absent.
                .ainkradContextMenu(folderURL(node).map {
                    loreFolderMenuItems(folder: $0, ops: ops)
                } ?? [])
                // Dropping a note on a folder moves it there — through the
                // SAME `ops.move` the context menu uses, so the link-rewrite
                // preview still appears. See `SidebarDragDrop`.
                .modifier(OptionalDropTarget(folder: folderURL(node), store: store,
                                             ops: ops, theme: theme))
        }
        if depth == 0 || expanded.contains(node.id) {
            ForEach(node.documents, id: \.path) { row in
                LoreSidebarRow.document(
                    row: row, depth: depth,
                    isSelected: selected?.path == row.path,
                    onTap: { selected = row; onSelect(row) })
                    .loreDraggableDocument(row)
                    .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops, store: store))
            }
            ForEach(node.children) { child in outline(child, depth: depth + 1) }
        }
    }

    /// The absolute URL of a tree node, or nil for the synthetic root node (its
    /// id is `"/"` and it IS the vault — renaming it is not a folder rename,
    /// and `loreFolderMenuItems`'s Rename/Move-to-Trash have no sense for it).
    /// This function is only ever called from `outlineBody`'s `depth > 0`
    /// branch, where `node.id` can never be `"/"`, so the nil case never
    /// actually fires here — the guard stays because a future caller passing
    /// the root node is exactly the kind of mistake it exists to catch. The
    /// root's OWN "New Folder" route is `loreRootMenuItems`, reached through
    /// the empty-space filler below the tree and the sidebar header button,
    /// not through this per-row menu.
    private func folderURL(_ node: FolderNode) -> URL? {
        guard let root = store.vaultRoot, node.id != "/" else { return nil }
        return root.appendingPathComponent(node.id)
    }
}
