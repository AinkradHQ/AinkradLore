import SwiftUI
import AinkradAppKit

/// Lore's **basic** mode: one document, rendered and editable.
///
/// Ahmed's case for it: *"sometimes I need to open a specific note or .md file
/// and opening Lore loads all of its features."* This is the mode a `.md`
/// clicked in Hoard or Rune lands in.
///
/// Not built here: both sidebars, the note list, the tag row, the search field,
/// the command palette, the import coordinator, the outline panel, the
/// linked-mentions slideover and the split view — roughly fourteen pieces of
/// `@State` in `LoreRootView`, none of which a single document needs.
///
/// **What this does NOT fix, stated plainly:** `LoreStore` opens the vault's
/// SQLite index when it is constructed, before any view exists — and on this
/// machine that index is 5.9 GB across 464k rows, 87.6% of it `node_modules`
/// and build output (see `Docs/Audits/2026-09-18-app-cold-open.md`). Basic mode
/// cannot avoid that cost, because the store is handed to it already built. The
/// indexing is being replaced in the next milestone, so this is deliberately
/// not worked around here.
struct LoreBasicView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme

    @Environment(\.ainkradSetPaneMode) private var setPaneMode
    @State private var ops: SidebarOperations
    @State private var showingActions = false

    init(store: LoreStore, theme: HostTheme) {
        self.store = store
        self.theme = theme
        _ops = State(initialValue: SidebarOperations(store: store))
    }

    var body: some View {
        AinkradBasicShell(icon: "doc.text",
                          title: title,
                          subtitle: subtitle) {
            content
        }
    }

    private var title: String {
        store.selectedTab?.url.lastPathComponent ?? "Lore"
    }

    /// The containing folder, which is what makes two notes of the same name
    /// tell apart — the one thing the filename alone cannot say.
    private var subtitle: String? {
        guard let url = store.selectedTab?.url else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }

    @ViewBuilder private var content: some View {
        if let session = store.selectedTab {
            DocumentPane(store: store, session: session, theme: theme, ops: ops,
                         // Basic has no outline panel, no ⌘⇧O palette and no
                         // tag row, so these three channels have nowhere to
                         // publish to. They are dropped rather than wired to
                         // hidden state that nothing would ever read.
                         onOutlineChange: { _ in },
                         onScrollHandler: { _ in },
                         onTagClick: { _ in setPaneMode(.advanced) },
                         mentionsRequest: .constant(false),
                         showingActions: $showingActions,
                         actionItems: [])
        } else {
            AinkradEmptyState(
                icon: "doc.text",
                title: "No document open",
                message: "Open one from a file, or switch to advanced to browse the vault.",
                actionTitle: "Show everything",
                action: { setPaneMode(.advanced) })
        }
    }
}
