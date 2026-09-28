import AppKit

/// Which block a paragraph belongs to, for layout purposes only.
enum MarkdownBlock: Equatable {
    case body
    case heading(Int)
    case listItem(depth: Int)
    case blockQuote
    /// An Obsidian callout. Indented further than a quote, to leave room for
    /// the icon drawn beside its title as well as the bar.
    case callout(MarkdownCallout.Kind)
    case codeBlock
}

/// How deeply each `.listItem` span is nested.
///
/// `StyleSpan.Kind.listItem` carries no depth, and does not need to: nesting is
/// already in the ranges. `MarkdownASTCollector.visitListItem` appends the item
/// then `descendInto`s it, so a nested item is emitted AFTER its ancestors and
/// its range is strictly contained in theirs. Depth is therefore the number of
/// still-open ancestors — which a stack answers in one pass, without changing
/// the span kind and without a second walk of the document.
enum MarkdownListDepth {

    /// Depths aligned with `spans` by index. Entries for non-list spans are
    /// `0` and are never read; the array is index-aligned rather than a
    /// dictionary so the renderer's own loop can look a depth up by position.
    static func depths(of spans: [StyleSpan]) -> [Int] {
        var result = [Int](repeating: 0, count: spans.count)
        var open: [Range<Int>] = []
        for (index, span) in spans.enumerated() {
            guard case .listItem = span.kind else { continue }
            // Pop every ancestor this item is NOT inside. A sibling that starts
            // where the previous item ended closes it; a genuinely nested item
            // leaves it open.
            while let top = open.last,
                  !(span.range.lowerBound >= top.lowerBound
                    && span.range.upperBound <= top.upperBound) {
                open.removeLast()
            }
            result[index] = open.count
            open.append(span.range)
        }
        return result
    }
}

/// Block layout as paragraph ATTRIBUTES.
///
/// Never as inserted whitespace: padding a list with spaces would change the
/// document text, and with it every offset the index, the link graph and the
/// MCP tools hold. Layout is a rendering concern and stays one.
enum MarkdownParagraphStyles {

    /// A list item's style with its hang indent DERIVED from where the item's
    /// text actually starts.
    ///
    /// Additive to `style(for:theme:)`, which keeps its committed signature and
    /// its committed answer. That answer assumes the bullet is the only thing
    /// between the indent and the text — true at the top level, false the
    /// moment an item is nested, because the source indentation before a nested
    /// bullet is visible text that no marker collapses. The first line
    /// therefore begins at `firstLineHeadIndent + leadingIndent`, and a
    /// wrapped line hangs under the text only if `headIndent` says the same.
    ///
    /// - Parameter leadingIndent: the rendered width of the whitespace before
    ///   the item's bullet. Zero for a top-level item, where this degrades to
    ///   "wrapped lines align with the first line" — which, with the bullet
    ///   collapsed in the reading state, is exactly under the text.
    static func listItemStyle(depth: Int, leadingIndent: CGFloat,
                              theme: MarkdownTheme) -> NSParagraphStyle {
        let base = style(for: .listItem(depth: depth), theme: theme)
        guard let s = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        s.headIndent = s.firstLineHeadIndent + max(0, leadingIndent)
        return s
    }

    /// Reserves `height` points of line height for an embedded image's
    /// paragraph. The image's SOURCE text is collapsed to a near-zero font
    /// (see `EmbedRendering.applyEmbeds`), which on its own would leave the
    /// line only as tall as a collapsed glyph — a single point. Setting
    /// `minimumLineHeight` is what makes the paragraph tall enough for
    /// `LinkTextView` to draw the actual image into, without inserting any
    /// character or attachment that would change what the line contains.
    ///
    /// - Parameter base: the paragraph's OWN style, as already applied by
    ///   `MarkdownStyleRenderer` for whatever block this paragraph is (list
    ///   item, blockquote, or plain body) — `nil` only when no such style is
    ///   on record yet, which falls back to `style(for: .body, theme:)`.
    ///   Rebasing on `.body` UNCONDITIONALLY, as this used to, discards
    ///   `firstLineHeadIndent`/`headIndent` for a list-nested or
    ///   blockquoted embed — it reset such an image to the left/right margin
    ///   as if it were top-level. That silently MASKED the writing-direction
    ///   bug `EmbedGeometry.drawRect` now fixes: with indent always zero,
    ///   a mis-derived RTL origin and a correctly-derived one only diverge
    ///   once there IS an indent to get wrong, so an indented embed was the
    ///   one case fix round 1 never actually exercised. Preserving `base`
    ///   here is what makes an indented embed sit at its list/blockquote's
    ///   indent instead of resetting to zero, in EITHER writing direction.
    static func embedImageStyle(basedOn base: NSParagraphStyle?, height: CGFloat,
                                theme: MarkdownTheme) -> NSParagraphStyle {
        let base = base ?? style(for: .body, theme: theme)
        guard let s = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        s.minimumLineHeight = height
        s.maximumLineHeight = height
        return s
    }

    static func style(for block: MarkdownBlock, theme: MarkdownTheme) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineHeightMultiple = theme.lineHeightMultiple
        s.paragraphSpacing = theme.paragraphSpacing

        switch block {
        case .body:
            break

        case .heading(let level):
            s.paragraphSpacingBefore = theme.headingSpacingBefore(level)
            s.paragraphSpacing = theme.headingSpacingAfter(level)

        case .listItem(let depth):
            let base = theme.listIndentStep * CGFloat(depth + 1)
            s.firstLineHeadIndent = base
            // The hang: wrapped lines align under the item's TEXT, not under
            // its bullet. This single attribute is most of what makes a
            // multi-line bullet stop looking broken.
            s.headIndent = base + theme.listIndentStep
            // List items are lines of one list, not separate paragraphs.
            s.paragraphSpacing = theme.paragraphSpacing * 0.25

        case .blockQuote:
            // Room for the bar drawn in `MarkdownBlockBackgrounds`.
            s.firstLineHeadIndent = theme.listIndentStep
            s.headIndent = theme.listIndentStep

        case .callout:
            // Exactly the room the decoration occupies — bar, gap, icon, gap —
            // read from the drawing's own constant so the two cannot disagree.
            // A guessed multiple of the list indent left 15 pt of dead space,
            // which showed as an empty gutter whenever the caret revealed the
            // header and the icon stopped being drawn.
            //
            // Constant whether or not the icon is currently drawn: shrinking it
            // on reveal would shift every line of the callout sideways as the
            // caret entered it, trading a small gap for a visible jump.
            s.firstLineHeadIndent = MarkdownBlockBackgrounds.calloutTextIndent
            s.headIndent = MarkdownBlockBackgrounds.calloutTextIndent
            s.paragraphSpacing = theme.paragraphSpacing * 0.5

        case .codeBlock:
            s.firstLineHeadIndent = theme.listIndentStep * 0.5
            s.headIndent = theme.listIndentStep * 0.5
            // Code wraps badly; keep lines tight so a fence reads as a unit.
            s.lineHeightMultiple = 1.2
            s.paragraphSpacing = 0
        }
        return s
    }
}
