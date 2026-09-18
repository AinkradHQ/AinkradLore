import Foundation

/// Opening, selecting and closing documents — the session lifecycle.
///
/// Split out of `LoreStore.swift` for the 500-line ceiling. These three belong
/// together because they are the only writers of `pane.session` and the only
/// mutators of the warm cache's membership, and because the ORDER inside
/// `closeTab` is load-bearing: it refuses before it mutates, disarms the
/// debounced autosave before removing the session, and only then picks a
/// successor. Splitting them apart would separate that sequence from the
/// comments explaining why it is that sequence.
extension LoreStore {

    /// Loads `url` into the warm cache WITHOUT showing it in any pane.
    ///
    /// Test-only, and deliberately has no production caller: every real path
    /// that warms a session also displays it, which is precisely why
    /// `evictColdSessions`' "never reclaim a visible session" guard cannot be
    /// exercised without one. Filling the cache by opening documents navigates
    /// the focused pane away from the document under test, at which point
    /// evicting it is correct and the test proves nothing.
    func warmForTesting(_ url: URL) {
        guard let session = try? DocumentSession.open(url: url, coordinator: coordinator)
        else { return }
        tabs.append(session)
    }

    public func open(_ row: IndexRow) { open(url: row.path) }

    public func open(url: URL) {
        open(url: url, recordingHistory: true)
    }

    /// Opens `url`, optionally without recording the visit.
    ///
    /// `recordingHistory: false` is what `goBack()`/`goForward()` use: moving
    /// through history is not itself a new visit, and recording it would make
    /// Back push an entry that Forward then has to step over — a stack that
    /// grows every time you use it and never returns you where you started.
    func open(url: URL, recordingHistory: Bool) {
        // Canonical on both sides. Compared raw, opening the already-open
        // `/tmp/v/a.md` as `/private/tmp/v/a.md` (or via a canonical `row.path`)
        // produced a SECOND session on the same file, each with its own mtime
        // baseline and its own debounced autosave racing the other.
        if let existing = tabs.first(where: { Self.pathKey($0.url) == Self.pathKey(url) }) {
            touch(existing)
            selectedTab = existing
            if recordingHistory { recordVisit(existing.url) }
            return
        }
        do {
            let session = try DocumentSession.open(url: url, coordinator: coordinator)
            tabs.append(session)
            selectedTab = session
            openError = nil
            if recordingHistory { recordVisit(session.url) }
            evictColdSessions()
        } catch {
            openError = (url, error)
        }
    }

    public func selectTab(_ session: DocumentSession) {
        touch(session)
        selectedTab = session
        recordVisit(session.url)
    }

    // MARK: - History

    /// Documents visited, oldest first — the back/forward stack.
    ///
    /// Replaces the tab strip's job of "get me back to what I was just
    /// looking at". In a vault, that is almost always a LINEAR trail (follow a
    /// link, read, come back), which a stack models exactly and a strip models
    /// only by accident of ordering.
    public var history: [URL] { pane.history }
    /// Where in `history` the open document sits. Nil before anything opens.
    public var historyIndex: Int? { pane.historyIndex }

    /// Closing does NOT discard unsaved edits: `DocumentSession` autosaves on a
    /// 500ms debounce, so a tab closed immediately after a keystroke could
    /// otherwise lose that edit. A read-only session can never be dirty (see
    /// `DocumentSession.markChanged`), so this only ever writes a document the
    /// engine can actually save.
    ///
    /// A `false` return means the document still has unsaved work and is
    /// still open: the tab was NOT removed, its selection was left
    /// untouched, and the session's own `conflict` / `lastSaveError` flags
    /// already explain why (a real save failure, or an external change).
    /// Callers must not assume a `false` return means the tab is gone.
    /// Pass `force: true` to remove the tab regardless — the user explicitly
    /// choosing to discard.
    @discardableResult
    public func closeTab(_ session: DocumentSession, force: Bool = false) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0 === session }) else { return false }
        if session.isDirty && !session.isReadOnly {
            do {
                try session.saveNow()
            } catch {
                if !force { return false }
            }
        }
        // Past this point the tab IS being removed, on both the normal and the
        // forced path, so the debounced autosave must be disarmed: it would
        // otherwise fire into a document nobody owns any more — writing back
        // edits the user chose to discard, or resurrecting a file a delete is
        // about to unlink.
        session.cancelPendingSave()
        tabs.remove(at: idx)
        // A second pane whose document just closed has nothing left to show,
        // so the split collapses — ⌘W closes a DOCUMENT (decision 2.3), and
        // the layout following it is the consequence rather than a second
        // meaning for the key.
        if focusIsSecondary, secondaryPane?.session === session {
            closeSecondaryPane()
            return true
        }
        if selectedTab === session {
            // The most recently used document, which `tabs`' LRU ordering puts
            // last. This used to pick the closed tab's NEIGHBOUR, which was
            // right when `tabs` was a visible strip (the eye expects the gap to
            // close sideways) and is wrong now that it is a cache: adjacency in
            // a cache is meaningless, and "what I was looking at before this
            // one" is the only answer a user can predict.
            selectedTab = tabs.last
        }
        return true
    }
}
