import AinkradAppKit
import SwiftUI

/// Lore's settings as DECLARED fields, so the host draws them in the shared
/// settings style — and puts its Appearance tab (Open as, Open in, Blur) first.
/// `LoreSettingsView` stays as the page for hosts that predate this; the
/// wording here is the same.
@MainActor
enum LoreSettingsCatalog {
    /// Why the last vault choice did not take — shown under the row until the
    /// next attempt. Nil when nothing has failed.
    static var vaultFailure: String?

    static func page(store: LoreStore, theme: HostTheme) -> SettingsPage {
        let root = SettingsPath([LoreApp.id])
        return SettingsPage(
            path: root, title: "Lore", icon: "book.closed", group: .installedApps, order: 0,
            groups: [
                vault(store, root), editor(store, root), display(store, root),
                index(store, root), shortcuts(root),
            ],
            appID: LoreApp.id)
    }

    private static func vault(_ store: LoreStore, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("vault")
        var fields = [
            SettingsField(
                path: group.appending("folder"),
                label: "Vault folder",
                help: vaultFailure ?? store.configuredVaultRoot?.path
                    ?? "None selected — the folder of markdown files Lore reads and writes.",
                keywords: ["vault", "folder", "notes", "directory"],
                kind: .action(title: "Choose…") {
                    let ops = SidebarOperations(store: store)
                    ops.beginChooseVault()
                    vaultFailure = ops.message
                })
        ]
        if !store.subfolders.isEmpty {
            fields.append(
                SettingsField(
                    path: group.appending("default-folder"),
                    label: "Default new-note folder",
                    help: "Where ⌘N quick-capture saves new notes.",
                    keywords: ["new note", "capture", "folder"],
                    kind: .select(
                        options: [SettingsOption(id: "", title: "Vault root")]
                            + store.subfolders.map { SettingsOption(id: $0, title: $0) },
                        selection: Binding(
                            get: { store.defaultNoteFolder },
                            set: { store.setDefaultNoteFolder($0) })),
                    defaultDescription: "Vault root",
                    isModified: { !store.defaultNoteFolder.isEmpty },
                    reset: { store.setDefaultNoteFolder("") }))
        }
        return SettingsGroup(path: group, title: "Vault", fields: fields)
    }

    private static func editor(_ store: LoreStore, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("editor")
        return SettingsGroup(
            path: group, title: "Editor",
            fields: [
                select(
                    store, group.appending("text-size"), "Text size",
                    "Line height and paragraph spacing move with it, so the page keeps its rhythm. "
                        + "⌘+ and ⌘− adjust it per session; ⌘0 resets.",
                    \.density, EditorSettings.Density.allCases, title: \.title),
                select(
                    store, group.appending("line-width"), "Line width",
                    "How wide the text column runs. A measure much beyond ~70 characters is tiring "
                        + "to read, which is what full width gives you on a wide display — it is there "
                        + "for tables and wide code blocks.",
                    \.measure, EditorSettings.Measure.allCases, title: \.title),
                toggle(
                    store, group.appending("focus"), "Focus mode",
                    "Dim everything except the paragraph you're writing.", \.focusMode),
                toggle(
                    store, group.appending("typewriter"), "Typewriter scrolling",
                    "Keep the line you're writing at a fixed height instead of letting it walk to "
                        + "the bottom of the window.", \.typewriterMode),
                toggle(
                    store, group.appending("codemirror"), "Experimental CodeMirror editor",
                    "Renders with CodeMirror instead of the native editor: tables edit in place, "
                        + "embedded notes and images render inline, maths is typeset, and link "
                        + "completion and hover previews work. A file with mixed line endings opens in "
                        + "the native editor instead, so its bytes are preserved. Reopen the note "
                        + "after changing this.", \.usesCM6),
            ])
    }

    private static func display(_ store: LoreStore, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("display")
        return SettingsGroup(
            path: group, title: "Display",
            fields: [
                SettingsField(
                    path: group.appending("all-files"),
                    label: "Show all files",
                    help: "Show attachments and other non-document files in the sidebar. Files stay "
                        + "indexed, linkable and openable either way — this only changes what the "
                        + "browse list draws.",
                    keywords: ["attachments", "files", "sidebar", "hidden"],
                    kind: .toggle(Binding(get: { store.showAllFiles }, set: { store.setShowAllFiles($0) })),
                    defaultDescription: "Off",
                    isModified: { store.showAllFiles },
                    reset: { store.setShowAllFiles(false) }),
                toggle(
                    store, group.appending("tag-chips"), "Render tags as chips",
                    "Draw inline #tags with a tinted background. Off leaves them as tinted text.",
                    \.renderTagsAsChips),
            ])
    }

    private static func index(_ store: LoreStore, _ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("index")
        let help =
            store.indexError.map { "The index couldn't be rebuilt: \($0)" }
            ?? (store.isIndexing ? "Indexing…" : "Rebuild the search index from the files on disk.")
        return SettingsGroup(
            path: group, title: "Index",
            fields: [
                SettingsField(
                    path: group.appending("rebuild"),
                    label: "Search index",
                    help: help,
                    keywords: ["index", "rebuild", "search", "reindex"],
                    // Background, never the synchronous rebuild: that walks the
                    // whole vault on the main actor.
                    kind: .action(title: "Rebuild index") { store.rebuildInBackground() })
            ])
    }

    /// One declared row per command, generated from `LoreCommands.all` — the
    /// same catalog the key bindings mount from, so this cannot list a key
    /// that does not work. The keys sit on the control rail like any other
    /// row's control. Commands with no shortcut are listed too: this is the one
    /// place the full set of things Lore can do is written down.
    private static func shortcuts(_ root: SettingsPath) -> SettingsGroup {
        let group = root.appending("shortcuts")
        var fields = LoreCommand.Group.allCases.flatMap { section in
            LoreCommands.all.filter { $0.group == section }.map { command in
                SettingsField(
                    path: group.appending("\(command.id)"),
                    label: command.title,
                    help: command.shortcut == nil
                        ? "\(section.rawValue) · no shortcut — run it from ⌘K"
                        : section.rawValue,
                    keywords: ["shortcut", "keyboard", section.rawValue.lowercased()],
                    kind: .shortcut(.constant(command.shortcut?.display ?? "⌘K")))
            }
        }
        // Not in the command registry (see `LoreCommands.all`), so written out
        // by hand — omitting them would make the list quietly incomplete.
        let also: [(String, String, String)] = [
            ("escape", "Close the palette, a side panel, or the link suggestions", "esc"),
            ("footnote", "Jump to a footnote's definition, and back", "Click"),
            ("tag", "Filter the note list to a #tag", "Click"),
        ]
        fields += also.map { id, label, keys in
            SettingsField(
                path: group.appending(id), label: label, help: "Also",
                keywords: ["shortcut", "keyboard"], kind: .shortcut(.constant(keys)))
        }
        return SettingsGroup(path: group, title: "Shortcuts", fields: fields)
    }

    // MARK: - Editor-settings rows

    private static func toggle(
        _ store: LoreStore, _ path: SettingsPath, _ label: String,
        _ help: String, _ key: WritableKeyPath<EditorSettings, Bool>
    ) -> SettingsField {
        let fallback = EditorSettings.default[keyPath: key]
        return SettingsField(
            path: path, label: label, help: help, keywords: [label.lowercased()],
            kind: .toggle(
                Binding(
                    get: { store.editorSettings[keyPath: key] },
                    set: { set(store, key, $0) })),
            defaultDescription: fallback ? "On" : "Off",
            isModified: { store.editorSettings[keyPath: key] != fallback },
            reset: { set(store, key, fallback) })
    }

    private static func select<V: RawRepresentable & Equatable>(
        _ store: LoreStore, _ path: SettingsPath, _ label: String, _ help: String,
        _ key: WritableKeyPath<EditorSettings, V>, _ all: [V], title: KeyPath<V, String>
    ) -> SettingsField where V.RawValue == String {
        let fallback = EditorSettings.default[keyPath: key]
        return SettingsField(
            path: path, label: label, help: help, keywords: [label.lowercased()],
            kind: .select(
                options: all.map { SettingsOption(id: $0.rawValue, title: $0[keyPath: title]) },
                selection: Binding(
                    get: { store.editorSettings[keyPath: key].rawValue },
                    set: { if let v = V(rawValue: $0) { set(store, key, v) } })),
            defaultDescription: fallback[keyPath: title],
            isModified: { store.editorSettings[keyPath: key] != fallback },
            reset: { set(store, key, fallback) })
    }

    private static func set<V>(_ store: LoreStore, _ key: WritableKeyPath<EditorSettings, V>, _ value: V) {
        var next = store.editorSettings
        next[keyPath: key] = value
        store.setEditorSettings(next)
    }
}
