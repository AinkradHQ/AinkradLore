import SwiftUI
import AppKit
import AinkradAppKit

/// The draggable divider between the two editor panes.
///
/// Same shape as `SidebarResizeHandle`, including the bug that one documents:
/// the drag applies its translation to the fraction AT THE GESTURE'S START,
/// not the live value, because `translation` is cumulative from where the drag
/// began. Applying it to the live value on every event compounds, and the
/// divider accelerates away from the pointer.
struct SplitDivider: View {
    @Binding var fraction: CGFloat
    let theme: HostTheme

    @State private var hovering = false
    @State private var dragStart: CGFloat?

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
            Rectangle()
                .fill(hovering ? theme.tokens.accentSecondary
                               : theme.tokens.foreground.opacity(0.12))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -4))
                .onHover { hovering = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active: NSCursor.resizeLeftRight.set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? fraction
                            if dragStart == nil { dragStart = fraction }
                            // The window's width, not the divider's: the
                            // divider is one point wide, so its own geometry
                            // says nothing about how far a drag has moved in
                            // proportion to the editor.
                            let width = max(geometry.size.width, 1)
                            fraction = Self.clamped(start + value.translation.width / width)
                        }
                        .onEnded { _ in dragStart = nil })
                .accessibilityLabel("Resize panes")
                .accessibilityValue("\(Int(fraction * 100)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: fraction = Self.clamped(fraction + 0.05)
                    case .decrement: fraction = Self.clamped(fraction - 0.05)
                    @unknown default: break
                    }
                }
        }
        .frame(width: 1)
    }
}
