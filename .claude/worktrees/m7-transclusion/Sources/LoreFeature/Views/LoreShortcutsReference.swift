import SwiftUI
import AinkradAppKit

/// The keyboard-shortcuts reference, GENERATED from `LoreCommands.all`.
///
/// Generated, not written. A hand-maintained shortcut list is a document that
/// starts correct and decays: someone rebinds a key, or adds a command, and
/// the reference keeps confidently stating the old answer. Because this reads
/// the same catalog the bindings are mounted from — and prints the same
/// `LoreShortcut.display` string the binding is derived from — it cannot
/// describe a key that does not work.
///
/// Commands with no shortcut are listed too, without a keycap. That is the
/// point rather than an oversight: this doubles as the only place the full set
/// of things Lore can do is written down, and "New Folder… has no shortcut,
/// reach it from ⌘K" is useful information.
struct LoreShortcutsReference: View {
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            ForEach(LoreCommand.Group.allCases, id: \.self) { group in
                let commands = LoreCommands.all.filter { $0.group == group }
                if !commands.isEmpty {
                    AinkradSectionHeader(title: group.rawValue)
                    VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                        ForEach(commands) { command in row(command) }
                    }
                }
            }

            // Esc is real, reachable, and deliberately NOT in the registry —
            // see `LoreCommands.all`. Documented by hand precisely because it
            // is the one key the generated list cannot know about, and
            // omitting it would make the reference quietly incomplete.
            AinkradSectionHeader(title: "Also")
            HStack(spacing: AinkradSpacing.sm) {
                AinkradKbd("esc")
                Text("Close the palette, a side panel, or the link suggestions")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(0.85))
                Spacer(minLength: 0)
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradIconGlyph(systemName: "arrow.turn.right.down", size: 11)
                Text("Click a footnote reference to jump to its definition, "
                     + "and back")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(0.85))
                Spacer(minLength: 0)
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradIconGlyph(systemName: "number", size: 11)
                Text("Click a #tag to filter the note list to it")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(0.85))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ command: LoreCommand) -> some View {
        HStack(spacing: AinkradSpacing.sm) {
            AinkradIconGlyph(systemName: command.systemName, size: 11)
            Text(command.title)
                .font(AinkradFontResolver.font(.body, typography: typo))
                .foregroundStyle(theme.tokens.foreground.opacity(0.85))
            Spacer(minLength: AinkradSpacing.sm)
            if let shortcut = command.shortcut {
                AinkradKbd(shortcut.display)
            } else {
                // Says where to find it rather than leaving a blank the reader
                // has to interpret.
                Text("⌘K")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.tertiaryText))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.shortcut.map { "\(command.title), \($0.display)" }
                            ?? "\(command.title), no shortcut, available in the command palette")
    }
}
