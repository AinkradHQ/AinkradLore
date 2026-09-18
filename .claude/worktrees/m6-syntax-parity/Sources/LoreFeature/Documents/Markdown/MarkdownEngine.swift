import SwiftUI
import AinkradAppKit

/// Markdown documents: plain `.md` with YAML frontmatter, read and written
/// verbatim and safe to open in Obsidian.
///
/// A thin adapter over the existing `Note` + `Frontmatter` pair. Loading and
/// saving must stay byte-identical to what `LoreStore` did before M0 — this is
/// an extraction, not a rewrite.
public final class MarkdownEngine: DocumentEngine {
    public static let identifier = "markdown"

    public var note: Note

    private init(note: Note) { self.note = note }

    public static func canOpen(_ url: URL) -> Bool {
        ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased())
    }

    public static func load(_ url: URL) throws -> MarkdownEngine {
        let text = try String(contentsOf: url, encoding: .utf8)
        return MarkdownEngine(note: Frontmatter.parse(text, path: url))
    }

    public func save(to url: URL) throws {
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Built from `note.body` alone, not the serialized note (frontmatter and
    /// all). `MarkdownDocumentEditor` binds `MarkdownEditor`'s `text` to
    /// `engine.note.body` — the title lives in a separate field — so every
    /// offset the editor's styling model computes (`MarkdownStyleCache.derive`
    /// parses that same `body_` string) is body-relative. Building the outline
    /// from full frontmatter+body text would shift every `utf16Offset` by the
    /// frontmatter's length, and the click-to-scroll entry point would land in
    /// the wrong place. `note.body` keeps this consistent with the editor by
    /// construction, not by convention. See `OutlineEntry.utf16Offset`'s doc
    /// comment for the general contract this is an instance of.
    ///
    /// `init(body:)` because `note.body` has ALREADY had any real frontmatter
    /// separated out by `Frontmatter.parse`. `init(fullText:)` would run
    /// `Frontmatter.bodyOffset` a second time over text that is no longer
    /// frontmatter-prefixed, and a body that happens to open with something
    /// fence-shaped (an `---` rule, later followed by another bare `---`) would
    /// have that whole span misread as frontmatter and dropped from the parse —
    /// see `MarkdownDocumentModel.init(body:)`.
    ///
    /// A dedicated accessor, not folded into `indexPayload`: `DocumentPane`
    /// wants the outline on its own, on a cadence tighter than a full
    /// `indexPayload` (title/tags/properties/links) is worth recomputing for.
    /// Reaching through `indexPayload` for just the outline would also run
    /// `LinkParser.links(in:)` — a second, unrelated scan — for no reason.
    public var outline: [OutlineEntry] {
        MarkdownDocumentModel(body: note.body).outline
    }

    /// The title is a stored field of the parsed frontmatter — no markdown
    /// parse involved. Overriding the protocol's `indexPayload.title` default
    /// is what keeps `DocumentSession`'s four title refreshes free; see
    /// `DocumentEngine.indexTitle`.
    public var indexTitle: String { note.title }

    /// ONE parse, feeding both halves.
    ///
    /// This used to read `outline` (a `MarkdownDocumentModel`) and then call
    /// `LinkParser.links(in:)`, which builds a SECOND, identical model of the
    /// same body to answer "is this offset inside code?". Nothing was shared,
    /// so every `indexPayload` cost two full AST parses — on the main actor in
    /// the save path, and once per note across a whole-vault rebuild.
    ///
    /// The seam already existed: the model can hand `LinkParser` the
    /// suppression index it just built (`MarkdownDocumentModel.links`), which
    /// is exactly what `wikilinkSpans` does for the styling path. CRLF bodies
    /// still cost two, deliberately — the model withholds its index there
    /// because `LinkParser` normalises before scanning and pre-normalisation
    /// UTF-16 offsets would misplace suppression. Correctness over the saved
    /// parse; see `injectableSuppressionIndex`.
    public var indexPayload: IndexPayload {
        let model = MarkdownDocumentModel(body: note.body)
        return IndexPayload(title: note.title,
                            plaintext: note.body,
                            // Frontmatter tags AND inline `#tags`, deduplicated.
                            // A note tagged both ways must count once, or
                            // `LoreStore.tagCounts` double-counts it in the
                            // sidebar chip row.
                            tags: Array(Set(note.tags + model.inlineTags)).sorted(),
                            properties: note.extra,
                            outline: model.outline,
                            links: model.links,
                            aliases: note.aliases,
                            blocks: model.blockAnchors,
                            id: note.id)
    }

    public func replaceContents(with other: MarkdownEngine) {
        note = other.note
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(MarkdownDocumentEditor(engine: self, ctx: ctx))
    }
}

/// The markdown engine's editor. Owns no persistence: it mutates the engine's
/// note and calls `ctx.onChange`, and `DocumentSession` decides when to write.
@MainActor
private struct MarkdownDocumentEditor: View {
    let engine: MarkdownEngine
    let ctx: EditorContext
    @State private var title: String = ""
    @State private var body_: String = ""
    /// The title as of the last COMMIT (blur/Enter), never per keystroke —
    /// what a refused rename reverts `title` back to. Kept separate from
    /// `engine.note.title` because that field is mutated live, on every
    /// keystroke, below.
    @State private var lastCommittedTitle: String = ""
    /// The text as of the moment the title field last GAINED focus — see
    /// `onChange(of: titleFocused)`'s doc comment.
    @State private var titleAtFocusStart: String = ""
    @State private var titleRefusal: String?
    /// The alert's own title — distinct from "Couldn't rename" for
    /// `.partial`, where the rename actually SUCCEEDED and only something
    /// afterward (persisting the title, an unrewritable link) did not; that
    /// case previously reused "Couldn't rename" verbatim, which is simply
    /// false when the file has, in fact, been renamed (whole-branch review,
    /// fix round 2, Minor D).
    @State private var titleAlertTitle: String = "Couldn't rename"
    @FocusState private var titleFocused: Bool
    /// Set by `ctx.registerScrollHandler`'s callback, which `OutlineSection`
    /// invokes through the closure the shell captured. Body-relative UTF-16 —
    /// see `MarkdownEngine.outline`'s doc comment for why that is what
    /// `outline` offsets already are.
    @State private var scrollTarget: Int?
    /// The editor's own context-menu wiring — see `MarkdownEditorMenu.swift`.
    /// Kept current by `onSelectionChange`, not by the click itself; see that
    /// file's doc comment for why.
    @State private var menuSelection = NSRange(location: 0, length: 0)
    @State private var menuSuggestions: [String] = []
    @State private var menuActions = EditorMenuActions.noop
    /// Off the caret-move hot path — see `MenuSuggestionDebouncer`'s doc
    /// comment. `@State`, not a plain `let`: this struct is reconstructed on
    /// every render, and only `@State` storage survives that across renders,
    /// the same reason `scrollTarget` above is `@State` and not a local var.
    @State private var menuSuggestionDebouncer = MenuSuggestionDebouncer()

    var body: some View {
        VStack(spacing: 0) {
            AinkradTextField(text: $title, placeholder: "Title")
                .padding(AinkradSpacing.md)
                .focused($titleFocused)
                // Live text and the in-memory model track every keystroke —
                // unchanged from before — so the editor's content (and its
                // debounced autosave of BODY/tag changes) keeps working
                // exactly as it did. What is NEW is that the FILE rename is
                // gated on commit, below: renaming the file on every
                // keystroke would thrash the filesystem and rewrite inbound
                // links dozens of times for one typed word.
                .onChange(of: title) { engine.note.title = title; ctx.onChange() }
                // `onSubmit` (Enter/Return) and losing focus (Tab away, click
                // elsewhere) are the two "commit" gestures the owner asked
                // for. Both funnel into the same commit function so there is
                // exactly one rename per commit, never two.
                .onSubmit { if title != titleAtFocusStart { commitTitle() } }
                .onChange(of: titleFocused) { _, isFocused in
                    // Record the text as it stood the moment editing STARTED,
                    // so blur can tell "the user actually typed something"
                    // apart from "the user merely clicked in and back out".
                    // Without this, `commitTitle()` fired unconditionally on
                    // every blur, and for a note whose title and filename
                    // already diverge (the owner's explicitly-uncovered
                    // case), that alone renamed the file and mass-rewrote
                    // every inbound link with no edit and no confirmation —
                    // whole-branch review, Critical 1.
                    if isFocused {
                        titleAtFocusStart = title
                    } else if title != titleAtFocusStart {
                        commitTitle()
                    }
                }

            // Only markdown gets the link affordances: wikilinks are markdown
            // syntax, and offering completion inside a plain-text file would
            // insert brackets that mean nothing there.
            MarkdownEditor(text: $body_, tokens: ctx.theme.tokens,
                           settings: ctx.editorSettings,
                           headingCompletions: ctx.headingCompletions,
                           createLinkedNote: ctx.createLinkedNote,
                           completions: ctx.completions, tagCompletions: ctx.tagCompletions,
                           onOpenLink: ctx.openLink,
                           onTagClick: ctx.onTagClick,
                           resolveEmbedTarget: ctx.resolveEmbedTarget,
                           linkTarget: ctx.linkTarget, scrollTarget: $scrollTarget,
                           // Task checkboxes are markdown, and only a session
                           // that can actually be written may offer to flip
                           // one — see `EditorContext.isReadOnly`.
                           allowsTaskToggle: !ctx.isReadOnly,
                           writePastedImage: ctx.writePastedImage,
                           writeDroppedFile: ctx.writeDroppedFile,
                           onSelectionChange: { text, selection, tag in
                               // Cheap — a struct copy, no XPC — so this part
                               // stays synchronous with the caret.
                               menuSelection = selection
                               // The spine rail's active-heading tracking rides
                               // this same callback rather than adding a second
                               // observer of the caret.
                               ctx.reportCaretOffset(selection.location)
                               // The XPC-backed part is debounced: see
                               // `MenuSuggestionDebouncer`'s doc comment.
                               menuSuggestionDebouncer.schedule(
                                   text: text, offset: selection.location, tag: tag
                               ) { menuSuggestions = $0 }
                           },
                           registerMenuActions: { menuActions = $0 })
                .onChange(of: body_) { engine.note.body = body_; ctx.onChange() }
                .ainkradContextMenu(EditorMenuItems.build(selection: menuSelection,
                                                          suggestions: menuSuggestions,
                                                          actions: menuActions))
        }
        .background(ctx.theme.tokens.background)
        .onAppear {
            title = engine.note.title; body_ = engine.note.body
            lastCommittedTitle = engine.note.title
            titleAtFocusStart = engine.note.title
            ctx.registerScrollHandler { offset in scrollTarget = offset }
        }
        .alert(titleAlertTitle,
               isPresented: Binding(get: { titleRefusal != nil },
                                    set: { if !$0 { titleRefusal = nil } })) {
            Button("OK") { titleRefusal = nil }
        } message: {
            Text(titleRefusal ?? "")
        }
    }

    /// The one place a title-field edit turns into a file rename. Called only
    /// when the commit gesture (`onSubmit`, focus loss) fires AND the text
    /// actually changed since focus was gained — see `titleAtFocusStart`.
    ///
    /// On `.refused` (illegal title, or a collision), the field — and
    /// `engine.note.title`, which the per-keystroke `onChange` above already
    /// pushed the illegal text into — are both reverted to
    /// `lastCommittedTitle`, so the title field never shows text the file on
    /// disk does not have. The owner's ruling: refused, not sanitized, and
    /// reverted to the last VALID value.
    ///
    /// On `.partial`, the file WAS renamed — the field is deliberately NOT
    /// reverted, only the message is shown, or the field would disagree with
    /// the rename that already happened.
    private func commitTitle() {
        switch ctx.commitTitle(title) {
        case .success:
            lastCommittedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            titleAtFocusStart = title
        case .refused(let reason):
            titleAlertTitle = "Couldn't rename"
            titleRefusal = reason
            title = lastCommittedTitle
            engine.note.title = lastCommittedTitle
            titleAtFocusStart = lastCommittedTitle
        case .partial(let reason):
            titleAlertTitle = "Renamed, with a problem"
            titleRefusal = reason
            lastCommittedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            titleAtFocusStart = title
        }
    }
}
