import Foundation

/// One styled region of the editor's text.
struct StyleSpan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(Int)
        case strong
        case emphasis
        /// `~~text~~`. From the AST — `swift-markdown` has a `Strikethrough`
        /// node — not from `MarkdownExtensions`, because wherever the AST has
        /// a node the AST stays the single source of truth.
        case strikethrough
        /// `==text==`. From `MarkdownExtensions`, not the AST — CommonMark has
        /// no highlight node.
        case highlight
        /// `[^label]` inline.
        case footnoteReference(label: String)
        /// `[^label]:` at line start.
        case footnoteDefinition(label: String)
        /// `#tag`, `#nested/tag`. `name` excludes the `#` and any trailing
        /// `/`. From `MarkdownExtensions` — CommonMark has no tag node.
        case tag(name: String)
        /// `^block-id` at the end of a block. An anchor, not a control. From
        /// `MarkdownExtensions` — CommonMark has no block-reference node.
        case blockID(id: String)
        case inlineCode
        case codeBlock(language: String?)
        case link
        case wikilink
        case listItem
        case blockQuote
        /// A block quote that opens with `[!type]` — an Obsidian callout.
        /// Emitted INSTEAD of `.blockQuote`, not alongside it: the two want
        /// different decoration (a tinted panel and a coloured bar against a
        /// grey bar) and emitting both would draw them on top of each other.
        case callout(MarkdownCallout.Kind)
        /// A callout's title — the author's own, on the header line.
        case calloutTitle(MarkdownCallout.Kind)
        /// A `---` / `***` / `___` rule, whole. The source collapses and a
        /// line is drawn across the measure in its place.
        case thematicBreak
        /// A GFM pipe table, whole.
        case table
        /// A table's header row, which renders bolder than its body.
        case tableHeader
        /// A `$…$` expression. `isRendered` is false when it contains
        /// something this editor cannot render exactly, in which case the
        /// source stays visible and is merely tinted — see `MarkdownMath`.
        case math(isRendered: Bool)
        case checkbox(Bool)
        /// An `![[target]]` embed's TARGET text — same convention as
        /// `.wikilink`'s content span: the brackets (and the leading `!`)
        /// sit OUTSIDE this range, as `.marker(of: .wikilink)` spans, so the
        /// SAME reveal machinery that shows/hides an ordinary wikilink's
        /// `[[`/`]]` on caret entry also shows/hides an embed's `![[`/`]]` —
        /// see Task 8 fix round 1, Important 6. `target` is the raw target
        /// (fragment included, alias excluded — see `DocumentLink.rawTarget`),
        /// for resolving what to render. `fullRange` is the WHOLE source
        /// form — `!`, both brackets and the target — because an IMAGE
        /// embed, unlike a chip, must collapse the target text too (there is
        /// no rasterized filename to show instead), and that collapse needs
        /// the outer bound the marker spans alone do not carry. See
        /// `EmbedRendering.applyEmbeds`.
        case embed(target: String, fullRange: Range<Int>)
        /// The syntax characters of `owner`, and NOTHING else. Emitted
        /// separately from the content span so Live Preview can collapse the
        /// markers without touching the text they delimit.
        case marker(of: MarkerOwner)

        /// Whether ONE opening marker and ONE closing marker delimit this kind,
        /// with the content between them.
        ///
        /// The reveal rule's one exception, and it lives on the kind rather than in
        /// `MarkdownReveal` so that adding a kind forces the question to be
        /// answered here — see `MarkdownReveal.revealedRange`. A span like this that
        /// crosses a line boundary must reveal WHOLE, or the caret sits inside
        /// syntax whose other half is hidden.
        ///
        /// `blockQuote`, `listItem` and `heading` answer `false`: each of their
        /// lines carries its own marker, so there is no pair to split, and
        /// revealing them together is the block-scoped behaviour being replaced.
        var isDelimitedByASinglePair: Bool {
            switch self {
            case .strong, .emphasis, .strikethrough, .highlight, .inlineCode, .codeBlock, .link, .wikilink, .embed:
                return true
            case .footnoteReference:
                return true
            case .footnoteDefinition:
                return false
            // No closing delimiter at all — there is nothing to split across
            // a line break, and no pair to reveal together.
            case .tag:
                return false
            // Line-scoped, with no closing half — same shape as `.tag`.
            case .blockID:
                return false
            case .heading, .listItem, .blockQuote, .callout, .calloutTitle,
                .table, .tableHeader, .checkbox, .marker, .thematicBreak:
                return false
            // A `$…$` expression is delimited by ONE pair, so it reveals
            // whole rather than splitting across a line break.
            case .math: return true
            }
        }

        /// Whether the caret landing anywhere inside this span reveals ALL of
        /// it, rather than only the line the caret is on.
        ///
        /// Two different reasons lead here. A span delimited by ONE marker
        /// pair (`isDelimitedByASinglePair`) must reveal whole or the caret
        /// stands in syntax whose other half is hidden.
        ///
        /// A TABLE is here for a second reason, found by watching what the
        /// line-scoped rule actually does to one: the caret in a single row
        /// put THAT row back to `| a | b |` while the rows above and below
        /// stayed painted as a grid — a strip of raw markdown wedged inside a
        /// table, which is the "glitching when I click on the table" Ahmed
        /// reported. A table is one object on screen; it has to be one object
        /// when it comes apart, too.
        var revealsWholeOnCaretEntry: Bool {
            if case .table = self { return true }
            return isDelimitedByASinglePair
        }
    }
    /// UTF-16 offsets into the EDITOR's full string, frontmatter included.
    /// Not Character offsets — `LinkSpan.targetRange` uses those, and mixing
    /// the two misplaces every span in a document containing an emoji.
    let range: Range<Int>
    let kind: Kind

    init(range: Range<Int>, kind: Kind) {
        self.range = range
        self.kind = kind
    }

    /// Whether this span is an `![[target]]` embed's target span — the ONLY
    /// kind `EmbedRendering`/`TransclusionStyling` ever act on. Named for the
    /// M8 test that pins the code-fence mask: a `![[…]]` written inside a
    /// fenced code block is never emitted as `.embed` at all (the fence
    /// suppresses wikilink/embed parsing entirely, same as any other inline
    /// syntax inside a code span), so no span with `isTransclusionEmbed ==
    /// true` can ever fall inside a fence's range. This property exists so
    /// that guarantee has a name to test, rather than tests reaching past
    /// `StyleSpan` into `Kind` directly.
    var isTransclusionEmbed: Bool {
        if case .embed = kind { return true }
        return false
    }
}
