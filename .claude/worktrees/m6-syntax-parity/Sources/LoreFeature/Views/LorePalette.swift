import SwiftUI
import AinkradAppKit

/// One row in the palette, whichever mode it is in.
///
/// A single item type rather than a generic over three, because
/// `AinkradCommandMenu` is generic over ONE `Hashable` and the three modes
/// otherwise differ only in where the rows come from. `id` carries the mode
/// so a command and a document that happen to share a title are still
/// distinct rows.
struct LorePaletteItem: Hashable, Identifiable {
    enum Payload: Hashable {
        case command(LoreCommand.ID)
        case document(URL)
        /// A heading's body-relative UTF-16 offset.
        case heading(Int)
    }

    let id: String
    let title: String
    let systemName: String
    /// The right-hand keycap or hint — a shortcut for commands, a folder for
    /// documents, a heading level for headings.
    let detail: String?
    let payload: Payload
}

/// ⌘K / ⌘P / ⌘⇧O.
///
/// ## Why a palette instead of more shortcuts
///
/// Lore's commands outnumber the keys worth memorising, and a plugin has no
/// menu bar of its own — so without this, every command that did not earn a
/// shortcut was unreachable except by knowing where its button lived, and
/// every command that DID earn one was undiscoverable until someone read the
/// source. The palette is the surface where the whole registry is visible,
/// each row wearing the shortcut it can also be reached by, which is how a
/// user learns the shortcuts without being taught them.
///
/// Quick-open (⌘P) is here rather than in the sidebar for the reason the
/// review found: sidebar search is a LIST FILTER, so finding a note means
/// aiming at a narrow column and, in tree mode, expanding folders to reach a
/// file whose name you already know. Typing its name is faster and does not
/// degrade as the vault grows.
struct LorePalette: View {
    let mode: LorePaletteMode
    let store: LoreStore
    let runner: LoreCommandRunner
    let theme: HostTheme
    /// Headings of the open document, supplied by `DocumentPane`'s cache
    /// rather than re-parsed here — `MarkdownEngine.outline` is a full AST
    /// parse and this view rebuilds on every keystroke.
    let outline: [OutlineEntry]
    let onDismiss: () -> Void
    /// Jumps the editor to a body-relative UTF-16 offset.
    let onJumpToOffset: (Int) -> Void

    @State private var query = ""
    @State private var highlight: Int?
    @State private var selection: LorePaletteItem?
    @FocusState private var fieldFocused: Bool
    @Environment(\.ainkradTypography) private var typo

    private var items: [LorePaletteItem] {
        Self.items(mode: mode, query: query, context: runner.context,
                   rows: store.rows, vaultRoot: store.vaultRoot, outline: outline)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // A click-off scrim. Dims the work behind without hiding it, and
            // gives the palette an unambiguous way out for anyone who reached
            // it by accident and does not know Esc closes it.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            panel
                .padding(.top, 96)
        }
        // `.onExitCommand`, NOT a `.keyboardShortcut(.cancelAction)` button.
        //
        // Esc is contended: `DocumentPane` claims it while a side panel is
        // open, and `MarkdownEditor` handles `cancelOperation` to dismiss the
        // `[[`-completion popup. A `keyboardShortcut` claim is dispatched at
        // `performKeyEquivalent` time and would race those two, with SwiftUI
        // free to pick either. `onExitCommand` travels the RESPONDER chain
        // instead, so the palette — which holds focus while it is up — gets it
        // first, and neither of the other two has to know this view exists.
        .onExitCommand(perform: onDismiss)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSearchField(text: $query, placeholder: placeholder)
                .focused($fieldFocused)
                // Return activates the highlighted row. Without this the field
                // swallows Return and the palette can only be driven by mouse
                // — which would defeat the point of a keyboard surface.
                .onSubmit(activateHighlighted)

            AinkradCommandMenu(
                items: items,
                selection: Binding(get: { selection },
                                   set: { if let item = $0 { activate(item) } }),
                icon: { $0.systemName },
                label: { $0.title },
                detail: { $0.detail },
                uppercased: false,
                emptyState: { AnyView(emptyState) },
                highlight: $highlight,
                // The MENU owns ↑/↓, not the field: the field has focus (so
                // typing goes there), and arrow keys must still move the
                // highlight rather than the text caret.
                handlesKeyPresses: true)
        }
        .padding(AinkradSpacing.md)
        .frame(width: 520)
        .frame(maxHeight: 420)
        .background(theme.tokens.surfaceElevated)
        .clipShape(ChamferShape(cut: LoreMetrics.chamfer))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .onAppear { fieldFocused = true; highlight = 0 }
        // Retyping re-ranks the list, so a highlight left at index 7 would
        // point at a row that no longer exists — or worse, a different one.
        .onChange(of: query) { _, _ in highlight = items.isEmpty ? nil : 0 }
        .environment(\.ainkradTheme, theme.tokens)
    }

    private var placeholder: String {
        switch mode {
        case .commands: return "Run a command…"
        case .documents: return "Open a note…"
        case .headings: return "Jump to a heading…"
        }
    }

    @ViewBuilder private var emptyState: some View {
        AinkradEmptyState(
            icon: "magnifyingglass",
            title: "No matches",
            message: mode == .headings
                ? "This document has no headings to jump to."
                : "Nothing here matches “\(query)”.")
    }

    private func activateHighlighted() {
        guard let index = highlight, items.indices.contains(index) else { return }
        activate(items[index])
    }

    private func activate(_ item: LorePaletteItem) {
        switch item.payload {
        case .command(let id):
            // `run` dismisses the palette itself — it has to, because some
            // commands open a sheet of their own and a palette left on top of
            // it would swallow the sheet's keys.
            runner.run(id)
        case .document(let url):
            onDismiss()
            store.open(url: url)
        case .heading(let offset):
            onDismiss()
            onJumpToOffset(offset)
        }
    }

    /// The rows for a mode and query. Pure and `static`, so the ranking is
    /// asserted directly — this project's standing rule for anything a view
    /// decides.
    static func items(mode: LorePaletteMode, query: String,
                      context: LoreCommands.Context, rows: [IndexRow],
                      vaultRoot: URL?, outline: [OutlineEntry]) -> [LorePaletteItem] {
        switch mode {
        case .commands:
            return LoreCommands.matching(query, in: context).map { command in
                LorePaletteItem(id: "command:\(command.id.rawValue)",
                                title: command.title,
                                systemName: command.systemName,
                                detail: command.shortcut?.display,
                                payload: .command(command.id))
            }
        case .documents:
            return rankedDocuments(query, rows: rows, vaultRoot: vaultRoot)
        case .headings:
            let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
            return outline
                .filter { trimmed.isEmpty || $0.text.lowercased().contains(trimmed) }
                .map { entry in
                    LorePaletteItem(id: "heading:\(entry.utf16Offset)",
                                    title: entry.text,
                                    systemName: "number",
                                    detail: "H\(entry.level)",
                                    payload: .heading(entry.utf16Offset))
                }
        }
    }

    /// Documents matching `query`, best first.
    ///
    /// Ranked by WHERE the match lands, not by index order: a prefix match
    /// beats a word-start match beats a mid-string one. Without this, typing
    /// "q1" in a vault with `Q1.md` and `Archive/old-q1-draft.md` puts
    /// whichever the index returned first at the top, and Return opens a coin
    /// flip.
    ///
    /// Ranking happens over `rows` (the browse set) rather than through
    /// `store.search`, because this matches TITLES only — full-text search is
    /// a different question with a different surface, and mixing them would
    /// make Return unpredictable in a different way.
    static func rankedDocuments(_ query: String, rows: [IndexRow],
                                vaultRoot: URL?) -> [LorePaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let scored: [(IndexRow, Int)] = rows.compactMap { row in
            let name = (row.title.isEmpty ? row.path.lastPathComponent : row.title)
                .lowercased()
            guard !trimmed.isEmpty else { return (row, 0) }
            if name.hasPrefix(trimmed) { return (row, 0) }
            // A match at a word boundary reads as intentional; one in the
            // middle of a word is usually incidental.
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains(where: { $0.hasPrefix(trimmed) }) { return (row, 1) }
            if name.contains(trimmed) { return (row, 2) }
            return nil
        }
        return scored
            .sorted {
                $0.1 != $1.1 ? $0.1 < $1.1
                    : $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
            }
            .prefix(50)
            .map { row, _ in
                LorePaletteItem(id: "doc:\(row.path.path)",
                                title: row.title.isEmpty
                                    ? row.path.lastPathComponent : row.title,
                                systemName: LoreSidebarRow.icon(for: row),
                                detail: folderHint(for: row.path, vaultRoot: vaultRoot),
                                payload: .document(row.path))
            }
    }

    /// The containing folder, vault-relative — the disambiguator when several
    /// notes share a title, which in a real vault they routinely do.
    static func folderHint(for url: URL, vaultRoot: URL?) -> String? {
        guard let vaultRoot else { return nil }
        let root = VaultIndexCoordinator.canonical(vaultRoot).pathComponents
        let parts = VaultIndexCoordinator.canonical(url).pathComponents
        guard parts.count > root.count,
              Array(parts.prefix(root.count)) == root else { return nil }
        let folders = parts.dropFirst(root.count).dropLast()
        return folders.isEmpty ? nil : folders.joined(separator: "/")
    }
}
