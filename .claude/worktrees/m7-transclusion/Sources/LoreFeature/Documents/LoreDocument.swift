import SwiftUI
import AinkradAppKit

/// A heading in a document, for outline navigation (M2 consumes this; M0 only
/// has to carry it so engines do not need a schema change later).
public struct OutlineEntry: Sendable, Equatable {
    public let level: Int
    public let text: String
    /// UTF-16 offset of the heading, relative to whatever string the
    /// PRODUCING engine parsed to build this outline — NOT necessarily the
    /// on-disk file's full text. There is no runtime check tying this to an
    /// editor's coordinate space; the contract is exactly "whatever string
    /// the engine that built this outline handed its scroll-to-offset entry
    /// point". For `MarkdownEngine` that string is `note.body` — frontmatter
    /// EXCLUDED — because `MarkdownDocumentEditor` binds the editor's text to
    /// `engine.note.body` (the title lives in a separate field), so an offset
    /// counted from a serialized "frontmatter + body" string would be off by
    /// the frontmatter's length the moment it reached the editor. An engine
    /// producing offsets against a different string than the one its own
    /// editor scrolls will misplace every click silently — offset math is
    /// dropped, never guessed, everywhere else in this codebase; this field
    /// is the one place a wrong convention would not even fail loudly.
    /// Defaulted so existing construction sites (tests, other engines) keep
    /// compiling.
    public let utf16Offset: Int
    public init(level: Int, text: String, utf16Offset: Int = 0) {
        self.level = level; self.text = text; self.utf16Offset = utf16Offset
    }
}

/// Everything the shell needs to index a document, supplied BY the engine.
///
/// The shell never re-reads a document's file to index it. That indirection is
/// what lets a PDF or a `.lore` package contribute searchable text it does not
/// literally contain as bytes.
/// A `^block-id` anchor and where it sits.
///
/// `offset` is a UTF-16 offset into the document BODY, matching every other
/// offset the index holds.
public struct BlockAnchor: Sendable, Equatable {
    public let id: String
    public let offset: Int
    public init(id: String, offset: Int) { self.id = id; self.offset = offset }
}

public struct IndexPayload: Sendable {
    /// Stable document identity, when the format has one of its own (markdown's
    /// `id:` frontmatter key). `nil` means "no intrinsic identity" and the
    /// index falls back to the file path — which is what a plain text file has.
    /// Callers that resolve a document by name (the MCP layer) match on this.
    public var id: String?
    public var title: String
    public var plaintext: String
    public var tags: [String]
    public var properties: [FrontmatterPair]
    public var outline: [OutlineEntry]
    /// Outbound links, in document order. Populated by M1.
    public var links: [DocumentLink]
    /// Alternate names this document answers to, from frontmatter `aliases`.
    public var aliases: [String]
    /// `^block-id` anchors this document defines. Populated by M6.
    public var blocks: [BlockAnchor]

    public init(title: String, plaintext: String, tags: [String] = [],
                properties: [FrontmatterPair] = [], outline: [OutlineEntry] = [],
                links: [DocumentLink] = [], aliases: [String] = [],
                blocks: [BlockAnchor] = [], id: String? = nil) {
        self.id = id
        self.title = title; self.plaintext = plaintext; self.tags = tags
        self.properties = properties; self.outline = outline; self.links = links
        self.aliases = aliases
        self.blocks = blocks
    }
}

/// What an engine's editor view needs from the shell.
public struct EditorContext {
    public let theme: HostTheme
    /// Headings of the document named before a `#` in a `[[…]]`, filtered by
    /// what follows it. Defaulted to none, which is what suppresses heading
    /// completion for an engine with no vault behind it.
    public let headingCompletions: @MainActor (String, String) -> HeadingCompletions?
    /// Creates a note for a name typed into a `[[` completion, reporting
    /// whether it worked. Defaulted to "cannot create", which is what
    /// suppresses the popup's create row for an engine with no vault behind
    /// it.
    public let createLinkedNote: @MainActor (String) -> Bool
    /// Reports the caret's BODY-relative UTF-16 offset as it moves.
    ///
    /// Body-relative, matching `OutlineEntry.utf16Offset` and the offset
    /// `registerScrollHandler`'s function accepts — the markdown engine splits
    /// frontmatter and title off the body, and mixing the two spaces would put
    /// every answer out by the length of the frontmatter.
    ///
    /// Defaulted like every other field added since this struct was written,
    /// so an engine with no caret (PDF, attachment) is unaffected.
    public let reportCaretOffset: @MainActor (Int) -> Void
    /// The reader's display preferences for the writing surface. DEFAULTED,
    /// like every other field added to this struct since it was written, so
    /// widening it cannot break an engine that has no text of its own to
    /// scale — the PDF and attachment engines ignore it entirely.
    public let editorSettings: EditorSettings
    /// Called by the editor after every user mutation. The session debounces
    /// and saves; the editor never writes files itself.
    public let onChange: @MainActor () -> Void
    /// Candidate documents for a `[[` prefix. Defaulted to "no candidates" so
    /// widening this struct cannot break an engine or a call site that has no
    /// link layer to offer — an engine that ignores it behaves exactly as
    /// before.
    public let completions: @MainActor (String) -> [IndexRow]
    /// Tag names matching a `#` prefix, for `#` completion. Defaulted to "no
    /// candidates" — same shape as `completions` — so an engine or call site
    /// that has not been updated behaves exactly as before.
    public let tagCompletions: @MainActor (String) -> [String]
    /// Open a wikilink target the user activated in the editor.
    public let openLink: @MainActor (String) -> Void
    /// ⌥-click on a transclusion's rendered content: open its source note
    /// BESIDE what is showing, rather than replacing it — the same gesture
    /// `LoreRootView.openRow` already gives an ⌥-clicked sidebar row.
    /// Defaulted to a no-op, the same "no capability supplied" shape every
    /// other closure added to this struct since it was written uses, so an
    /// engine or call site with no split-view story needs no changes.
    public let openLinkBeside: @MainActor (String) -> Void
    /// A `#tag` the user clicked in the editor. Wired to the SAME
    /// `activeTag` filter the sidebar's `TagChipRow`/`NoteListView` share, so
    /// a click in the body does exactly what a click in the sidebar does.
    /// Defaulted to a no-op, matching every other closure added since this
    /// struct was written, so an engine or call site that ignores tags
    /// behaves exactly as before.
    public let onTagClick: @MainActor (String) -> Void
    /// Resolves an `![[target]]` embed's raw target to a file, for inline
    /// image / chip rendering (`EmbedRendering`). Defaulted to "nothing
    /// resolves", the same "no link layer" default `completions` and
    /// `openLink` already have, so an engine that ignores it behaves exactly
    /// as before.
    public let resolveEmbedTarget: @MainActor (String) -> URL?
    /// The text to write for a picked completion. Supplied by the shell because
    /// only the shell can check that the target resolves back to that document
    /// — see `LoreStore.linkTarget(for:)`. The default is the store-blind
    /// approximation, which is right for an engine with no link layer.
    public let linkTarget: @MainActor (IndexRow) -> String
    /// Lets the editor hand the shell a "scroll to this offset" function,
    /// without the shell reaching into the editor's internals to get one.
    /// `OutlineSection` lives in `DocumentPane`, a sibling of whatever view
    /// `makeEditor` returns — not a descendant of it — so this closure is the
    /// only channel between the two. Defaulted to a no-op so an engine with no
    /// outline (or no editor that supports scrolling at all) needs no changes.
    public let registerScrollHandler: @MainActor (@escaping @MainActor (Int) -> Void) -> Void
    /// The session refuses to write this document, so `onChange` cannot lead
    /// anywhere: `DocumentSession.markChanged()` returns immediately for a
    /// read-only session and `saveNow()` throws. An editor uses this to
    /// withhold affordances that would otherwise PROMISE persistence — today
    /// the task-checkbox toggle. Defaulted to writable so an engine or a test
    /// that does not care behaves exactly as before.
    public let isReadOnly: Bool
    /// Writes pasted image bytes as an attachment BESIDE the open document
    /// and returns the `![[name]]` embed text to insert at the caret, or
    /// `nil` if the write failed (no vault, no permission, …) — in which
    /// case the editor drops the paste rather than inserting a link to
    /// nothing. Defaulted to "cannot write", the same shape every other
    /// store-backed capability here defaults to, so an engine with no
    /// attachment story (or a read-only session) needs no changes.
    public let writePastedImage: @MainActor (Data, String) -> String?
    /// Copies a dropped file into the vault BESIDE the open document and
    /// returns the `![[name]]` embed text to insert. Same "nil means declined
    /// or failed" contract as `writePastedImage`.
    public let writeDroppedFile: @MainActor (URL) -> String?
    /// Called when the title field is COMMITTED — blur or Enter, never per
    /// keystroke — with the field's current text. Renames the file to match
    /// and rewrites inbound links. Returns a `LoreStore.TitleCommitOutcome`:
    /// `.success` (nothing to show), `.refused` (revert the field — nothing
    /// was written), or `.partial` (the file WAS renamed; show the message
    /// but do NOT revert the field, or the field would desynchronize from a
    /// rename that already happened). Defaulted to "always refuse" — same
    /// "declined" shape as `writePastedImage` — so an engine with no
    /// title-field story, or a test that does not care, needs no changes.
    public let commitTitle: @MainActor (String) -> LoreStore.TitleCommitOutcome
    /// Lets the editor learn, with no keystroke required, that a file changed
    /// on disk — an edit made in Obsidian, a save from the same file open in
    /// another split pane, or any other external tool. Rides the SAME sink
    /// the index already uses (`VaultIndexCoordinator`'s watcher-driven
    /// rescan and per-save `indexDocument`), rather than a second watcher:
    /// this is what makes a transcluded `![[note]]` embed update live. The
    /// returned token must be handed back to `unregisterExternalChangeHandler`
    /// when the editor tears down, or the closure — and everything it
    /// captures — outlives it. Defaulted to "never fires, token unused", so
    /// an engine or test with no vault behind it needs no changes.
    public let registerExternalChangeHandler:
        @MainActor (@escaping @MainActor (URL) -> Void) -> UUID
    /// Pairs with `registerExternalChangeHandler` — see its doc comment.
    public let unregisterExternalChangeHandler: @MainActor (UUID) -> Void

    public init(theme: HostTheme,
                editorSettings: EditorSettings = .default,
                headingCompletions: @escaping @MainActor (String, String) -> HeadingCompletions?
                    = { _, _ in nil },
                createLinkedNote: @escaping @MainActor (String) -> Bool = { _ in false },
                reportCaretOffset: @escaping @MainActor (Int) -> Void = { _ in },
                onChange: @escaping @MainActor () -> Void,
                completions: @escaping @MainActor (String) -> [IndexRow] = { _ in [] },
                tagCompletions: @escaping @MainActor (String) -> [String] = { _ in [] },
                openLink: @escaping @MainActor (String) -> Void = { _ in },
                openLinkBeside: @escaping @MainActor (String) -> Void = { _ in },
                onTagClick: @escaping @MainActor (String) -> Void = { _ in },
                resolveEmbedTarget: @escaping @MainActor (String) -> URL? = { _ in nil },
                linkTarget: @escaping @MainActor (IndexRow) -> String
                    = { LinkCompletionContext.insertableTarget(for: $0) },
                registerScrollHandler: @escaping @MainActor (@escaping @MainActor (Int) -> Void) -> Void
                    = { _ in },
                isReadOnly: Bool = false,
                writePastedImage: @escaping @MainActor (Data, String) -> String? = { _, _ in nil },
                writeDroppedFile: @escaping @MainActor (URL) -> String? = { _ in nil },
                commitTitle: @escaping @MainActor (String) -> LoreStore.TitleCommitOutcome
                    = { _ in .refused("Renaming is unavailable here.") },
                registerExternalChangeHandler:
                    @escaping @MainActor (@escaping @MainActor (URL) -> Void) -> UUID
                    = { _ in UUID() },
                unregisterExternalChangeHandler: @escaping @MainActor (UUID) -> Void
                    = { _ in }) {
        self.theme = theme; self.editorSettings = editorSettings
        self.headingCompletions = headingCompletions
        self.createLinkedNote = createLinkedNote
        self.reportCaretOffset = reportCaretOffset
        self.onChange = onChange
        self.completions = completions; self.tagCompletions = tagCompletions
        self.openLink = openLink
        self.openLinkBeside = openLinkBeside
        self.onTagClick = onTagClick
        self.resolveEmbedTarget = resolveEmbedTarget
        self.linkTarget = linkTarget
        self.registerScrollHandler = registerScrollHandler
        self.isReadOnly = isReadOnly
        self.writePastedImage = writePastedImage
        self.writeDroppedFile = writeDroppedFile
        self.commitTitle = commitTitle
        self.registerExternalChangeHandler = registerExternalChangeHandler
        self.unregisterExternalChangeHandler = unregisterExternalChangeHandler
    }
}
