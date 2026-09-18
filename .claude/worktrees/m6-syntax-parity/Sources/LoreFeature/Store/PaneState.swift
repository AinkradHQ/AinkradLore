import Foundation

/// One editing pane: the document it is showing, and how it got there.
///
/// ## Why this exists before split view does
///
/// Lore shows one document. Split view will show two, and every property that
/// answers "which document, and what is behind the back button" has to become
/// per-pane when it does. Extracting them into a value FIRST — with the store
/// holding exactly one and every existing accessor forwarding to it — turns
/// that milestone's riskiest step into an additive one: adding a second pane
/// becomes a second `PaneState`, not a second meaning for a dozen properties
/// scattered across the store.
///
/// This step is deliberately behaviour-preserving. The test count is unchanged
/// by it, and that is the point: a refactor that moves the number has moved
/// behaviour instead of code.
///
/// ## What is NOT here
///
/// `tabs` — the warm session cache — stays on the store. It is not per-pane:
/// it is the set of documents kept loaded behind whatever the panes are
/// showing, and two panes will share one cache. Putting it here would give
/// each pane its own cache and evict documents the other is holding.
struct PaneState {
    /// The document on screen in this pane.
    var session: DocumentSession?
    /// Documents visited in this pane, oldest first — the back/forward stack.
    var history: [URL] = []
    /// Where in `history` the current document sits. Nil before anything opens.
    var historyIndex: Int?

    var canGoBack: Bool { (historyIndex ?? 0) > 0 }
    var canGoForward: Bool {
        guard let historyIndex else { return false }
        return historyIndex + 1 < history.count
    }

    /// Forgets everything. Used when the vault changes underneath the pane:
    /// its history holds URLs that point into the vault being closed.
    mutating func reset() {
        session = nil
        history = []
        historyIndex = nil
    }

    /// Records a visit, truncating any forward entries.
    ///
    /// Truncation is what makes Forward mean something: after going back and
    /// then opening something new, the trail you abandoned is not somewhere
    /// you can return to — the rule every browser follows, and the absence of
    /// it is how a forward stack becomes a list of places nobody chose.
    ///
    /// Re-visiting the CURRENT document records nothing: clicking the open
    /// note in the sidebar is not navigation, and treating it as such fills
    /// the stack with duplicates that make Back appear broken.
    mutating func recordVisit(_ url: URL, key: (URL) -> String) {
        if let historyIndex, history.indices.contains(historyIndex),
           key(history[historyIndex]) == key(url) {
            return
        }
        if let historyIndex, historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(url)
        historyIndex = history.count - 1
    }
}
