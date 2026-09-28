import SwiftUI
import AppKit
import AinkradAppKit

struct LoreSettingsView: View {
    @Bindable var store: LoreStore
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo
    /// Why the last vault choice did not take. Nil when nothing has failed.
    @State private var failure: String?
    /// View state, not a persisted preference: the shortcut list is reference
    /// material someone opens, reads and is done with, so remembering that it
    /// was open once is not worth a stored key.
    @State private var shortcutsExpanded = false
    @State private var showAllFilesHelpExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.lg) {
            // Grouped rather than one flat stack. The page grew from three
            // rows to eight over this milestone, and a flat list of eight
            // unrelated controls makes the reader scan all of them to find the
            // one they came for.
            AinkradSectionHeader(title: "Vault")

            AinkradFormRow(title: "Vault folder",
                           help: "The folder of markdown files Lore reads and writes.") {
                HStack(spacing: AinkradSpacing.sm) {
                    Text(store.vaultRoot?.path ?? "None selected")
                        .font(AinkradFontResolver.font(.mono, typography: typo))
                        .foregroundStyle(theme.tokens.foreground.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AinkradButton(title: "Choose…", style: .secondary, action: pickFolder)
                }
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(theme.tokens.accentPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.subfolders.isEmpty {
                AinkradFormRow(title: "Default new-note folder",
                               help: "Where ⌘N quick-capture saves new notes.") {
                    AinkradSelect(items: [""] + store.subfolders,
                                  selection: defaultFolderBinding,
                                  label: { $0.isEmpty ? "Vault root" : $0 })
                }
            }

            AinkradFormRow(title: "Focus mode",
                           help: "Dim everything except the paragraph you're "
                               + "writing.") {
                AinkradToggle(isOn: Binding(
                    get: { store.editorSettings.focusMode },
                    set: { on in
                        var next = store.editorSettings
                        next.focusMode = on
                        store.setEditorSettings(next)
                    }))
            }

            AinkradFormRow(title: "Typewriter scrolling",
                           help: "Keep the line you're writing at a fixed "
                               + "height instead of letting it walk to the "
                               + "bottom of the window.") {
                AinkradToggle(isOn: Binding(
                    get: { store.editorSettings.typewriterMode },
                    set: { on in
                        var next = store.editorSettings
                        next.typewriterMode = on
                        store.setEditorSettings(next)
                    }))
            }

            AinkradSectionHeader(title: "Display")

            // The help text was seven lines inside a form row — longer than
            // everything above it put together, and unreadable as a caption.
            // One line states the setting; the disclosure holds the caveat
            // that only matters once someone has hit it.
            AinkradFormRow(title: "Show all files",
                           help: "Show attachments and other non-document "
                               + "files in the sidebar.") {
                AinkradToggle(isOn: showAllFilesBinding)
            }
            AinkradDisclosureGroup(title: "What this affects",
                                   isExpanded: $showAllFilesHelpExpanded) {
                Text("Off by default so the sidebar stays a list of documents. "
                     + "Files stay fully indexed, linkable and openable either "
                     + "way — this only changes what the browse list draws.")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }

            AinkradFormRow(title: "Render tags as chips",
                           help: "Draw inline #tags with a tinted background. "
                               + "Off leaves them as tinted text.") {
                AinkradToggle(isOn: Binding(
                    get: { store.editorSettings.renderTagsAsChips },
                    set: { on in
                        var next = store.editorSettings
                        next.renderTagsAsChips = on
                        store.setEditorSettings(next)
                    }))
            }

            // The editor's OWN settings — not inherited from the host theme.
            // The host owns hue; how large the text is and how wide the column
            // runs are properties of the document and the person reading it.
            // See `EditorSettings`.
            AinkradSectionHeader(title: "Editor")

            AinkradFormRow(title: "Text size",
                           help: "Line height and paragraph spacing move with "
                               + "it, so the page keeps its rhythm. ⌘+ and ⌘− "
                               + "adjust it per session; ⌘0 resets.") {
                AinkradSegmentedPicker(
                    items: EditorSettings.Density.allCases,
                    selection: Binding(
                        get: { store.editorSettings.density },
                        set: { density in
                            var next = store.editorSettings
                            next.density = density
                            store.setEditorSettings(next)
                        })
                ) { $0.title }
            }

            AinkradFormRow(title: "Line width",
                           help: "How wide the text column runs. A measure much "
                               + "beyond ~70 characters is tiring to read, which "
                               + "is what full width gives you on a wide display "
                               + "— it is there for tables and wide code blocks.") {
                AinkradSelect(items: EditorSettings.Measure.allCases,
                              selection: Binding(
                                get: { store.editorSettings.measure },
                                set: { measure in
                                    var next = store.editorSettings
                                    next.measure = measure
                                    store.setEditorSettings(next)
                                }),
                              label: { $0.title })
            }

            AinkradSectionHeader(title: "Index")

            AinkradFormRow(title: "Index",
                           help: "Rebuild the search index from the files on disk.") {
                HStack(spacing: AinkradSpacing.sm) {
                    // `rebuildInBackground()`, never `try? store.rebuild()`:
                    // the synchronous path walks and parses the whole vault on
                    // the main actor, which on a large vault is a multi-second
                    // freeze — and the `try?` threw the failure away, so a
                    // rebuild that could not run looked identical to one that
                    // did.
                    AinkradButton(title: "Rebuild index", style: .ghost) {
                        store.rebuildInBackground()
                    }
                    .disabled(store.isIndexing)
                    if store.isIndexing {
                        AinkradSpinner(size: 14)
                        Text("Indexing…")
                            .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                    }
                }
            }

            // The rescan's own failure, which used to be discarded. Distinct
            // from `failure` above, which reports a refused VAULT CHOICE — two
            // different problems with two different fixes.
            if let indexError = store.indexError {
                AinkradBanner(message: "The index couldn't be rebuilt: \(indexError)",
                              status: .danger)
            }

            // Collapsed by default: it is reference material, consulted
            // occasionally, and expanded it is longer than everything above it
            // put together.
            AinkradDisclosureGroup(title: "Keyboard shortcuts",
                                   isExpanded: $shortcutsExpanded) {
                LoreShortcutsReference(theme: theme)
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.ainkradTheme, theme.tokens)
    }

    private var defaultFolderBinding: Binding<String> {
        Binding(get: { store.defaultNoteFolder },
                set: { store.setDefaultNoteFolder($0) })
    }

    private var showAllFilesBinding: Binding<Bool> {
        Binding(get: { store.showAllFiles },
                set: { store.setShowAllFiles($0) })
    }

    /// Shares `SidebarOperations`' picker so settings and the first-run empty
    /// state cannot drift apart, and so a failure here is reported rather than
    /// swallowed. This was `try? store.setVaultRoot(url)`: a vault that could
    /// not be bookmarked or indexed left the row still reading "None selected"
    /// with nothing said about why.
    private func pickFolder() {
        let ops = SidebarOperations(store: store)
        ops.beginChooseVault()
        failure = ops.message
    }
}
