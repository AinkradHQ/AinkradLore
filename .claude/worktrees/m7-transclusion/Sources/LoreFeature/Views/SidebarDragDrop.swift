import SwiftUI
import UniformTypeIdentifiers
import AinkradAppKit

/// Dragging documents between folders in the sidebar.
///
/// Moving a note used to mean right-click → Move to… → a folder picker → a
/// preview → confirm. That is the correct flow for a rename with link
/// rewrites, and far too much ceremony for the single most common organising
/// gesture in a file-backed note app.
///
/// A drop does NOT bypass any of that safety. It lands on the same
/// `SidebarOperations.move(_:toFolder:)` the menu item calls, which plans the
/// move and shows the same preview of which links will be rewritten. Dragging
/// replaces the two steps that were pure navigation — finding the menu and
/// picking the folder — and nothing else.
extension View {

    /// Makes a document row draggable.
    ///
    /// Carries the file URL rather than a custom payload so the drag is
    /// meaningful outside Lore too (dropping into Finder copies the file). The
    /// drop side does not trust it: `SidebarDrop.row(for:in:)` re-matches the
    /// URL against the known rows, so a URL dragged in from elsewhere is
    /// rejected rather than treated as a document Lore already has.
    func loreDraggableDocument(_ row: IndexRow) -> some View {
        onDrag { NSItemProvider(object: row.path as NSURL) }
    }

    /// Makes a folder row accept dropped documents.
    ///
    /// `isTargeted` drives a visible highlight, and it is gated on the drop
    /// being LEGAL — see `SidebarDrop`, which both this and `move` consult so a
    /// folder cannot light up and then refuse.
    func loreDocumentDropTarget(folder: URL, store: LoreStore,
                                ops: SidebarOperations,
                                theme: HostTheme) -> some View {
        modifier(LoreDocumentDropTarget(folder: folder, store: store, ops: ops, theme: theme))
    }
}

private struct LoreDocumentDropTarget: ViewModifier {
    let folder: URL
    let store: LoreStore
    let ops: SidebarOperations
    let theme: HostTheme
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background {
                if targeted {
                    ChamferShape(cut: LoreMetrics.chamfer)
                        .fill(theme.tokens.accentSecondary.opacity(0.25))
                        .overlay(ChamferShape(cut: LoreMetrics.chamfer)
                            .strokeBorder(theme.tokens.accentSecondary, lineWidth: 1.5))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                handle(providers)
            }
    }

    /// Resolves the dropped URL and routes it into the ordinary move.
    ///
    /// Returns `true` only when a real document was recognised. The return
    /// value is what tells AppKit whether the drag was consumed — returning
    /// `true` for a foreign file would swallow the drag with nothing to show
    /// for it.
    private func handle(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                // Re-checked on the MAIN ACTOR at drop time, not at drag time:
                // the vault can be rebuilt, renamed or closed mid-drag, and a
                // row captured when the drag started may no longer exist.
                guard let row = SidebarDrop.row(for: url, in: store.rows) else {
                    ops.message = "“\(url.lastPathComponent)” isn't a document in this vault, "
                        + "so it wasn't moved."
                    return
                }
                ops.move(row, toFolder: folder)
            }
        }
        return true
    }
}
