import AppKit

/// Focus mode and typewriter scrolling, applied to the text view.
extension MarkdownEditor.Coordinator {

    /// How far unfocused text fades.
    ///
    /// Faded, not hidden. The point of focus mode is to quieten the rest of
    /// the document, not to make it unreadable — a writer glances up at the
    /// previous paragraph constantly, and a mode that made that impossible
    /// would be turned off within a minute.
    static let unfocusedAlpha: CGFloat = 0.35

    /// Applies both writing modes for the current caret position.
    ///
    /// Called from the same selection-change path the reveal logic uses, so a
    /// caret move does one pass rather than two.
    func applyWritingModes() {
        applyFocusDimming()
        applyTypewriterScroll()
    }

    /// Dims everything outside the caret's paragraph.
    ///
    /// TEMPORARY attributes, never the text storage. This is the same
    /// distinction that lets the find bar's highlighting coexist with the
    /// markdown styling: `MarkdownStyleRendering` owns the storage's real
    /// attributes and rewrites them on every restyle, so a dim written there
    /// would be erased on the next keystroke — or worse, would survive into a
    /// SAVE if anything ever read attributes back out. Temporary attributes
    /// live on the layout manager and belong to presentation alone.
    private func applyFocusDimming() {
        guard let tv = textView, let layoutManager = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        // Cleared unconditionally, including when the mode is off: switching it
        // off must un-dim a document that is already on screen, and this is the
        // only path that runs then.
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard settings.focusMode else { return }

        let focused = WritingModes.paragraphRange(in: tv.string,
                                                  caret: tv.selectedRange().location)
        let dimmed = NSColor(tokens.foreground).withAlphaComponent(Self.unfocusedAlpha)
        for range in [NSRange(location: 0, length: focused.location),
                      NSRange(location: focused.location + focused.length,
                              length: full.length - (focused.location + focused.length))]
        where range.length > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dimmed,
                                                forCharacterRange: range)
        }
    }

    /// Keeps the caret at a fixed height in the viewport.
    private func applyTypewriterScroll() {
        guard settings.typewriterMode,
              let tv = textView,
              let scroll = tv.enclosingScrollView else { return }
        let caret = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        guard caret != .zero, let window = tv.window else { return }

        // Screen → window → the clip view's own space, which is what
        // `scroll(to:)` speaks. Converting in one hop would land in the text
        // view's coordinates and be wrong by the container's inset.
        let inWindow = window.convertFromScreen(caret)
        let inClip = scroll.contentView.convert(inWindow, from: nil)
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let origin = WritingModes.typewriterOrigin(
            caretY: inClip.midY + scroll.contentView.bounds.origin.y,
            viewportHeight: scroll.contentView.bounds.height,
            documentHeight: documentHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
