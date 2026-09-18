import SwiftUI
import AppKit
import AinkradAppKit

// The `NSViewRepresentable` lifecycle for `MarkdownEditor` — building the
// `NSScrollView`/`LinkTextView` pair, wiring their callbacks to the
// `Coordinator`, and tearing them down. Moved out of `MarkdownEditor.swift`
// to keep that file to the type's declared surface (properties, init,
// `Coordinator`); this file is the AppKit object graph those properties
// describe.
extension MarkdownEditor {
    public func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than via `NSTextView.scrollableTextView()`
        // because the text view has to be a subclass — Cmd-click detection has
        // no delegate hook, only `mouseDown(with:)`.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        // Markdown source, not prose. macOS's automatic substitutions turn `"`
        // into typographic quotes and `--` into an em dash, which corrupts the
        // very characters the parser reads — and, for `"`, gives the key two
        // owners, since `MarkdownEditing.pairs` also auto-pairs it. Which one
        // won depended on a System Settings toggle; now neither does.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // The system find bar. `usesFindBar` puts it inside the scroll view
        // rather than in a floating panel, which is what keeps it attached to
        // the document it is searching when several are open.
        //
        // Safe alongside the markdown styling passes: find highlighting is
        // drawn with the layout manager's TEMPORARY attributes, while
        // `MarkdownStyleRendering` writes real attributes into the text
        // storage. The two never touch the same storage, so a restyle on the
        // next keystroke cannot erase the highlights — which is precisely the
        // collision that would have made this unusable.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        // Margins and measure come from the theme, and are both a function of
        // the view's width — see `MarkdownEditorLayout`. Set once here for the
        // initial size, then kept in sync by `onWidthChange` via
        // `applyContainerGeometry`, which owns both together so they cannot
        // drift apart on resize.
        let initialTheme = MarkdownTheme(tokens: tokens, settings: settings)
        tv.textContainerInset = MarkdownEditorLayout.containerInset(
            forViewWidth: tv.bounds.width, theme: initialTheme)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(
            width: MarkdownEditorLayout.containerWidth(forViewWidth: tv.bounds.width,
                                                        theme: initialTheme),
            height: .greatestFiniteMagnitude)
        tv.onWidthChange = { [weak coordinator = context.coordinator] width in
            coordinator?.applyContainerGeometry(forWidth: width)
        }
        tv.onCommandClick = { [weak coordinator = context.coordinator] index in
            coordinator?.openLink(atUTF16: index) ?? false
        }
        tv.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handlePlainClick(atUTF16: index) ?? false
        }
        tv.onEmbedClick = { [weak coordinator = context.coordinator] index, optionHeld in
            coordinator?.openTransclusion(atUTF16: index, beside: optionHeld) ?? false
        }
        // Losing first responder INSIDE the same window — clicking the title
        // field, the sidebar, another pane — is not covered by
        // `hidesOnDeactivate`, and would otherwise leave a `.popUpMenu`-level
        // panel floating over the UI. `textDidEndEditing` covers the common
        // routes; this covers the rest (focus moved by keyboard, by the shell,
        // or to a control that does not end editing).
        tv.onResignFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.completionPanel.hide()
            // Same rule the completion panel follows: a floating window that
            // outlives its reason to exist is the failure mode here.
            coordinator?.hoverChanged(to: nil)
            // `false`, not a live read: at this point `NSWindow` has not yet
            // reassigned first responder away from `tv` (see
            // `revealForSelectionChange`'s doc comment), so a live read would
            // still answer "focused" and never hide the markers.
            coordinator?.revealForSelectionChange(forcedFocus: false)
        }
        tv.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.revealForSelectionChange(forcedFocus: true)
            // The on-focus half of the mtime backstop — see
            // `detectExternalTransclusionChanges()`'s doc comment. The
            // watcher push (`handleExternalChange(to:)`) is the primary
            // mechanism; this catches what it can miss (a same-second edit
            // on a coarse-mtime filesystem) the moment the user comes back
            // to this pane, without paying for it on every keystroke.
            coordinator?.detectExternalTransclusionChanges()
        }
        tv.onPasteImage = { [weak coordinator = context.coordinator] data, name in
            coordinator?.insertAttachment(fromPastedImage: data, name: name) ?? false
        }
        tv.onDropFileURLs = { [weak coordinator = context.coordinator] urls in
            coordinator?.insertAttachments(fromDroppedFiles: urls) ?? false
        }
        tv.onHoverIndex = { [weak coordinator = context.coordinator] index in
            coordinator?.hoverChanged(to: index)
        }
        // See `LinkTextView`'s doc comment on why this is registered here,
        // post-construction, rather than in an overridden initializer.
        tv.registerForDraggedTypes([.fileURL])
        scroll.documentView = tv

        // The caret moves under the list when the document scrolls, so the list
        // has to follow it.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scroll.contentView)

        context.coordinator.textView = tv
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.resolveEmbedTarget = resolveEmbedTarget ?? { _ in nil }
        // The SAME resolver embeds use, so a hover and an embed cannot
        // disagree about what a name points at.
        context.coordinator.resolveHoverTarget = resolveEmbedTarget
        // The live-transclusion push (fix round 1, Critical #1): rides the
        // SAME sink the index already uses for a watcher event or another
        // pane's save, rather than a second watcher. `nil` — an engine or
        // test with no vault behind it — means live updates never fire,
        // which degrades to exactly the poll-only backstop this coordinator
        // already runs on-appear/on-focus.
        context.coordinator.unregisterExternalChangeHandler = unregisterExternalChangeHandler
        if let registerExternalChangeHandler {
            context.coordinator.externalChangeToken =
                registerExternalChangeHandler { [weak coordinator = context.coordinator] url in
                    coordinator?.handleExternalChange(to: url)
                }
        }
        context.coordinator.createLinkedNote = createLinkedNote
        context.coordinator.headingCompletions = headingCompletions
        context.coordinator.writePastedImage = writePastedImage
        context.coordinator.writeDroppedFile = writeDroppedFile
        context.coordinator.stylingNotice = Self.addStylingNotice(to: scroll, tokens: tokens)
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onTagClick = onTagClick
        tv.string = text
        context.coordinator.applyStyles()
        // The on-open half of the mtime backstop — see
        // `detectExternalTransclusionChanges()`'s doc comment. AFTER
        // `applyStyles()`, whose render pass is what populates
        // `styleCache.spans` (and so the embed targets this walks) in the
        // first place — a call before it would find nothing to check yet.
        context.coordinator.detectExternalTransclusionChanges()
        // The text view exists now, so the closures that need it (cut, copy,
        // the formatting actions) can be built once, here, rather than
        // re-derived on every menu presentation. Deferred to the next
        // run-loop turn, same as `scrollTarget` above and for the same
        // reason: `makeNSView` runs INSIDE a SwiftUI view-update pass, and
        // writing a `@State` from there — which is what this callback does —
        // is the "modifying state during view update" trap: it produces the
        // purple runtime warning and leaves the first render's menu actions
        // at `.noop`.
        if let registerMenuActions {
            let actions = MarkdownEditorMenuActions.build(for: tv)
            DispatchQueue.main.async { registerMenuActions(actions) }
        }
        return scroll
    }

    /// A floating label, hidden unless the document is over the hard cap. Added
    /// to the SCROLL view rather than the text view so it stays put while the
    /// document scrolls under it, and so it never becomes part of the text.
    private static func addStylingNotice(to scroll: NSScrollView,
                                  tokens: HostThemeTokens) -> NSTextField {
        let notice = NSTextField(labelWithString:
            "Styling off — document over \(MarkdownDocumentModel.stylingHardCap / (1024 * 1024)) MB")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = NSColor(tokens.accentSecondary)
        notice.isHidden = true
        notice.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            notice.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6)
        ])
        return notice
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.completions = completions
        context.coordinator.tagCompletions = tagCompletions
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onOpenLinkBeside = onOpenLinkBeside
        context.coordinator.onTagClick = onTagClick
        context.coordinator.resolveEmbedTarget = resolveEmbedTarget ?? { _ in nil }
        context.coordinator.linkTarget = linkTarget
        context.coordinator.createLinkedNote = createLinkedNote
        context.coordinator.headingCompletions = headingCompletions
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.writePastedImage = writePastedImage
        context.coordinator.writeDroppedFile = writeDroppedFile
        context.coordinator.onSelectionChange = onSelectionChange
        if tv.string != text { tv.string = text; context.coordinator.applyStyles() }
        tv.backgroundColor = NSColor(tokens.background)
        tv.insertionPointColor = NSColor(tokens.accentPrimary)
        context.coordinator.tokens = tokens
        // Display settings changing must re-lay out the document the reader is
        // ALREADY looking at — a font size that only applies to the next
        // document opened reads as a broken setting. The geometry is
        // re-applied explicitly because container inset and width are a
        // function of the theme AND the view width, and `applyStyles` alone
        // does not touch them (see `applyContainerGeometry`, which owns both
        // together so they cannot drift apart).
        if context.coordinator.settings != settings {
            context.coordinator.settings = settings
            context.coordinator.applyContainerGeometry(forWidth: tv.bounds.width)
            // Called explicitly, not left to `applyContainerGeometry`'s own
            // call: that one only fires when the CONTAINER'S width or inset
            // actually moved, but `bodySize` (density) can change under a
            // settings edit — a text-size or density change — without either
            // one moving. Every transcluded embed's measured height is a
            // function of `bodySize`/`lineHeightMultiple` too (see
            // `TransclusionMeasurement`), so it must drop on ANY settings
            // change, not only the ones that happen to move the geometry.
            context.coordinator.transclusionCache.invalidateMeasurements()
            // `applyStyles()` below is a no-op unless `isRenderStale` says the
            // ON-SCREEN render is out of date, and that guard compares only
            // `tokens` and the text — never `settings` (see
            // `MarkdownEditorEditPath.isRenderStale`). Without this, a
            // settings-only change (e.g. the "Render tags as chips" toggle,
            // or text size / line width) would update the geometry above but
            // leave every span's ATTRIBUTES exactly as `MarkdownTheme`
            // computed them under the OLD settings, until some unrelated
            // edit or token change happened to invalidate the cache. Forcing
            // the snapshot stale here is what makes a settings change apply
            // to the document already on screen, not only the next one
            // opened.
            context.coordinator.renderedSnapshot = nil
        }
        context.coordinator.applyStyles()
        if let offset = scrollTarget.wrappedValue {
            context.coordinator.scrollToOffset(offset)
            // Scheduled, not written synchronously: `updateNSView` is inside a
            // view-update pass, and writing a `Binding` from there is the
            // "modifying state during view update" trap.
            DispatchQueue.main.async { scrollTarget.wrappedValue = nil }
        }
        // Deliberately no completion recompute here: `updateNSView` runs on
        // every ancestor redraw (theme change, banner appearing, window
        // resize), and querying the index on a redraw is both wasted work and
        // a way to make a popup appear when the user did not type.
    }

    /// Tearing the editor down must take the floating panel with it — this is
    /// the path that fires on a tab close and on a document switch (the pane
    /// re-`id`s the editor, so the old one is dismantled).
    ///
    /// `assumeIsolated` only where it is true. AppKit always dismantles on the
    /// main thread, but asserting that would turn a wrong assumption into a
    /// crash in the user's editor; off the main thread this degrades to a hop
    /// instead.
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { coordinator.tearDown() }
        } else {
            Task { @MainActor in coordinator.tearDown() }
        }
    }
}
