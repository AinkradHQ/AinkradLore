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
                    && span.range.upperBound <= top.upperBound)
            {
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
    static func listItemStyle(
        depth: Int, leadingIndent: CGFloat,
        theme: MarkdownTheme
    ) -> NSParagraphStyle {
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
    static func embedImageStyle(
        basedOn base: NSParagraphStyle?, height: CGFloat,
        theme: MarkdownTheme
    ) -> NSParagraphStyle {
        let base = base ?? style(for: .body, theme: theme)
        guard let s = base.mutableCopy() as? NSMutableParagraphStyle else { return base }
        s.minimumLineHeight = height
        s.maximumLineHeight = height
        return s
    }

    /// A heading's style, with the space ABOVE it collapsed when the thing
    /// above it is another heading.
    ///
    /// `headingSpacingBefore` is ~1.35x the heading's own size, which is right
    /// when a heading follows prose — it is what stops the heading crowding
    /// the paragraph it comes after. Between two headings it is wrong twice
    /// over: the previous heading has already contributed its own
    /// `paragraphSpacing` below itself, and there is no body text for the gap
    /// to separate the new heading FROM. `## A` immediately followed by
    /// `### B` stacked both, leaving a band of dead air that reads as a
    /// missing paragraph.
    ///
    /// Collapsed to the PREVIOUS heading's spacing-after, not to zero: two
    /// headings still need to be told apart, just by a normal gap rather than
    /// a section break.
    static func headingStyle(
        level: Int, follows previousLevel: Int?,
        theme: MarkdownTheme
    ) -> NSParagraphStyle {
        let base = style(for: .heading(level), theme: theme)
        guard let previousLevel,
            let s = base.mutableCopy() as? NSMutableParagraphStyle
        else { return base }
        s.paragraphSpacingBefore = theme.headingSpacingAfter(previousLevel)
        return s
    }

    /// The level of the heading immediately above the paragraph starting at
    /// `paragraphStart`, or `nil` when what is above is not a heading.
    ///
    /// Read from the TEXT rather than from the span list, deliberately. The
    /// per-block restyle path (`MarkdownStyleRenderer.restyle`) is handed only
    /// its own block's spans — two headings separated by a blank line are two
    /// blocks — so a span-based answer would be correct on a full render and
    /// silently wrong the moment the caret moved. The text is available to
    /// both paths and says the same thing to each.
    ///
    /// ATX only (`## A`), and a hash run must be followed by a space to count:
    /// `#tag` at the start of a line is not a heading, and CommonMark agrees.
    /// A setext heading is not detected — its own underline is the line above,
    /// so the lookback would have to distinguish `---` the underline from
    /// `---` the rule, and answering "not a heading" merely keeps the spacing
    /// that was there before.
    static func headingLevelAbove(paragraphStart: Int, in text: NSString) -> Int? {
        var index = paragraphStart
        // Back over the blank lines between the two, if any.
        while index > 0 {
            let unit = text.character(at: index - 1)
            guard unit == 0x0A || unit == 0x0D || unit == 0x20 || unit == 0x09 else { break }
            index -= 1
        }
        guard index > 0 else { return nil }
        let previous = text.lineRange(for: NSRange(location: index - 1, length: 0))
        var scan = previous.location
        let limit = min(NSMaxRange(previous), text.length)
        // Up to three spaces of indent are still a heading; four make it code.
        var indent = 0
        while scan < limit, text.character(at: scan) == 0x20, indent < 3 {
            scan += 1
            indent += 1
        }
        var hashes = 0
        while scan < limit, text.character(at: scan) == 0x23 {
            scan += 1
            hashes += 1
        }
        guard hashes >= 1, hashes <= 6, scan < limit,
            text.character(at: scan) == 0x20
        else { return nil }
        return hashes
    }

    /// The line a thematic break occupies once its source has collapsed.
    ///
    /// A fixed height, like an embedded image's: the source is 0.01 pt while
    /// hidden, so without this the rule would be drawn through a line only a
    /// point tall and land on the paragraph beneath it. The height is the room
    /// the rule needs plus air on both sides — a `---` is a separator, and a
    /// separator with no space around it separates nothing.
    static func thematicBreakStyle(theme: MarkdownTheme) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        let height = max(12, theme.paragraphSpacing * 1.5)
        s.minimumLineHeight = height
        s.maximumLineHeight = height
        // Zero, for the reason `.body` is zero: the blank lines an author puts
        // around a rule are real lines and already space it.
        s.paragraphSpacing = 0
        return s
    }

    static func style(for block: MarkdownBlock, theme: MarkdownTheme) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineHeightMultiple = theme.lineHeightMultiple
        s.paragraphSpacing = theme.paragraphSpacing

        switch block {
        case .body:
            // NO paragraph spacing, and this is the single biggest correction
            // in M9.
            //
            // `paragraphSpacing` is an AppKit paragraph attribute, and AppKit's
            // paragraph is a run of text ending at a NEWLINE — not markdown's
            // paragraph, which ends at a BLANK line. So 12 pt was being pushed
            // between the two source lines of
            //
            //     Manual walkthrough for branch `x`.
            //     Covers all 8 implemented tasks.
            //
            // which markdown says is ONE paragraph with a soft break, and
            // Obsidian renders as two adjacent lines. Worse, a blank line is
            // itself a paragraph: it took a full line box (27 pt) AND the
            // spacing after the paragraph above it AND its own spacing after —
            // 51 pt of dead air where the source asked for one blank line.
            // Measured on a real note, that is what made the document read as
            // sparse and broken next to Obsidian.
            //
            // Obsidian's Live Preview does not do this: every source line is a
            // line, a blank line is a blank line, and the separation between
            // paragraphs IS the blank line the author typed. Nothing is added.
            // Setting this to zero is what matches it — the blank line already
            // carries the gap, and doubling it was the bug.
            s.paragraphSpacing = 0

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
            let indent =
                MarkdownBlockBackgrounds
                .calloutTextIndent(iconSize: theme.bodyFont.pointSize)
            s.firstLineHeadIndent = indent
            s.headIndent = indent
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
