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
        // Every transcluded embed's measured height is a function of THIS
        // width — see `TransclusionMeasurement`. A stale height self-corrects
        // on the very next render (the geometry travels with the number), so
        // dropping it here is purely an optimisation: it stops the next pass
        // from carrying around a measurement it already knows it cannot use,
        // rather than discovering that one geometry check at a time.
        transclusionCache.invalidateMeasurements()
    }

    // MARK: - Live transclusion updates

    /// The PRIMARY live-update path: called with NO editor interaction
    /// whatsoever, whenever `EditorContext.registerExternalChangeHandler`'s
    /// sink fires for `url` — a watcher-driven vault rescan (an edit made in
    /// Obsidian, or any external tool), or another split pane saving the
    /// SAME file. See `MarkdownEditor.Coordinator.externalChangeToken`'s doc
    /// comment for why this exists as a push rather than relying on
    /// `detectExternalTransclusionChanges()` alone (fix round 1, Critical #1
    /// — a poll driven only by `applyStyles()` never fires while the window
    /// sits idle, so an Obsidian edit would sit invisible until the user
    /// typed a character).
    ///
    /// `cache.invalidate(path:)` is called UNCONDITIONALLY — it is a cheap
    /// no-op for a path with no entries, and computing the membership check
    /// twice (once to guard this, once to guard the render below) would cost
    /// more than the no-op it would be guarding.
    ///
    /// `renderStyles()` is NOT unconditional (fix round 2, Important #4): it
    /// is a full render pass (span apply, `revealIndex` rebuild, embed index
    /// rebuild, writing-direction scan, embed application, block-background
    /// refresh) — cheap for `invalidate(path:)` to be a no-op over, but not
    /// cheap to run unfiltered. Every open editor registers a handler
    /// against the SAME sink, and `VaultIndexCoordinator.indexDocument`
    /// fires it on every save of ANY document — so an unfiltered render here
    /// meant every open pane paid for a full render on every save anywhere
    /// in the vault, whether or not it embedded the saved file. Filtered by
    /// `isEmbeddedTarget(url)`, a cheap scan of the CURRENT spans with no
    /// filesystem access — no `stat`, unlike the mtime backstop below — so
    /// it costs far less than the render it decides whether to run.
    func handleExternalChange(to url: URL) {
        transclusionCache.invalidate(path: url)
        guard isEmbeddedTarget(url) else { return }
        // `applyStyles()`'s `isRenderStale` guard has no way to know a
        // DIFFERENT file changed, so it is bypassed by forcing a render
        // directly — the render itself re-derives `transclusionRegions` from
        // the (now-invalidated, so freshly re-resolved) cache and repaints,
        // exactly what Task 6's drain invariant requires.
        renderStyles()
    }

    /// Whether `url` is one of THIS document's currently-transcluded targets
    /// — a scan of `styleCache.spans` for `.embed` spans that resolve to a
    /// `.transclusion` matching `url`. No filesystem access: this exists to
    /// be cheap enough to run before deciding whether a real render is
    /// warranted, not to detect whether the file's content actually changed
    /// (that is `TransclusionKey`'s mtime, and the backstop's `stat` calls).
    private func isEmbeddedTarget(_ url: URL) -> Bool {
        for span in styleCache.spans {
            guard case .embed(let target, _) = span.kind else { continue }
            guard case .transclusion(let resolved) = EmbedRendering.kind(for: resolveEmbedTarget(target))
            else { continue }
            if resolved == url { return true }
        }
        return false
    }

    /// Compares every currently-embedded transclusion target's on-disk mtime
    /// against what the last check saw, and invalidates the cache (and forces
    /// a render) for any that changed.
    ///
    /// The BACKSTOP, not the primary mechanism — see
    /// `MarkdownEditor.Coordinator.embeddedTargetMTimes`'s doc comment.
    /// Deliberately NOT called from `applyStyles()` (fix round 1, Important
    /// #2): that runs once per keystroke, and stat-ing every embedded
    /// target's file on every character typed is real, measured,
    /// synchronous main-actor filesystem work the typing-path performance
    /// gates do not cover. Called instead from `makeNSView` (on open) and
    /// `onBecomeFirstResponder` (on focus) — an idle document that never
    /// regains focus relies entirely on the watcher push in
    /// `handleExternalChange(to:)` above, which is the common case this
    /// backstop is not needed for.
    ///
    /// Distinct URLs are stat'd once per call, not once per embed SPAN
    /// occurrence — a target embedded five times in one document costs one
    /// `stat`, not five.
    func detectExternalTransclusionChanges() {
        var stattedThisPass: [URL: Date] = [:]
        var seen: Set<URL> = []
        var changedTargets: [URL] = []
        for span in styleCache.spans {
            guard case .embed(let target, _) = span.kind else { continue }
            guard case .transclusion(let url) = EmbedRendering.kind(for: resolveEmbedTarget(target))
            else { continue }
            seen.insert(url)
            guard stattedThisPass[url] == nil else { continue }
            externalChangeStatCalls += 1
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attributes?[.modificationDate] as? Date) ?? .distantPast
            stattedThisPass[url] = mtime
            if let known = embeddedTargetMTimes[url], known != mtime {
                changedTargets.append(url)
            }
            embeddedTargetMTimes[url] = mtime
        }
        // Targets no longer embedded (the `![[…]]` was removed or edited to
        // point elsewhere) are dropped, so a later re-embed of the same path
        // is compared against a fresh baseline rather than one from before it
        // was removed.
        if embeddedTargetMTimes.count != seen.count {
            embeddedTargetMTimes = embeddedTargetMTimes.filter { seen.contains($0.key) }
        }
        for url in changedTargets { transclusionCache.invalidate(path: url) }
        if !changedTargets.isEmpty { renderStyles() }
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
