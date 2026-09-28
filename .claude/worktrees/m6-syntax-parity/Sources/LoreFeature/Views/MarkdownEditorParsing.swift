import AppKit

// Container geometry and the off-actor parse pipeline for `MarkdownEditor`.
// Moved out of `MarkdownEditorReveal.swift`, which was over the 500-line
// cap — that file keeps the reveal/render machinery (`applyStyles`,
// `renderStyles`, `revealForSelectionChange`, `restyleBlock`); this one is
// everything downstream of "the text container's width changed" or "the
// debounce fired".
extension MarkdownEditor.Coordinator {

    // MARK: - Container geometry

    /// Re-applies both the inset and the container's own width for a view
    /// `width` points wide.
    ///
    /// Called on every width change, because BOTH are a function of the
    /// view's width: the inset would keep the margins it was born with and
    /// drift off-centre as the window resizes, and — the bug this method used
    /// to have — the container's width would stay pinned at the theme's
    /// measure regardless of how narrow the pane got, leaving text wider than
    /// the visible view with no horizontal scroller to reach it. The two are
    /// applied together, from the one function that owns both
    /// (`containerInset`/`containerWidth`), so they cannot drift apart again.
    func applyContainerGeometry(forWidth width: CGFloat) {
        guard let tv = textView else { return }
        let theme = MarkdownTheme(tokens: tokens, settings: settings)
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: width, theme: theme)
        let containerWidth = MarkdownEditorLayout.containerWidth(forViewWidth: width, theme: theme)
        let insetChanged = tv.textContainerInset != inset
        let widthChanged = tv.textContainer?.size.width != containerWidth
        guard insetChanged || widthChanged else { return }
        tv.textContainerInset = inset
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        // The drawn decoration is positioned from the container, so it has to
        // be repainted when the container moves.
        tv.needsDisplay = true
    }

    // MARK: - Parsing

    /// Re-arms the debounce. Only its firing parses, so a burst of typing
    /// costs one parse rather than one per character.
    func scheduleParse() {
        parseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.parseDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.parseNow() }
        }
        parseTimer = timer
        // `.common` so the parse still lands while the user is scrolling or
        // holding a menu open, rather than after they stop.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Parses OFF the main actor and applies the result back on it.
    ///
    /// This used to be a synchronous parse on the main actor, called from a
    /// main-run-loop timer. On a large note that is measured in whole
    /// seconds, and a main-actor second is not lag — it is a beachball, once
    /// per pause in typing. The parse itself is pure (`derive` touches no
    /// AppKit and no editor state), so the only thing that must stay on the
    /// main actor is applying the answer.
    ///
    /// Two guards keep a slow parse from styling the wrong characters:
    ///
    /// 1. `generation` — a newer parse having been started makes this one's
    ///    result garbage, even if the text looks right.
    /// 2. the SNAPSHOT check — the spans index `snapshot` and nothing else,
    ///    so they are installed only if the view still holds exactly that
    ///    string. This is the same identity rule `describes(_:)` encodes,
    ///    applied across the hop.
    ///
    /// When the text HAS moved on, nothing is applied and nothing is
    /// re-armed here: the edit that moved it went through `textDidChange`,
    /// which armed the debounce already.
    func parseNow() {
        // Invalidated, not merely dropped: `applyStyles` calls this DIRECTLY on
        // the open path, so there may be a debounce timer still armed, and a
        // released-but-live `Timer` would fire into a parse that has already
        // been launched.
        parseTimer?.invalidate()
        parseTimer = nil
        guard let tv = textView else { return }
        let snapshot = tv.string
        guard styleCache.isStale || !styleCache.describes(snapshot) else { return }
        parseGeneration += 1
        let generation = parseGeneration
        Task.detached(priority: .userInitiated) {
            let derived = MarkdownStyleCache.derive(snapshot)
            await MainActor.run { [weak self] in
                self?.applyParsed(derived, of: snapshot, generation: generation)
            }
        }
    }

    private func applyParsed(_ derived: MarkdownStyleCache.Derived,
                             of snapshot: String, generation: Int) {
        guard generation == parseGeneration,
              let tv = textView, tv.string == snapshot else { return }
        styleCache.adopt(derived, for: snapshot)
        renderStyles()
    }

    /// In viewport mode the styled range follows the scroll, so scrolling
    /// has to re-render — but only when the window actually moved, since
    /// this fires continuously during a drag.
    func restyleForViewportIfNeeded() {
        guard styleCache.isOverViewportCap, let tv = textView else { return }
        let window = MarkdownStyleRenderer.viewportWindow(of: tv)
        if let last = lastViewportWindow, NSEqualRanges(last, window) { return }
        renderStyles()
    }
}
