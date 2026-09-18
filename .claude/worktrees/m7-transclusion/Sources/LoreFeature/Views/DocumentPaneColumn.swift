import SwiftUI
import AinkradAppKit

/// One column of the editor: a document's header and its pane.
///
/// Extracted so `LoreRootView` does not have to grow a second copy of every
/// piece of per-document state when the view splits. Each column owns its own
/// actions menu and mentions slideover, which is what makes two of them
/// independent rather than two views sharing one set of flags — the failure
/// that would show as opening the right pane's menu from the left pane's
/// button.
struct DocumentPaneColumn: View {
    @Bindable var store: LoreStore
    let session: DocumentSession
    let theme: HostTheme
    let ops: SidebarOperations
    /// Whether this column has keyboard focus. Always true when unsplit —
    /// there is nothing to distinguish it from.
    let isFocused: Bool
    /// Whether a second column exists at all. Focus is only worth SHOWING when
    /// there is another pane it could have been.
    let isSplit: Bool
    let onFocus: () -> Void
    let onOutlineChange: ([OutlineEntry]) -> Void
    let onScrollHandler: (((Int) -> Void)?) -> Void
    /// A `#tag` clicked in the FOCUSED column's editor. See `DocumentPane
    /// .onTagClick`.
    let onTagClick: @MainActor (String) -> Void

    /// A request from ⇧⌘B, shared by both columns and consumed only by the
    /// FOCUSED one. Column-local state would leave the command with nothing to
    /// reach — the shortcut would set a flag no column observed, which is
    /// exactly the defect `PaneWiringTests` exists to catch.
    @Binding var mentionsRequest: Bool
    @State private var showingActions = false

    var body: some View {
        VStack(spacing: 0) {
            DocumentHeaderBar(session: session, store: store, theme: theme,
                              row: headerRow, ops: ops,
                              showingActions: $showingActions)
            DocumentPane(store: store, session: session, theme: theme, ops: ops,
                         onOutlineChange: { if isFocused { onOutlineChange($0) } },
                         onScrollHandler: { if isFocused { onScrollHandler($0) } },
                         // NOT gated on `isFocused` — a tag click is a direct
                         // action in WHICHEVER column it landed in, not a
                         // "what does the active pane show" question the way
                         // the outline/scroll channels are.
                         onTagClick: onTagClick,
                         mentionsRequest: isFocused ? $mentionsRequest : .constant(false),
                         showingActions: $showingActions,
                         actionItems: actionItems)
                // Identity is the session's stable id — NOT its url, which
                // changes when the session adopts a "save a copy" resolution.
                .id(session.id)
        }
        // Focus follows a click anywhere in the column, including into the
        // text. `simultaneousGesture` rather than `onTapGesture`: the latter
        // would consume the click, so focusing a pane would cost a second
        // click to then place the caret.
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .overlay(alignment: .top) { focusIndicator }
    }

    /// Which column the keyboard is in.
    ///
    /// TWO channels, not just colour: an accent rule along the focused
    /// column's top edge, and the unfocused column's content dimmed. Two
    /// editors that look identical, where keystrokes go to one of them, is a
    /// UI that feels broken every time it guesses wrong — and a tint alone
    /// would leave that unreadable for anyone who cannot distinguish it.
    @ViewBuilder private var focusIndicator: some View {
        if isSplit {
            Rectangle()
                .fill(isFocused ? theme.tokens.accentPrimary : .clear)
                .frame(height: 2)
                .accessibilityHidden(true)
        }
    }

    /// This document's index row, matched CANONICALLY — a session opened via
    /// `open(url:)` keeps the caller's spelling, so a raw `==` silently finds
    /// nothing for a document opened with a non-canonical URL.
    private var headerRow: IndexRow? {
        let path = VaultIndexCoordinator.canonical(session.url)
        return store.rows.first { VaultIndexCoordinator.canonical($0.path) == path }
    }

    /// The ⋯ menu's items — the SAME `loreRowMenuItems` the sidebar's
    /// right-click menu uses, so the two cannot drift into offering different
    /// destructive affordances.
    private var actionItems: [AinkradMenuItem] {
        guard let row = headerRow else { return [] }
        // "Linked mentions" leads: the one item that INSPECTS the document
        // rather than changing it.
        return [AinkradMenuItem(title: "Linked mentions", systemName: "link",
                                shortcut: "\u{21E7}\u{2318}B",
                                action: { mentionsRequest = true })]
            + loreRowMenuItems(row: row, ops: ops, store: store)
    }
}
