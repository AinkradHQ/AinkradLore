import AppKit

/// Reaches the focused text view's find bar.
///
/// ## Why this indirection exists
///
/// On a normal Mac app ⌘F arrives from the Edit menu's Find item, and
/// `NSTextView` handles it for free. Lore is a PLUGIN: it has no menu bar of
/// its own, so nothing dispatches those key equivalents and the find bar —
/// which `MarkdownEditorView` enables — would be permanently unreachable.
///
/// `sendAction(_:to:from:)` with a `nil` target walks the responder chain, so
/// the action lands on whichever text view is first responder without this
/// code holding a reference to it. That matters because the alternative was
/// plumbing a find handler up through `EditorContext` — a protocol shared with
/// the PDF and rich-text engines, neither of which has a find bar to offer.
///
/// `performFindPanelAction(_:)` reads which operation to perform off the
/// SENDER's `tag`, which is why an otherwise pointless `NSMenuItem` is built
/// here: it is the tag carrier the API expects.
enum LoreFind {

    /// Performs a find action against the first responder.
    ///
    /// Returns whether anything handled it. `false` means focus was somewhere
    /// with no find bar — the sidebar, the palette — and the keystroke is
    /// simply ignored, which is the correct outcome: ⌘F in a list is not a
    /// request to search the document the user is not looking at.
    @discardableResult
    static func perform(_ action: NSTextFinder.Action) -> Bool {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        return NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)),
                                to: nil, from: sender)
    }
}
