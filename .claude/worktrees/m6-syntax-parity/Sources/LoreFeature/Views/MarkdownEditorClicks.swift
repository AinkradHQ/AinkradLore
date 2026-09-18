import AppKit

/// `NSTextView` that reports the two clicks the editor gives meaning to.
///
/// Moved out of `MarkdownEditor.swift` when the checkbox toggle was added:
/// that file was 489 of its 500 permitted lines and is about the editor's
/// AppKit wiring, while this one is about what a click MEANS.
///
/// Both hooks share one scheme, deliberately, rather than a second one being
/// invented for the checkbox: a handler receives the clicked UTF-16 offset and
/// reports whether it consumed the click; a `false` — or no handler at all —
/// falls straight through to `super.mouseDown`, so the caret still lands
/// exactly where the user clicked. Nothing here can swallow a click it did not
/// positively recognise.
///
/// Cmd-click for links, plain click for checkboxes, and that asymmetry is
/// intentional. Inside an editor the primary meaning of a click is "put the
/// caret here", so hijacking a plain click on a `[[…]]` span would make link
/// text the one run of characters the user cannot click into to fix a typo —
/// and a link span is long. A checkbox marker is ONE character wide, sits
/// between two brackets that remain freely clickable, and is the affordance
/// every markdown editor on this platform activates with a plain click. The
/// caret can still be placed on either side of the `[ ]`; only the interior
/// boundaries are claimed.
final class LinkTextView: NSTextView {
    /// Receives the clicked UTF-16 offset and reports whether it opened a link.
    /// The Bool matters: a Cmd-click that hits no link — or a document with no
    /// link handler at all, i.e. plain text — must fall through to AppKit so
    /// the caret still lands where the user clicked.
    var onCommandClick: (@MainActor (Int) -> Bool)?
    /// Receives the clicked UTF-16 offset of an unmodified single click and
    /// reports whether it toggled a task checkbox. Same fall-through contract.
    var onPlainClick: (@MainActor (Int) -> Bool)?
    /// Fires whenever focus leaves this view, including the routes that do not
    /// produce a `textDidEndEditing`.
    var onResignFirstResponder: (@MainActor () -> Void)?
    /// Fires whenever this view GAINS focus. `textDidBeginEditing` is not a
    /// substitute — `NSText` posts that only on the first EDIT after becoming
    /// first responder, not on becoming it, so clicking back into the editor
    /// without typing anything fired nothing at all until this was added.
    var onBecomeFirstResponder: (@MainActor () -> Void)?
    /// Fires when the view's WIDTH changes, which is the only input to where
    /// the text column sits — see `MarkdownEditorLayout`. Height changes are
    /// ignored, and a height change is what most `setFrameSize` calls are: the
    /// view grows as the document does.
    var onWidthChange: (@MainActor (CGFloat) -> Void)?
    private var lastNotifiedWidth: CGFloat = -1
    /// Receives pasted image bytes and a generated filename, and reports
    /// whether it was handled (written as an attachment and inserted).
    /// `false` — or no handler — falls through to AppKit's own `paste(_:)`,
    /// same fall-through contract `onCommandClick`/`onPlainClick` use.
    var onPasteImage: (@MainActor (Data, String) -> Bool)?
    /// Receives the file URLs from a Finder drop and reports whether they
    /// were handled (copied in and inserted). Same fall-through contract.
    var onDropFileURLs: (@MainActor ([URL]) -> Bool)?
    /// Reports the UTF-16 index under the pointer as it moves, and nil when it
    /// leaves. Drives the link hover preview.
    ///
    /// Reported RAW, on every move: deciding whether the index is inside a
    /// link, and whether the pointer has rested long enough to mean it, are
    /// both the coordinator's job — this view knows nothing about links.
    var onHoverIndex: (@MainActor (Int?) -> Void)?

    /// The tracking area that makes `mouseMoved` fire at all.
    ///
    /// Rebuilt on every bounds change: a tracking area holds a fixed rect, so
    /// a stale one after a resize covers the wrong part of a text view that
    /// grows with its document — which is most of the time here.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        onHoverIndex?(characterIndexForInsertion(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverIndex?(nil)
    }

    /// File URLs are registered by `MarkdownEditor.makeNSView` right after
    /// construction, not here: `NSTextView` is an Objective-C class, and
    /// overriding its designated initializer to do this would drop the
    /// inherited `NSTextView(frame:)` convenience initializer that
    /// `makeNSView` actually calls. A plain (`isRichText == false`) text
    /// view does not accept a Finder drag by default the way a rich text
    /// view does, and the default rich-text behaviour (embedding the image
    /// as an `NSTextAttachment`) is not what a MARKDOWN source file wants
    /// anyway — Task 9 wants a `![[name]]` embed, not an attachment run.

    /// The resize hook. `updateNSView` is not one: SwiftUI does not re-run it
    /// for every frame of a live window resize, so a column centred only there
    /// would drift off-centre while the user drags the window edge.
    ///
    /// Cannot recurse: the handler sets `textContainerInset`, never the frame,
    /// and any frame change that follows carries the same width — which this
    /// guard drops.
    /// The responder-chain entry point for formatting shortcuts.
    ///
    /// `@objc` and tag-driven because `NSApp.sendAction(_:to:from:)` with a
    /// nil target is the only way the shell can reach "whichever text view is
    /// focused" without holding a reference to it — see `LoreFormatting`.
    /// Reads the action off the sender's tag, exactly as
    /// `performFindPanelAction(_:)` does.
    @objc func loreApplyFormat(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let action = LoreFormatAction(rawValue: item.tag) else { return }
        LoreFormatting.apply(action, to: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - lastNotifiedWidth) > 0.5 else { return }
        lastNotifiedWidth = newSize.width
        onWidthChange?(newSize.width)
    }

    /// Code panels and blockquote bars to paint BEHIND the text. Set by the
    /// coordinator whenever styles are applied; see `MarkdownBlockBackgrounds`
    /// for why these are drawn rather than attributed.
    var blockBackgrounds: [MarkdownBlockBackgrounds.Region] = [] {
        didSet { if blockBackgrounds != oldValue { needsDisplay = true } }
    }
    /// The colours those regions are painted in, from the host theme.
    var blockBackgroundPalette: MarkdownBlockBackgrounds.Palette? {
        didSet { if blockBackgroundPalette != oldValue { needsDisplay = true } }
    }

    /// Resolved image embeds to paint where their (collapsed) source text
    /// sits — see `MarkdownEditor.Coordinator.applyEmbeds`. Drawn in
    /// `drawBackground`, same as `blockBackgrounds`: the embed's paragraph
    /// style already reserves the vertical room, so drawing before the text
    /// layer is enough — the collapsed source glyphs are visually empty and
    /// nothing else occupies that rect.
    var embedImages: [MarkdownEditor.Coordinator.EmbedImageRegion] = [] {
        didSet { if embedImages != oldValue { needsDisplay = true } }
    }

    /// The one drawing hook. `super` first, so the view's own background is
    /// down before the block decoration goes on top of it and the text on top
    /// of that.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let palette = blockBackgroundPalette {
            MarkdownBlockBackgrounds.draw(blockBackgrounds, palette: palette,
                                          in: self, dirtyRect: rect)
        }
        drawEmbedImages(in: rect)
    }

    /// Positions each region from its character rect at draw time, rather
    /// than caching a rect computed earlier: scrolling and resizing move
    /// glyph rects without changing the ranges `applyEmbeds` recorded them
    /// for.
    ///
    /// `firstRect(forCharacterRange:actualRange:)`, not `layoutManager`:
    /// `MarkdownStyleRenderer.viewportWindow` already documents why reading
    /// `layoutManager` on a TextKit 2 view silently downgrades the whole view
    /// to TextKit 1, and `caretRect(in:)` in `MarkdownEditor.swift` uses this
    /// same version-agnostic API for the identical reason. It answers in
    /// SCREEN coordinates, so the result is converted back through the
    /// window before comparing against `dirtyRect`, which is in this view's
    /// own coordinate space.
    private func drawEmbedImages(in dirtyRect: NSRect) {
        guard !embedImages.isEmpty, let window else { return }
        for region in embedImages {
            let screenRect = firstRect(forCharacterRange: region.range, actualRange: nil)
            guard screenRect.width.isFinite, screenRect.height.isFinite else { continue }
            let windowRect = window.convertFromScreen(screenRect)
            let rect = convert(windowRect, from: nil)
            guard rect.intersects(dirtyRect) else { continue }
            // Positioned by `EmbedGeometry.drawRect`, NOT by `rect.minX` —
            // for a collapsed, near-zero-width source run, TextKit places
            // that run against the LINE'S END margin, which for an RTL
            // paragraph is the right edge, not the left. Deriving the
            // origin from the paragraph's own writing direction and the
            // container's usable width instead is correct for both
            // directions and clamps an over-wide image to never overflow
            // either edge. `rect.minY` is still trusted — the diagnosed bug
            // is horizontal only.
            //
            // `EmbedGeometry.drawRect` answers in CONTAINER-local x.
            // `textContainerOrigin.x`, NOT `textContainerInset.width`,
            // translates that into this view's own coordinate space — see
            // `MarkdownBlockBackgrounds.columnX`'s doc comment: the inset
            // only happens to agree with the container's real origin while
            // the column is flush against the view edge, and
            // `MarkdownEditorLayout` centres a capped-width column, so on a
            // wide window the two part company and every embed image would
            // detach sideways from the code panels/quote bars that already
            // use `textContainerOrigin.x`. `lineFragmentPadding` (AppKit's
            // own 5pt default, never zeroed here) is passed through too —
            // fix round 1, Important 2 — because the OLD `rect.minX` code
            // included it for free (a glyph rect already accounts for line
            // fragment padding) and dropping it would shift every
            // previously-working top-level LTR embed 5pt left of where it
            // used to sit.
            let containerWidth = textContainer?.size.width ?? bounds.width
            let padding = textContainer?.lineFragmentPadding ?? 0
            let local = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                               writingDirection: region.writingDirection,
                                               indent: region.indent,
                                               lineFragmentPadding: padding, imageSize: region.size)
            let drawRect = NSRect(x: local.origin.x + textContainerOrigin.x, y: rect.minY,
                                  width: region.size.width, height: region.size.height)
            // `draw(in:)` (the single-rect convenience) does NOT respect a
            // flipped coordinate system, and `NSTextView` IS flipped — fix
            // round 1, Important 5. Without `respectFlipped: true` every
            // inline embed image renders upside down. `.sourceOver` and
            // `fraction: 1` are the same defaults `draw(in:)` uses; only the
            // flip behaviour changes.
            region.image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                              fraction: 1.0, respectFlipped: true, hints: nil)
        }
    }

    /// Modifiers that mean the user is doing something other than "activate
    /// what is under the pointer": extending a selection, opening a context
    /// menu, or whatever the host binds Option-click to.
    private static let selectionModifiers: NSEvent.ModifierFlags =
        [.shift, .option, .control, .command]

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            if onCommandClick?(characterIndexForInsertion(at: point)) == true { return }
            super.mouseDown(with: event)
            return
        }
        // Single, unmodified click only. A double-click is select-the-word and
        // a drag starts from a click too — neither should flip a checkbox.
        if event.clickCount == 1,
           event.modifierFlags.intersection(Self.selectionModifiers).isEmpty,
           onPlainClick?(characterIndexForInsertion(at: point)) == true { return }
        super.mouseDown(with: event)
    }

    // MARK: - Typing affordances

    /// Auto-pairing. `insertText` rather than a `doCommandBy` arm because
    /// ordinary characters never reach `doCommandBy`. Multi-character input —
    /// a paste, or an IME committing a phrase — is filtered out inside
    /// `MarkdownEditorTyping.typed`, so composition is untouched.
    ///
    /// Two inputs must never be auto-paired, because
    /// `MarkdownEditorTyping.typed` rebuilds the whole string around
    /// `selectedRange()` and knows nothing about either:
    ///
    /// - MARKED TEXT. An IME committing a single pair character (`[`, `(`, a
    ///   backtick, a quote) mid-composition would have its in-progress marked
    ///   range replaced with no `unmarkText`, leaving the input session
    ///   describing text that no longer exists.
    /// - An explicit `replacementRange`. Autocorrect, dictation and text
    ///   substitution target a range that is NOT the selection, so pairing
    ///   there inserts the pair in the wrong place and drops the correction.
    ///
    /// A `replacementRange` EQUAL to the current selection is ordinary typing
    /// described redundantly, and is allowed — refusing it would disable
    /// auto-pairing wherever AppKit chooses to spell the range out.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let targetsSelection = replacementRange.location == NSNotFound
            || replacementRange == selectedRange()
        if targetsSelection, !hasMarkedText() {
            let typed = (string as? String) ?? (string as? NSAttributedString)?.string
            if let typed, MarkdownEditorTyping.typed(typed, in: self) { return }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // Paste and drop of images/files (`paste(_:)`, `draggingEntered`,
    // `performDragOperation`, and the pasteboard-classification helpers they
    // share) live in `MarkdownEditorAttachments.swift`.

    /// Cmd-B / Cmd-I. Handled here rather than through `toggleBoldface(_:)`
    /// because those selectors arrive only from a Font menu, which a plugin's
    /// host window need not have.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, window?.firstResponder === self {
            switch event.charactersIgnoringModifiers {
            case "b": MarkdownEditorTyping.toggleWrap(in: self, with: "**"); return true
            case "i": MarkdownEditorTyping.toggleWrap(in: self, with: "*"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension MarkdownEditor.Coordinator {

    /// Flips the task checkbox whose marker the click landed in, and reports
    /// whether it did. `false` means "not mine" and the click proceeds to
    /// AppKit untouched.
    ///
    /// THE EDIT PATH. The toggle is a one-character `replaceCharacters`
    /// bracketed by `shouldChangeText(in:replacementString:)` and
    /// `didChangeText()` — the identical pair `insert(_ row:)` uses for a
    /// picked completion, and the pair AppKit itself uses for a keystroke. That
    /// bracketing is what makes the toggle:
    ///
    /// - one undo step (`allowsUndo` + `shouldChangeText` registers it);
    /// - a `textDidChange` delegate call, which writes `text.wrappedValue` and
    ///   so drives `MarkdownDocumentEditor`'s `.onChange(of: body_)` →
    ///   `engine.note.body = body_` → `ctx.onChange()` → `session.markChanged()`
    ///   → `isDirty = true` and the 500 ms debounced autosave, which calls
    ///   `saveNow()` and therefore passes the mtime external-change guard;
    /// - a `shouldChangeTextIn` delegate call, which records `pendingEdit` so
    ///   the style cache SHIFTS rather than flashing the note back to plain
    ///   text for a debounce.
    ///
    /// Nothing here writes a file and nothing calls `saveNow()`. A toggle is
    /// indistinguishable from the user typing the character themselves, which
    /// is the only way it inherits every data-loss guard M1 and M2 built.
    ///
    /// THE OFFSET GUARD. `styleCache.spans` may lag the live text by up to one
    /// styling debounce — they are shifted between parses, not re-derived — so
    /// a cached span's offset is a CANDIDATE, never an authority.
    /// `TaskCheckbox.markerRange(forBracketSpan:in:)` re-reads `tv.string` at
    /// that offset and yields a range only if a real `[` marker `]` still sits
    /// there. When it does not, the click is dropped and falls through to
    /// ordinary caret placement: mis-styling a character is cosmetic, but
    /// mis-toggling one edits the user's note.
    @MainActor func toggleTask(atUTF16 index: Int) -> Bool {
        // A read-only session can never persist this — see `allowsTaskToggle`.
        guard allowsTaskToggle, let tv = textView, let storage = tv.textStorage else {
            return false
        }
        let ns = tv.string as NSString

        // ONE locator, shared with nothing that could disagree with it — see
        // `TaskCheckbox`. `items` already validates each cached span against
        // the LIVE text, so a span that has drifted is simply absent here.
        for item in TaskCheckbox.items(in: styleCache.spans, text: ns) {
            // The interior boundaries of `[x]` only: `characterIndexForInsertion`
            // snaps to the nearest boundary, so the marker's own offset and the
            // one just past it are "the pointer was over the marker character,
            // or over the inner half of a bracket". The bracket offsets stay
            // available for placing the caret beside the marker.
            guard index >= item.markerRangeUTF16.location,
                  index <= item.markerRangeUTF16.location + 1 else { continue }
            // Located from a cached span; the live text still decides what the
            // character becomes.
            guard let (marker, replacement) = TaskCheckbox.replacement(for: item, in: ns)
            else { continue }

            guard tv.shouldChangeText(in: marker, replacementString: replacement) else {
                return false
            }
            storage.replaceCharacters(in: marker, with: replacement)
            tv.didChangeText()
            // The click still means "the caret goes here", just after the
            // character it flipped — so typing continues where the user
            // pointed rather than wherever the caret happened to be.
            tv.setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
            return true
        }
        return false
    }

    // `insertAttachment(fromPastedImage:name:)`, `insertAttachments
    // (fromDroppedFiles:)` and their shared `insertAtCaret` primitive live in
    // `MarkdownEditorAttachments.swift`, alongside the `LinkTextView` paste/
    // drop handling that calls them.
}
