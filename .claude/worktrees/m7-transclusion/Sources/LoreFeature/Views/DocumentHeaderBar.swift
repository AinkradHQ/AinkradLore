import SwiftUI
import AppKit
import AinkradAppKit

/// The one chrome row: where you are, how to get back, and what you can do to
/// the open document.
///
/// ## Why the document needed a head
///
/// Until this existed, the ONLY place the open document was named was its tab,
/// and the only thing said about it was a 6pt dirty dot. Nothing on screen
/// answered "which folder is this in?" — a real question in a vault where
/// `Notes.md` can exist in six places — and the document's own actions
/// (rename, move, reveal, delete) were reachable only by finding the file
/// again in the sidebar and right-clicking it.
///
/// ## Why it renders with no document
///
/// It hosts the sidebar toggle and the history chevrons, which must stay
/// reachable in the empty state — otherwise collapsing the sidebar with no
/// document open would hide the only control that brings it back, leaving a
/// blank window whose sole recovery is a shortcut nobody has been told about.
/// With no session the row degrades to those controls alone.
///
/// The document menu is built from `loreRowMenuItems`, the SAME builder the
/// sidebar's context menu uses: a destructive affordance defined twice is a
/// destructive affordance reviewed once.
struct DocumentHeaderBar: View {
    /// Nil in the empty state — see the type's doc comment.
    let session: DocumentSession?
    @Bindable var store: LoreStore
    let theme: HostTheme
    /// The row this document corresponds to, when the index knows it. Nil for
    /// a document open from outside the vault, which has no index row and
    /// therefore no rename/move/trash — the menu is absent rather than dead.
    let row: IndexRow?
    let ops: SidebarOperations
    /// Whether the pane's actions menu is up. Owned by `DocumentPane`, which
    /// renders it — see `DocumentActionsMenu`.
    @Binding var showingActions: Bool

    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    /// Ticks only while a "Saved" label is young enough for its wording to
    /// still change. See `RelativeClock`.
    @State private var now = Date()

    private var saveState: DocumentSaveState? {
        guard let session else { return nil }
        return DocumentSaveState.of(readOnly: session.isReadOnly,
                                    hasSaveError: session.lastSaveError != nil,
                                    isDirty: session.isDirty,
                                    lastSavedAt: session.lastSavedAt)
    }

    var body: some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconButton(
                systemName: store.sidebarCollapsed ? "sidebar.left" : "sidebar.leading",
                tooltip: store.sidebarCollapsed ? "Show sidebar" : "Hide sidebar") {
                    withAnimation(reduceMotion ? nil : AinkradMotion.hover) {
                        store.setSidebarCollapsed(!store.sidebarCollapsed)
                    }
                }
                .accessibilityLabel(store.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            history

            if session != nil { breadcrumb }
            Spacer(minLength: AinkradSpacing.sm)
            saveLabel
            if let row {
                // Toggles a binding the PANE owns: the menu is rendered as
                // an overlay in the pane, not here. A menu hung off this bar
                // would be clipped by it, and hosting it in a separate panel
                // window is what the previous two attempts got wrong.
                AinkradIconButton(systemName: "ellipsis", tooltip: "Document actions") {
                    showingActions.toggle()
                }
                .accessibilityLabel("Document actions")
            }
        }
        .padding(.horizontal, LoreMetrics.gutter)
        .padding(.vertical, AinkradSpacing.xs)
        .background(theme.tokens.surface)
        .task(id: session?.id) { await RelativeClock.tick { now = $0 } }
    }

    /// Back and forward.
    ///
    /// DISABLED rather than hidden when there is nowhere to go: a control that
    /// appears and disappears as you navigate makes the row jitter and moves
    /// everything after it sideways, which is worse than a dimmed chevron.
    @ViewBuilder private var history: some View {
        HStack(spacing: 2) {
            AinkradIconButton(systemName: "chevron.left", tooltip: "Back") {
                store.goBack()
            }
            .disabled(!store.canGoBack)
            .opacity(store.canGoBack ? 1 : 0.35)
            .accessibilityLabel("Back")

            AinkradIconButton(systemName: "chevron.right", tooltip: "Forward") {
                store.goForward()
            }
            .disabled(!store.canGoForward)
            .opacity(store.canGoForward ? 1 : 0.35)
            .accessibilityLabel("Forward")
        }
    }

    /// `Vault ▸ Folder ▸ Name`, truncating from the HEAD.
    ///
    /// Head truncation, not tail: when a path is too long the segment the user
    /// needs is the one nearest the file, so the vault name disappears first.
    @ViewBuilder private var breadcrumb: some View {
        if let session {
            Text(Self.breadcrumb(for: session.url, root: store.vaultRoot))
                .font(AinkradFontResolver.font(.body, typography: typo))
                .foregroundStyle(theme.tokens.foreground.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel("Document \(session.url.lastPathComponent)")
        }
    }

    @ViewBuilder private var saveLabel: some View {
        if let saveState, let session {
            let label = saveState.label(now: now)
            if !label.isEmpty {
                HStack(spacing: AinkradSpacing.xs) {
                    if session.isReadOnly {
                        AinkradIconGlyph(systemName: "lock", size: 10)
                    }
                    Text(label)
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                }
                // Only a FAILED save earns the danger colour. An ordinary
                // "Saved" in an attention-grabbing tint would train the user to
                // ignore the one reading that matters.
                .foregroundStyle(saveState.isAlarming
                                 ? theme.tokens.accentPrimary
                                 : theme.tokens.foreground.opacity(LoreMetrics.secondaryText))
                .accessibilityLabel(label)
            }
        }
    }

    /// The breadcrumb string. Pure and `static` so it is asserted directly.
    ///
    /// Returns the bare filename when the document is outside the vault (or
    /// there is no vault): a relative path that is not actually relative to
    /// anything would be a fiction, and an absolute one would not fit.
    static func breadcrumb(for url: URL, root: URL?) -> String {
        let name = url.lastPathComponent
        guard let root else { return name }
        let canonicalRoot = VaultIndexCoordinator.canonical(root)
        let canonical = VaultIndexCoordinator.canonical(url)
        let rootParts = canonicalRoot.pathComponents
        let parts = canonical.pathComponents
        guard parts.count > rootParts.count,
              Array(parts.prefix(rootParts.count)) == rootParts else { return name }
        // The vault's own folder name leads, so the crumb reads as a place
        // rather than as a bare path fragment.
        return ([canonicalRoot.lastPathComponent] + parts.dropFirst(rootParts.count))
            .joined(separator: " ▸ ")
    }
}

/// Drives the header's relative "Saved" wording without a permanent timer.
///
/// Wakes once after five seconds and once after a minute, then STOPS. A
/// repeating ticker would redraw the header forever for a label that stops
/// changing after a minute — exactly the class of cost
/// `OutlineRefreshDebouncer` was written to remove.
enum RelativeClock {
    static func tick(_ update: @escaping @MainActor (Date) -> Void) async {
        for delay in [UInt64(5), UInt64(55)] {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { update(Date()) }
        }
    }
}
