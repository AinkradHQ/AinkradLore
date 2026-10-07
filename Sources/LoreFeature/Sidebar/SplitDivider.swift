import AinkradAppKit
import SwiftUI

/// The divider between the two editor panes: a `PaneDivider` that resizes a
/// FRACTION of the editor's width rather than a width in points.
struct SplitDivider: View {
    @Binding var fraction: CGFloat
    let theme: HostTheme

    @Environment(\.ainkradSkin) private var skin

    /// Neither pane may be squeezed below this share of the width. A pane too
    /// narrow to hold a line of text is not a pane, and once it is that narrow
    /// there is no grip left to drag it back with.
    static let minFraction: CGFloat = 0.25
    static let maxFraction: CGFloat = 0.75

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minFraction), maxFraction)
    }

    var body: some View {
        GeometryReader { geometry in
            PaneDivider(
                value: fraction, theme: theme,
                accessibilityLabel: "Resize panes",
                accessibilityValue: "\(Int(fraction * 100)) percent",
                onDrag: { start, translation in
                    // The window's width, not the divider's: the
                    // divider is one point wide, so its own geometry
                    // says nothing about how far a drag has moved in
                    // proportion to the editor.
                    let width = max(geometry.size.width, 1)
                    fraction = Self.clamped(start + translation / width)
                },
                onAdjust: { step in fraction = Self.clamped(fraction + step * 0.05) })
        }
        .frame(width: CGFloat(skin.size.s1))
    }
}
