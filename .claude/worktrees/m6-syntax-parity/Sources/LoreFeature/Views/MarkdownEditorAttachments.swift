import AppKit

// Paste and drop of images/files. Moved out of `MarkdownEditorClicks.swift`,
// which Task 9's `becomeFirstResponder` hook pushed to 610 lines — that file
// keeps the click/typing affordances (`mouseDown`, `insertText`,
// `performKeyEquivalent`); this one is everything about turning a pasted or
// dropped file into a written attachment and an inserted `![[…]]` embed.
extension LinkTextView {

    // MARK: - Paste and drop attachments

    /// Intercepts an image or file paste before AppKit's own handling —
    /// which, on a plain (`isRichText == false`) view, either discards image
    /// data outright (no rich-text storage to hold it) or, for a Finder file
    /// copy, inserts the raw path/filename as text, since `.fileURL` always
    /// rides alongside a string representation of that same path.
    ///
    /// THE RULE, in priority order:
    ///
    /// 1. **File URLs win, UNLESS a string on the pasteboard is independent
    ///    prose rather than a mechanical rendering of one of those files.**
    ///    If the pasteboard can produce `NSURL`s restricted to
    ///    `.urlReadingFileURLsOnly` (a Finder "Copy", or anything else
    ///    vending genuine file references) AND every non-empty string on the
    ///    pasteboard is accounted for as a representation of one of those
    ///    files (see `stringsRepresentOnlyFiles`), this routes to
    ///    `onDropFileURLs` — the SAME handler the drop path uses, not a
    ///    parallel one, so multi-file, per-file failure, and the read-only
    ///    guard all come for free. Fix round 1 checked ONLY for a fileURL
    ///    and ignored the string entirely, on the premise that Finder's
    ///    string is always just the path — true for Finder, but a
    ///    reinstatement of this file's own data-loss class the moment some
    ///    other app (Mail, Notes) vends a `.fileURL` for an attachment
    ///    ALONGSIDE genuine prose the user selected around it.
    ///    `.urlReadingFileURLsOnly` keeps an ordinary `http(s)` string
    ///    (Safari's "Copy Link") from being misread as a file to begin with.
    /// 2. Otherwise, if the pasteboard offers image bytes (`.png`/`.tiff`)
    ///    AND EITHER no string at all, OR a string that is merely the
    ///    image's own source reference rather than prose the user selected
    ///    (see `isImageSourceRepresentation`), the image is attached. This
    ///    is what makes Safari/Preview's "Copy Image" — bytes plus the
    ///    source page's URL as a string, no `.fileURL` — write the image
    ///    instead of pasting that URL: the owner's most common complaint.
    /// 3. Anything else with a string present falls straight through to
    ///    `super.paste(_:)`, exactly AppKit's own behaviour. This is the
    ///    data-loss regression guard: a genuine mixed copy (real prose
    ///    selected alongside an image or a file, in Notes/Keynote/Mail, or
    ///    most RTF copies which carry `.tiff` beside
    ///    `public.utf8-plain-text`) must paste the TEXT and write nothing,
    ///    the same as before this rule existed — see
    ///    `isImageSourceRepresentation`'s doc comment for the honest limits
    ///    of that test.
    ///
    /// KNOWN GAP, not a regression: a PROMISED file (`.fileContents` /
    /// `NSFilesPromisePboardType`, offered by some apps before the file is
    /// materialised on disk — no `NSURL` to read yet) is invisible to
    /// `fileURLs(on:)` and falls through this whole rule to `super.paste`.
    /// `performDragOperation` below has the identical gap for a promised
    /// DROP, so this is not new here; neither path is exercised by a test,
    /// and fixing it would mean adopting `NSFilePromiseReceiver`, a
    /// materially bigger change than this rule.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        if let onDropFileURLs, let urls = Self.fileURLs(on: pb), !urls.isEmpty,
           Self.stringsRepresentOnlyFiles(on: pb, urls: urls) {
            // Committed: this pasteboard is a file copy with no independent
            // prose riding along. Whatever the handler reports — full
            // success, partial success (some files written, per
            // `insertAttachments(fromDroppedFiles:)`), or total failure —
            // is the final answer. Falling through to `super` on failure
            // would be exactly the ORIGINAL bug: AppKit's default paste
            // would still insert the raw path as text.
            _ = onDropFileURLs(urls)
            return
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let best = pb.availableType(from: imageTypes),
              let data = pb.data(forType: best) else {
            super.paste(sender)
            return
        }
        // `pb.string(forType:)`, not the earlier fix-round-1 guard of
        // `availableType(from: [.string]) == nil`: that gate blocked on the
        // TYPE being merely advertised, so a `.string` type present but
        // carrying no actual string data (rare, but a valid pasteboard
        // shape) would defer to text with nothing there to paste. Asking
        // for the string itself is the more precise question — "is there
        // real string content to weigh against the image" — and only
        // differs from the old gate in that one narrow, data-free edge.
        if let string = pb.string(forType: .string), !Self.isImageSourceRepresentation(string) {
            super.paste(sender)
            return
        }
        // `.png` is tried before `.tiff` because that is what `NSPasteboard`'s
        // screenshot/copy-image paths actually populate; TIFF is the
        // fallback some apps use instead.
        let ext = best == .png ? "png" : "tiff"
        let name = "Pasted image \(Self.pasteTimestampFormatter.string(from: Date())).\(ext)"
        if onPasteImage?(data, name) == true { return }
        super.paste(sender)
    }

    /// File URLs on the pasteboard, restricted to ones that are ACTUALLY
    /// file references — never an `http(s)` link that merely canonicalizes
    /// to a URL. `nil` when the pasteboard cannot produce any (the common
    /// case: no `.fileURL` type at all), so callers can tell "not a file
    /// paste" apart from "a file paste that happens to be empty", though the
    /// latter cannot occur in practice.
    fileprivate static func fileURLs(on pb: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard pb.canReadObject(forClasses: [NSURL.self], options: options) else { return nil }
        return pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    }

    /// Whether every non-empty string on the pasteboard is accounted for as
    /// a mechanical rendering of one of `urls` — never independent prose.
    ///
    /// Checked PER `NSPasteboardItem`, not via `NSPasteboard.string
    /// (forType:)` on the pasteboard as a whole: that method only ever sees
    /// the FIRST item's string, which would miss a SEPARATE item carrying
    /// real prose — the shape a Mail or Notes selection of "some text plus
    /// an attachment" can plausibly produce (one item for the attachment's
    /// `.fileURL`, a different item for the surrounding text the user
    /// selected around it). An item with a string but no `.fileURL` of its
    /// own is exactly that case: its string cannot be a representation of
    /// ANY file, since it is not paired with one, so any non-blank string
    /// there fails the check immediately.
    fileprivate static func stringsRepresentOnlyFiles(on pb: NSPasteboard, urls: [URL]) -> Bool {
        guard let items = pb.pasteboardItems else { return true }
        for item in items {
            guard let string = item.string(forType: .string),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard urls.contains(where: { Self.isRepresentation(string, of: $0) }) else { return false }
        }
        return true
    }

    /// Whether `string` is nothing more than a mechanical rendering of
    /// `url` — its absolute string, its filesystem path, or its last path
    /// component, with or without percent-encoding — as opposed to prose
    /// that merely happens to mention the file.
    fileprivate static func isRepresentation(_ string: String, of url: URL) -> Bool {
        guard let token = Self.singleToken(string) else { return false }
        if token == url.absoluteString || token == url.path || token == url.lastPathComponent {
            return true
        }
        if let decoded = token.removingPercentEncoding,
           decoded == url.absoluteString || decoded == url.path || decoded == url.lastPathComponent {
            return true
        }
        return false
    }

    /// Whether a string riding alongside image bytes looks like the image's
    /// own SOURCE reference (what Safari/Preview's "Copy Image" writes —
    /// the page or file the image came from) rather than prose the user
    /// independently selected. The test: the whole trimmed string is ONE
    /// token (see `singleToken`) and it parses as a URL with a scheme.
    ///
    /// HONEST LIMIT: this is a heuristic over pasteboard content, not a
    /// certainty. A genuine text selection that is itself a single bare URL
    /// with nothing else — copied deliberately, alongside an unrelated
    /// image, in some app — would be misread as the image's source and
    /// discarded rather than pasted. That case is judged rare enough (a
    /// prose selection consisting of exactly one URL and no other
    /// characters) to accept, because the alternative — always deferring to
    /// text whenever ANY string rides along — is what the owner hit: it
    /// makes "Copy Image" in Safari, the single most common source of this
    /// complaint, paste a URL every time instead of the image. Where the
    /// two goals conflict this narrowly, WHOLE SENTENCES OF PROSE (anything
    /// with a space) still always win over the image, per the guard this
    /// function backs — only a bare, spaceless, scheme-bearing token can
    /// ever be read as "this is the image's source, not the user's text".
    fileprivate static func isImageSourceRepresentation(_ string: String) -> Bool {
        guard let token = Self.singleToken(string),
              let url = URL(string: token), url.scheme != nil else { return false }
        return true
    }

    /// The one idea both `isRepresentation(_:of:)` and
    /// `isImageSourceRepresentation` are built on: trim the string, and
    /// treat it as a candidate "this is a MECHANICAL rendering, not prose"
    /// only if what remains has no internal whitespace at all. Real prose —
    /// a sentence, a caption, a filename mentioned in a sentence — almost
    /// always has a space somewhere; a raw path, filename, or URL never
    /// does. `nil` for anything blank or containing whitespace, which both
    /// callers treat as "not a mechanical representation of anything".
    fileprivate static func singleToken(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return trimmed
    }

    /// `yyyy-MM-dd HH.mm.ss`: colons are illegal in filenames on some
    /// volumes, so `HH.mm.ss` stands in for the usual `HH:mm:ss`. The
    /// pasteboard's timestamp is the only thing that distinguishes one paste
    /// from the next — without it, every image pasted into a note would
    /// collide on the same name and stack up as "image 2", "image 3", ….
    fileprivate static let pasteTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard onDropFileURLs != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) else {
            return super.draggingEntered(sender)
        }
        return .copy
    }

    /// Files dropped from Finder are COPIED into the vault, never referenced
    /// in place — see `LoreStore.writeAttachment(copying:besideNote:)`'s doc
    /// comment.
    ///
    /// Falls through to `super` (AppKit's default drop handling) only when
    /// there is NO handler installed, or the pasteboard carries no file
    /// URLs at all — the same two "this drop is not mine" cases
    /// `draggingEntered` already reports as not `.copy`. Once a handler IS
    /// installed and file URLs ARE present, this drop is fully owned:
    /// whatever `onDropFileURLs` reports — success or failure — is the
    /// final answer. Falling through to `super` on failure was the bug:
    /// with `.fileURL` registered, AppKit's own default handling inserts
    /// the raw file PATH as text, so a write that failed (permissions, disk
    /// full, outside-vault guard) would otherwise still leave something
    /// behind in the document — just the wrong something. A failed drop
    /// must insert nothing.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onDropFileURLs else { return super.performDragOperation(sender) }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        return onDropFileURLs(urls)
    }
}

extension MarkdownEditor.Coordinator {

    /// Writes pasted image bytes as an attachment beside the note (via
    /// `EditorContext.writePastedImage`) and inserts the resulting
    /// `![[name]]` embed at the caret. `false` means declined or failed —
    /// no vault, no `writePastedImage` handler installed, or the write
    /// itself threw — and `LinkTextView.paste(_:)` falls through to AppKit's
    /// default paste, exactly like a Cmd-click that hits no link.
    @discardableResult
    @MainActor func insertAttachment(fromPastedImage data: Data, name: String) -> Bool {
        guard let writePastedImage, let embed = writePastedImage(data, name) else { return false }
        insertAtCaret(embed)
        return true
    }

    /// Copies each dropped file into the vault beside the note (via
    /// `EditorContext.writeDroppedFile`) and inserts every embed that
    /// succeeded, one per line, at the caret. A partial failure (one file
    /// copies, another does not — e.g. a permissions error mid-drop) still
    /// inserts what DID succeed rather than discarding it; only a drop where
    /// EVERY file failed reports `false` and falls through to AppKit's
    /// default drop handling.
    @discardableResult
    @MainActor func insertAttachments(fromDroppedFiles urls: [URL]) -> Bool {
        guard let writeDroppedFile else { return false }
        let embeds = urls.compactMap { writeDroppedFile($0) }
        guard !embeds.isEmpty else { return false }
        insertAtCaret(embeds.joined(separator: "\n"))
        return true
    }

    /// The shared insertion primitive for both attachment paths. Goes
    /// through `shouldChangeText`/`didChangeText` — the identical bracketing
    /// `insert(_ row:)` and `toggleTask(atUTF16:)` use — so an attachment
    /// insert is ONE undo step and fires the same `textDidChange` delegate
    /// call that updates `text.wrappedValue`, shifts the style cache, and
    /// (through `ctx.onChange()`) marks the document dirty for autosave.
    /// Replaces the current selection, same as typing over it — this is the
    /// ONLY sanctioned way this feature touches document text or offsets.
    @MainActor private func insertAtCaret(_ insertion: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: insertion) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: insertion)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (insertion as NSString).length,
                                    length: 0))
    }
}
