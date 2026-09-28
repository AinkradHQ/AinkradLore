import SwiftUI
import AppKit
import AinkradAppKit

/// Floats a document's opening text beside a hovered `[[link]]`.
///
/// A non-activating child `NSPanel`, for exactly the reason
/// `LinkCompletionPanel` documents: an `NSPopover` makes its own window key and
/// pulls first responder off the text view, so hovering a link while writing
/// would silently stop the next keystroke reaching the document. Hovering must
/// cost the writer nothing.
@MainActor
final class LinkPreviewPanel {
    private var panel: NSPanel?
    private var host: NSHostingController<LinkPreviewView>?

    var isVisible: Bool { panel != nil }
    /// The link currently previewed, so an unchanged hover does not rebuild.
    private(set) var shownTarget: String?

    func show(title: String, excerpt: String, target: String,
              tokens: HostThemeTokens, near rect: NSRect, over view: NSView) {
        guard let window = view.window else { hide(); return }
        shownTarget = target
        let content = LinkPreviewView(title: title, excerpt: excerpt, tokens: tokens)
        if let host {
            host.rootView = content
        } else {
            host = NSHostingController(rootView: content)
        }
        let panel = self.panel ?? makePanel(attachedTo: window)
        self.panel = panel
        panel.contentViewController = host
        panel.setContentSize(host?.view.fittingSize ?? NSSize(width: 320, height: 120))
        place(panel, near: rect, on: window)
        panel.orderFront(nil)
    }

    func hide() {
        shownTarget = nil
        panel?.orderOut(nil)
        panel?.parent?.removeChildWindow(panel!)
        panel = nil
        host = nil
    }

    private func makePanel(attachedTo window: NSWindow) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Ignores the mouse entirely: a preview that can be hovered would keep
        // itself alive under the pointer, and moving toward it would never
        // dismiss it.
        panel.ignoresMouseEvents = true
        window.addChildWindow(panel, ordered: .above)
        return panel
    }

    /// Below the hovered text where there is room, above it otherwise — so the
    /// preview never covers the link that summoned it.
    private func place(_ panel: NSPanel, near rect: NSRect, on window: NSWindow) {
        let size = panel.frame.size
        let screen = window.screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - 6)
        if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
    }
}

/// The preview's contents.
private struct LinkPreviewView: View {
    let title: String
    let excerpt: String
    let tokens: HostThemeTokens

    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            Text(title)
                .font(AinkradFontResolver.font(.headline, typography: typo))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
            if excerpt.isEmpty {
                // An empty note is a real answer to "what is in there", and a
                // blank panel is not.
                Text("This note is empty.")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(tokens.foreground.opacity(LoreMetrics.tertiaryText))
            } else {
                Text(excerpt)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(tokens.foreground.opacity(LoreMetrics.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AinkradSpacing.sm)
        .frame(width: 320, alignment: .leading)
        .background(tokens.surfaceElevated)
        .clipShape(ChamferShape(cut: LoreMetrics.chamfer))
        .overlay(ChamferShape(cut: LoreMetrics.chamfer)
            .strokeBorder(tokens.foreground.opacity(0.15), lineWidth: 1))
        .environment(\.ainkradTheme, tokens)
    }
}
