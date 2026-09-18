import SwiftUI
import AppKit
import AinkradAppKit

/// Floats `LinkCompletionView` over the editor without stealing focus.
///
/// A child `NSPanel`, not an `NSPopover`: a popover makes its own window key,
/// which pulls first-responder status off the text view and stops the very
/// typing the completion list exists to assist. A `.nonactivatingPanel` added
/// as a child window keeps the text view first responder, so every keystroke
/// still lands in the document. That in turn means the panel never receives
/// key events at all — arrow/return/escape handling lives in the text view's
/// `doCommandBy:` and drives this controller's selection.
///
/// A floating window that outlives its reason to exist is the failure mode
/// here, so every path that ends editing calls `hide()`: Escape, the caret
/// leaving the link, the text view resigning first responder, and view
/// teardown. Scrolling repositions instead — the caret is still there.
@MainActor
final class LinkCompletionPanel {
    private var panel: NSPanel?
    private var host: NSHostingController<LinkCompletionView>?
    private var selection = LinkCompletionSelection()
    private var tokens: HostThemeTokens?

    /// Called when the user picks a row, by click or by return.
    var onPick: ((LinkCompletionItem) -> Void)?

    var isVisible: Bool { panel != nil }

    /// - Parameter caretRect: the caret rect in SCREEN coordinates, as returned
    ///   by `NSTextView.firstRect(forCharacterRange:actualRange:)`.
    func show(matches: [LinkCompletionItem], tokens: HostThemeTokens,
              caretRect: NSRect, over view: NSView) {
        guard !matches.isEmpty, let window = view.window else { hide(); return }
        selection.update(to: matches)
        self.tokens = tokens

        let panel = self.panel ?? makePanel(attachedTo: window)
        self.panel = panel
        render(into: panel)
        place(panel, at: caretRect, on: window)
        panel.orderFront(nil)
    }

    /// Keeps an open list pinned to the caret while the document scrolls
    /// underneath it. Without this the list stays put and points at the wrong
    /// line.
    func reposition(caretRect: NSRect, over view: NSView) {
        guard let panel, let window = view.window else { return }
        place(panel, at: caretRect, on: window)
    }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        host = nil
        tokens = nil
        selection.clear()
    }

    func moveSelection(by delta: Int) {
        guard let panel else { return }
        selection.move(by: delta)
        render(into: panel)
    }

    func pickSelected() {
        guard let row = selection.current else { return }
        onPick?(row)
    }

    // MARK: - Plumbing

    private func render(into panel: NSPanel) {
        guard let tokens else { return }
        let root = LinkCompletionView(matches: selection.matches,
                                      selected: selection.index,
                                      tokens: tokens) { [weak self] row in self?.onPick?(row) }
        if let host { host.rootView = root } else {
            let controller = NSHostingController(rootView: root)
            host = controller
            panel.contentViewController = controller
        }
        panel.setContentSize(host?.view.fittingSize ?? NSSize(width: 260, height: 100))
    }

    private func place(_ panel: NSPanel, at caretRect: NSRect, on window: NSWindow) {
        let size = panel.frame.size
        // Below the caret line by default; above it when there is no room, so
        // the list never hangs off the bottom of the screen.
        let screen = window.screen ?? NSScreen.main
        let below = caretRect.minY - 4
        let fitsBelow = (screen.map { below - size.height >= $0.visibleFrame.minY }) ?? true
        panel.setFrameTopLeftPoint(NSPoint(x: caretRect.minX,
                                           y: fitsBelow ? below
                                                        : caretRect.maxY + 4 + size.height))
    }

    private func makePanel(attachedTo window: NSWindow) -> NSPanel {
        let panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        window.addChildWindow(panel, ordered: .above)
        return panel
    }
}

/// A panel that can never take key status.
///
/// `NSPanel.canBecomeKey` is `true` even for a borderless panel, so WITHOUT
/// this a mouse-down on a completion row makes the panel key, the text view
/// resigns first responder, the resign handler hides the panel — and the row's
/// action never runs, because the button it belonged to was torn down between
/// mouse-down and mouse-up. Refusing key status keeps first responder on the
/// text view for the whole click, so the button completes its tracking and
/// fires, and the resign handler never runs at all.
///
/// Mouse events do not require key status: they are routed to the window under
/// the cursor. That is what makes a non-key panel clickable but unfocusable,
/// which is exactly what a completion list wants.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
