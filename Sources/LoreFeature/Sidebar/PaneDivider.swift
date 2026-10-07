import AinkradAppKit
import AppKit
import SwiftUI

/// Where a sidebar drag lands. Pure, so the compounding bug that the first
/// version of this shipped with — applying the translation to the live width
/// on every event — is stated as a test rather than felt as a sidebar that
/// runs away from the pointer.
enum SidebarResize {
    static func width(start: CGFloat, translation: CGFloat) -> CGFloat {
        LoreMetrics.clampSidebarWidth(start + translation)
    }
}

/// The draggable divider between two panes — the sidebar and the editor, or
/// the two editor panes (`SplitDivider`). One view, because the two drew the
/// same thing and had already drifted apart once.
///
/// ## Why nothing at rest, with a 9pt hit area
///
/// A resting hairline is a separator line, which the design bar rules out:
/// the surfaces either side already differ, and that difference is the edge.
/// So the strip draws NOTHING until the pointer is on it, then the
/// `accentSecondary` line plus the resize cursor say "this drags". The hit
/// target comes from `contentShape` — the same reason the tab close button
/// kept a 20×20 target while drawing at 9pt — so an invisible divider is
/// still easy to grab.
struct PaneDivider: View {
    /// The LIVE value being resized — a width, or a fraction.
    let value: CGFloat
    let theme: HostTheme
    let accessibilityLabel: String
    let accessibilityValue: String
    /// Receives the value AT THE DRAG'S START and the translation since then.
    let onDrag: (_ start: CGFloat, _ translation: CGFloat) -> Void
    /// VoiceOver's increment (+1) / decrement (-1).
    let onAdjust: (_ step: CGFloat) -> Void

    @Environment(\.ainkradSkin) private var skin
    @State private var hovering = false
    /// The value when the current drag began.
    ///
    /// Load-bearing: `value` is the LIVE store value and updates as the drag
    /// proceeds, so applying `translation` to it on every event compounds —
    /// the pane accelerates away from the pointer and the divider ends up
    /// nowhere near the cursor. `translation` is measured from the gesture's
    /// start, so it must be added to the value at the gesture's start.
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(hovering ? theme.tokens.accentSecondary : .clear)
            .frame(width: CGFloat(skin.size.s1))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering = $0 }
            // The pointer has to say "this drags" before the drag, or the
            // divider reads as decoration and nobody ever tries.
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        // Translation from the gesture's start, applied to the
                        // value AT that start — see `dragStart`. Deliberately
                        // not the pointer's absolute x: the sidebar does not
                        // begin at the window's left edge in every host, so an
                        // absolute reading would snap the divider to the cursor
                        // on the first pixel of movement.
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        onDrag(start, drag.translation.width)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel(accessibilityLabel)
            // Exposed as an adjustable so VoiceOver can drive it — a
            // drag-only control is unreachable without a pointer.
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(1)
                case .decrement: onAdjust(-1)
                @unknown default: break
                }
            }
    }
}
