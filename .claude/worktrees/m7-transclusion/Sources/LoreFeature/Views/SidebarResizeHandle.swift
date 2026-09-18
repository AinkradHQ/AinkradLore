import SwiftUI
import AinkradAppKit

/// Where a sidebar drag lands. Pure, so the compounding bug that the first
/// version of this shipped with — applying the translation to the live width
/// on every event — is stated as a test rather than felt as a sidebar that
/// runs away from the pointer.
enum SidebarResize {
    static func width(start: CGFloat, translation: CGFloat) -> CGFloat {
        LoreMetrics.clampSidebarWidth(start + translation)
    }
}

/// The draggable divider between the sidebar and the editor.
///
/// The sidebar was a fixed 280pt, which is the wrong width for both of the
/// cases that actually occur: a deep folder tree truncates every name, and a
/// flat list of short titles wastes a third of a small display.
///
/// ## Why a 5pt strip with a 9pt hit area
///
/// A divider thin enough to look like a divider is too thin to grab. The strip
/// DRAWS at hairline width and takes its hit target from `contentShape`, which
/// is the standard resolution — the same reason the tab close button kept a
/// 20×20 target while drawing at 9pt.
struct SidebarResizeHandle: View {
    let width: CGFloat
    let theme: HostTheme
    let onChange: (CGFloat) -> Void

    @State private var hovering = false
    /// The width when the current drag began.
    ///
    /// Load-bearing: `width` is the LIVE store value and updates as the drag
    /// proceeds, so applying `translation` to it on every event compounds —
    /// the sidebar accelerates away from the pointer and the divider ends up
    /// nowhere near the cursor. `translation` is measured from the gesture's
    /// start, so it must be added to the width at the gesture's start.
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(hovering ? theme.tokens.accentSecondary : theme.tokens.foreground.opacity(0.12))
            .frame(width: 1)
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
                    .onChanged { value in
                        // Translation from the gesture's start, applied to the
                        // width AT that start — see `dragStart`. Deliberately
                        // not the pointer's absolute x: the sidebar does not
                        // begin at the window's left edge in every host, so an
                        // absolute reading would snap the divider to the cursor
                        // on the first pixel of movement.
                        let start = dragStart ?? width
                        if dragStart == nil { dragStart = width }
                        onChange(SidebarResize.width(start: start,
                                                     translation: value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize sidebar")
            // Exposed as an adjustable so VoiceOver can drive it — a
            // drag-only control is unreachable without a pointer.
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(width + 20)
                case .decrement: onChange(width - 20)
                @unknown default: break
                }
            }
    }
}
