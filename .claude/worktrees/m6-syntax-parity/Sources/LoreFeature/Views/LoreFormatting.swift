import AppKit

/// The formatting operations a shortcut can ask the focused editor to perform.
///
/// `Int`-backed because the dispatch carries it in an `NSMenuItem.tag` — the
/// same responder-chain trick `LoreFind` uses, and for the same reason: Lore is
/// a plugin with no menu bar, so nothing dispatches ⌘B for it, and the shell
/// has no reference to whichever text view is focused.
///
/// Reaching the editor this way rather than by plumbing a handler up through
/// `EditorContext` matters beyond convenience: `EditorContext` is shared with
/// the PDF and attachment engines, which have no text to format, and it is
/// already carrying sixteen members.
enum LoreFormatAction: Int {
    case bold = 1, italic, inlineCode, link, bulletList, taskList, quote
    case heading1, heading2, heading3, heading4, heading5, heading6, body
}

/// Applies a formatting action to whichever text view is focused.
enum LoreFormatting {

    /// Sends `action` down the responder chain.
    ///
    /// Returns whether anything handled it. `false` means focus was somewhere
    /// with no text — the sidebar, the palette — and the keystroke is ignored,
    /// which is correct: ⌘B in a list is not a request to embolden something
    /// in a document the user is not looking at.
    @discardableResult
    static func perform(_ action: LoreFormatAction) -> Bool {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        return NSApp.sendAction(#selector(LinkTextView.loreApplyFormat(_:)),
                                to: nil, from: sender)
    }

    /// Performs `action` on `tv`.
    ///
    /// Every case routes through a PURE transform (`MarkdownEditing` or
    /// `MarkdownLineFormatting`) applied by `MarkdownEditorTyping.apply`,
    /// which is what registers a single undo step and keeps the styling passes
    /// in sync — the same path the context menu's Link/Code/Heading items
    /// already take. Nothing here edits the text view directly.
    @MainActor
    static func apply(_ action: LoreFormatAction, to tv: NSTextView) {
        switch action {
        case .bold:
            MarkdownEditorTyping.toggleWrap(in: tv, with: "**")
        case .italic:
            // A single asterisk, not an underscore: `_` inside a word (a
            // snake_case identifier, which a notes vault is full of) is not
            // emphasis in CommonMark, so wrapping with it produces text that
            // looks wrapped and renders plain.
            MarkdownEditorTyping.toggleWrap(in: tv, with: "*")
        case .inlineCode:
            MarkdownEditorTyping.toggleWrap(in: tv, with: "`")
        case .link:
            MarkdownEditorMenuActions.wrapAsWikiLink(in: tv)
        case .bulletList:
            applyLinePrefix("- ", to: tv)
        case .taskList:
            applyLinePrefix("- [ ] ", to: tv)
        case .quote:
            applyLinePrefix("> ", to: tv)
        case .heading1: applyHeading(1, to: tv)
        case .heading2: applyHeading(2, to: tv)
        case .heading3: applyHeading(3, to: tv)
        case .heading4: applyHeading(4, to: tv)
        case .heading5: applyHeading(5, to: tv)
        case .heading6: applyHeading(6, to: tv)
        case .body: applyHeading(0, to: tv)
        }
    }

    @MainActor
    private static func applyLinePrefix(_ prefix: String, to tv: NSTextView) {
        _ = MarkdownEditorTyping.apply(
            MarkdownLineFormatting.toggleLinePrefix(text: tv.string,
                                                    selection: tv.selectedRange(),
                                                    prefix: prefix),
            to: tv)
    }

    @MainActor
    private static func applyHeading(_ level: Int, to tv: NSTextView) {
        _ = MarkdownEditorTyping.apply(
            MarkdownLineFormatting.setHeading(text: tv.string,
                                              selection: tv.selectedRange(),
                                              level: level),
            to: tv)
    }
}
