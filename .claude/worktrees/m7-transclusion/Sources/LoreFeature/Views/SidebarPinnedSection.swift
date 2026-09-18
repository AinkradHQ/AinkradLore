import SwiftUI
import AinkradAppKit

/// Pinned documents, above the browse list.
///
/// A "Recent" section shipped here alongside Pinned and was removed: the
/// sidebar already shows the vault, the history chevrons already answer "back
/// to what I was just on", and ⌘P reaches anything by name — so a recents list
/// was a fourth route to documents that were never more than one of the other
/// three away, costing permanent vertical space at the top of the sidebar.
/// Pinning is different: it is a choice the user made, and nothing else
/// records it.
///
/// Deliberately ABOVE the mode picker and shared by both sidebar modes: these
/// are not a third way of browsing the vault, they are a shortcut past
/// browsing entirely, and they answer the same question whether the list below
/// is a tree or a flat list.
///
/// Shared by both sidebar modes — pinning is a shortcut PAST browsing, not a
/// third way of doing it — and hidden entirely when nothing is pinned, which
/// is every first-run vault.
struct SidebarPinnedSection: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Binding var selected: IndexRow?
    let onSelect: (IndexRow) -> Void
    let ops: SidebarOperations

    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        let pinned = store.pinnedRows
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header("Pinned")
                ForEach(pinned, id: \.path) { row in shortcutRow(row) }
                Divider().opacity(0.4).padding(.vertical, AinkradSpacing.xs)
            }
            .padding(.horizontal, AinkradSpacing.md)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.tertiaryText))
            .padding(.top, AinkradSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    /// A shortcut row is the SAME row component the browse lists use, so a
    /// document does not change shape depending on which part of the sidebar
    /// it appears in — and so selection, hover and the context menu behave
    /// identically in both.
    private func shortcutRow(_ row: IndexRow) -> some View {
        LoreSidebarRow.document(
            row: row, depth: 0,
            isSelected: selected?.path == row.path,
            emptyTitleFallback: "Untitled",
            onTap: { selected = row; onSelect(row) })
            .loreDraggableDocument(row)
            .ainkradContextMenu(loreRowMenuItems(row: row, ops: ops, store: store))
    }
}
