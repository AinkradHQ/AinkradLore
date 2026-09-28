import Foundation

/// The second pane: opening it, focusing it, and closing it.
///
/// Split view exists for ONE job — reading one document while writing another
/// — and the decisions here are what keep it that size. There are two panes,
/// not N; the split is a working arrangement rather than a preference, so
/// nothing here persists; and the pane a command acts on is the FOCUSED one
/// rather than a fixed side, because the reference document is as often on the
/// left as the right.
///
/// The store half only. Which pane is on screen where, and how focus is shown,
/// belong to the view — this is the state those decisions read.
extension LoreStore {

    /// Whether the view is split.
    public var isSplit: Bool { secondaryPane != nil }

    /// Opens `url` beside the current document, splitting if needed.
    ///
    /// Focus MOVES to the new pane: the user asked for this document to appear
    /// beside the other, and leaving focus behind would send the next
    /// keystroke to the document they just navigated away from.
    public func openInSecondaryPane(url: URL) {
        if secondaryPane == nil { secondaryPane = PaneState() }
        focusIsSecondary = true
        open(url: url)
    }

    /// Splits on whatever is currently open, so the split starts from
    /// something rather than an empty pane.
    ///
    /// Returns false when there is nothing to split on — an empty pane beside
    /// an empty pane is not a useful state to be able to reach.
    @discardableResult
    public func splitCurrentDocument() -> Bool {
        guard !isSplit, let url = pane.session?.url else { return false }
        openInSecondaryPane(url: url)
        return true
    }

    /// Closes the second pane.
    ///
    /// Does NOT close the document: it stays in the warm cache, reachable by
    /// Back or ⌘P, because collapsing a layout is not a request to discard
    /// what was in it. Closing the DOCUMENT is ⌘W's job and still routes
    /// through `closeTab`'s refusal path.
    ///
    /// Focus returns to the primary pane unconditionally — leaving
    /// `focusIsSecondary` true with no secondary pane is the one way commands
    /// could quietly act on nothing.
    public func closeSecondaryPane() {
        secondaryPane = nil
        focusIsSecondary = false
    }

    /// Moves focus between panes.
    ///
    /// Ignored when asked to focus a pane that does not exist, rather than
    /// creating one: focus is a consequence of the split, never a way to make
    /// one.
    public func focusPane(secondary: Bool) {
        guard !secondary || isSplit else { return }
        focusIsSecondary = secondary
    }
}
