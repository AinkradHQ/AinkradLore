import SwiftUI
import AinkradAppKit

/// The ⋯ menu's contents, rendered INSIDE the app's own window.
///
/// ## Two failed attempts precede this
///
/// 1. `AinkradIconButton` with an empty action plus `.ainkradContextMenu` —
///    that modifier presents on RIGHT-click, so left-clicking did nothing.
/// 2. `ainkradPopover`, which hosts content in a separate borderless
///    `NSPanel`. The menu appeared and then dismissed on any click without
///    running the item.
///
/// The second failure is the reason this is a plain overlay. A separate panel
/// window brings key-window transitions and a global outside-click monitor
/// into a problem that needs neither: this menu is small, lives for one click,
/// and has no reason to leave the window it belongs to. An in-window overlay
/// has no monitors to satisfy and no window to become key — a `Button` in it
/// is just a button.
///
/// The kit's own selects and context menus use that floating panel happily, so
/// this is not a claim it is broken; it is a claim that it was the wrong tool
/// for a menu hung off a toolbar button, and that two attempts to make it fit
/// were enough.
struct DocumentActionsMenu: View {
    let items: [AinkradMenuItem]
    let theme: HostTheme
    let onDismiss: () -> Void

    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in row(item) }
        }
        .padding(.vertical, AinkradSpacing.xs)
        // An explicit WIDTH, not a minimum. `minWidth` is a floor, and the
        // rows below use `maxWidth: .infinity` to make the whole row a hit
        // target — so inside the full-width scrim `ZStack` the menu happily
        // stretched to the width of the window. The rows still fill, they just
        // fill this.
        .frame(width: 240, alignment: .leading)
        .background(theme.tokens.surfaceElevated)
        .clipShape(ChamferShape(cut: LoreMetrics.chamfer))
        .overlay(ChamferShape(cut: LoreMetrics.chamfer)
            .strokeBorder(theme.tokens.foreground.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.ainkradTheme, theme.tokens)
    }

    private func row(_ item: AinkradMenuItem) -> some View {
        Button {
            // Dismissed BEFORE the action runs: several of these open a sheet,
            // and a menu left standing over one swallows its first click.
            onDismiss()
            item.action()
        } label: {
            HStack(spacing: AinkradSpacing.sm) {
                if let systemName = item.systemName {
                    AinkradIconGlyph(systemName: systemName, size: 11)
                }
                Text(item.title)
                    .font(AinkradFontResolver.font(.body, typography: typo))
                Spacer(minLength: AinkradSpacing.md)
                if let shortcut = item.shortcut {
                    AinkradKbd(shortcut)
                }
            }
            .foregroundStyle(item.isDestructive
                             ? theme.tokens.accentPrimary
                             : theme.tokens.foreground)
            .padding(.horizontal, AinkradSpacing.sm)
            .padding(.vertical, AinkradSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
