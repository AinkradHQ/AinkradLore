import AinkradAppKit
import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens
    /// Display preferences. Threaded down from `EditorContext` so the five
    /// places that build a `MarkdownTheme` all build the SAME one — the
    /// alternative was a process-wide current-settings global, which would
    /// have made two Lore instances in one host share a font size.
    let settings: EditorSettings
    /// See `EditorContext.headingCompletions`.
    let headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)?
    /// See `EditorContext.createLinkedNote`.
    let createLinkedNote: (@MainActor (String) -> Bool)?
    /// Rows to offer for the current `[[` prefix. `nil` disables completion
    /// entirely — which is how plain-text documents get no link affordances.
    let completions: (@MainActor (String) -> [IndexRow])?
    /// Tag names matching the current `#` prefix, for `#` completion. `nil`
    /// disables it entirely — same "no capability supplied" shape as
    /// `completions` above, so a document type with no tag pipeline (or a
    /// call site that has not been updated) behaves exactly as before.
    let tagCompletions: (@MainActor (String) -> [String])?
    /// Called with the raw target of a Cmd-clicked `[[…]]` span. `nil` disables
    /// click-to-open.
    let onOpenLink: (@MainActor (String) -> Void)?
    /// Called with the raw target of a click that landed inside a rendered
    /// transclusion (a `![[note]]` embed's drawn content, not its collapsed
    /// source) while ⌥ was held. `nil` disables the beside-open affordance —
    /// same "no capability supplied" shape `onOpenLink == nil` already has —
    /// which is how a plain click still opens the embed in place even when
    /// nothing wired the split-view path up.
    let onOpenLinkBeside: (@MainActor (String) -> Void)?
    /// Called with a `#tag`'s name when clicked in the body. `nil` disables
    /// tag-click-to-filter entirely, matching `onOpenLink`'s "no capability
    /// supplied" shape.
    let onTagClick: (@MainActor (String) -> Void)?
    /// Resolves an `![[target]]` embed's raw target to a file, for
    /// `EmbedRendering`. `nil` — the default — makes every embed render
    /// `.unresolved` (plain wikilink colouring), which is the right answer
    /// for an engine with no link layer, exactly like `completions == nil`.
    let resolveEmbedTarget: (@MainActor (String) -> URL?)?
    /// See `EditorContext.registerExternalChangeHandler`. `nil` disables live
    /// transclusion updates entirely — the same "no capability supplied"
    /// shape `resolveEmbedTarget == nil` already has, which is right for an
    /// engine with no vault (and so no `![[…]]` targets that could ever
    /// change out from under it).
    let registerExternalChangeHandler: (@MainActor (@escaping @MainActor (URL) -> Void) -> UUID)?
    /// Pairs with `registerExternalChangeHandler` — see its doc comment.
    let unregisterExternalChangeHandler: (@MainActor (UUID) -> Void)?
    /// What a picked row inserts. Defaults to the store-blind approximation.
    let linkTarget: @MainActor (IndexRow) -> String
    /// A UTF-16 offset (into `text`) to scroll the caret to and select. Set by
    /// a caller — `OutlineSection` — and cleared back to `nil` once handled,
    /// so re-clicking the same heading still fires: `updateNSView` only acts
    /// on a non-nil value, never on "the value changed".
    let scrollTarget: Binding<Int?>
    /// Whether clicking a `[ ]` marker flips it. Off by default, so a document
    /// type that has no task lists — and, crucially, a READ-ONLY session, whose
    /// `markChanged()` is a no-op and whose saves are refused — offers no
    /// affordance it cannot honour. See `MarkdownEditorClicks.swift`.
    let allowsTaskToggle: Bool
    /// See `EditorContext.writePastedImage`. `nil` disables the paste
    /// interception entirely, so a document with no attachment story falls
    /// straight through to AppKit's default paste — exactly the
    /// `completions == nil` / `onOpenLink == nil` pattern above.
    let writePastedImage: (@MainActor (Data, String) -> String?)?
    /// See `EditorContext.writeDroppedFile`. `nil` disables the drop
    /// destination.
    let writeDroppedFile: (@MainActor (URL) -> String?)?
    /// Fired on every selection change with the live document text and
    /// selection — the host's context-menu wiring (`MarkdownEditorMenu.swift`)
    /// uses this to keep its menu items current without reaching back into
    /// AppKit itself. See that file for why the items cannot be computed at
    /// the exact moment of a right-click.
    let onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)?
    /// Called once the text view exists, with the actions its own context
    /// menu should run. See `MarkdownEditorMenu.swift`.
    let registerMenuActions: (@MainActor (EditorMenuActions) -> Void)?

    init(
        text: Binding<String>, tokens: HostThemeTokens,
        settings: EditorSettings = .default,
        headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)? = nil,
        createLinkedNote: (@MainActor (String) -> Bool)? = nil,
        completions: (@MainActor (String) -> [IndexRow])? = nil,
        tagCompletions: (@MainActor (String) -> [String])? = nil,
        onOpenLink: (@MainActor (String) -> Void)? = nil,
        onOpenLinkBeside: (@MainActor (String) -> Void)? = nil,
        onTagClick: (@MainActor (String) -> Void)? = nil,
        resolveEmbedTarget: (@MainActor (String) -> URL?)? = nil,
        registerExternalChangeHandler:
            (@MainActor (@escaping @MainActor (URL) -> Void) -> UUID)? = nil,
        unregisterExternalChangeHandler: (@MainActor (UUID) -> Void)? = nil,
        linkTarget: @escaping @MainActor (IndexRow) -> String = { LinkCompletionContext.insertableTarget(for: $0) },
        scrollTarget: Binding<Int?> = .constant(nil),
        allowsTaskToggle: Bool = false,
        writePastedImage: (@MainActor (Data, String) -> String?)? = nil,
        writeDroppedFile: (@MainActor (URL) -> String?)? = nil,
        onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)? = nil,
        registerMenuActions: (@MainActor (EditorMenuActions) -> Void)? = nil
    ) {
        self._text = text
        self.tokens = tokens
        self.settings = settings
        self.headingCompletions = headingCompletions
        self.createLinkedNote = createLinkedNote
        self.completions = completions
        self.tagCompletions = tagCompletions
        self.onOpenLink = onOpenLink
        self.onOpenLinkBeside = onOpenLinkBeside
        self.onTagClick = onTagClick
        self.resolveEmbedTarget = resolveEmbedTarget
        self.registerExternalChangeHandler = registerExternalChangeHandler
        self.unregisterExternalChangeHandler = unregisterExternalChangeHandler
        self.linkTarget = linkTarget
        self.scrollTarget = scrollTarget
        self.allowsTaskToggle = allowsTaskToggle
        self.writePastedImage = writePastedImage
        self.writeDroppedFile = writeDroppedFile
        self.onSelectionChange = onSelectionChange
        self.registerMenuActions = registerMenuActions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tokens: tokens, settings: settings)
    }

    // `makeNSView`, `updateNSView`, `dismantleNSView` and `addStylingNotice`
    // — the AppKit-object lifecycle — live in `MarkdownEditorView.swift`.
    // This file keeps the `NSViewRepresentable`'s declared surface (the
    // properties, the initializer, `makeCoordinator`) together with the
    // `Coordinator` those lifecycle methods drive.
}
