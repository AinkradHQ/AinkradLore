import AinkradAppKit
import SwiftUI

/// A right-edge panel over the editor.
///
/// It OVERLAYS rather than narrows: the text column never reflows, so the
/// writing position is identical whether the panel is open or shut. Fixed
/// width by design — one less piece of persisted state for something that is
/// meant to be transient.
struct DocumentSlideover<Content: View>: View {
    let title: String
    let theme: HostTheme
    let onClose: () -> Void
    @ViewBuilder let content: Content

    static var width: CGFloat { 300 }

    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Text(title)
                    .font(AinkradFontResolver.font(.headline, typography: typo))
                    .foregroundStyle(theme.tokens.foreground)
                Spacer(minLength: AinkradSpacing.sm)
                AinkradIconButton(systemName: "xmark", tooltip: "Close", action: onClose)
                    .accessibilityLabel("Close \(title)")
            }
            content
            Spacer(minLength: 0)
        }
        .padding(AinkradSpacing.md)
        .frame(width: Self.width)
        .modifier(SlideoverSurface(theme: theme))
    }
}

/// Neon's opaque slab with a drop shadow, or the kit's Liquid Glass panel.
private struct SlideoverSurface: ViewModifier {
    let theme: HostTheme
    @Environment(\.ainkradSkin) private var skin

    @ViewBuilder func body(content: Content) -> some View {
        if skin.usesNativeGlass {
            content.ainkradPanel()
        } else {
            content
                .background(theme.tokens.surfaceElevated)
                .shadow(
                    color: .black.opacity(skin.opacity.o35),
                    radius: CGFloat(skin.size.s12), x: -4, y: 0)
        }
    }
}
