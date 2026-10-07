import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownStyleRenderer {
    /// The block kinds of `add(_:)` — paragraph-level styling. The inline
    /// kinds are listed as a no-op so this switch stays exhaustive.
    static func addBlock(
        _ kind: StyleSpan.Kind, in r: NSRange,
        to storage: NSTextStorage,
        theme: MarkdownTheme, listDepth: Int
    ) {
        let tokens = theme.tokens
        switch kind {
        case .heading(let level):
            // Foreground, not accentPrimary. Size and weight carry hierarchy;
            // colour is reserved for what is clickable. Reversing M2a here is
            // deliberate: a note should read as text, not as coloured bands.
            // Weight comes from `systemFont(ofSize:weight:)`, and `.boldFontMask`
            // is deliberately NOT unioned on top of it: doing so rounds semibold
            // back up to bold and collapses `headingWeight`'s distinction between
            // the top and the bottom of the ramp. Inherited traits still compose,
            // so `# A *b*` keeps its italic.
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current),
                    to: .systemFont(
                        ofSize: theme.headingSize(level),
                        weight: theme.headingWeight(level)))
            }
            // h1–h3 at full foreground; h4–h6 faded slightly. Size separates the
            // top of the ramp on its own, and the bottom — where the steps are
            // 1–2 pt — needs a second signal. A FADE rather than a hue, so the
            // rule that accent means "you can click this" is untouched.
            storage.addAttribute(
                .foregroundColor,
                value: level <= 3
                    ? NSColor(tokens.foreground)
                    : NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o85),
                range: r)
            let full = storage.string as NSString
            let paragraph = full.paragraphRange(for: r)
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.headingStyle(
                    level: level,
                    follows: MarkdownParagraphStyles.headingLevelAbove(
                        paragraphStart: paragraph.location, in: full),
                    theme: theme),
                range: r)

        case .footnoteDefinition:
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground)
                    .withAlphaComponent(theme.skin.opacity.o75),
                range: r)

        case .codeBlock(let language):
            // REVISITED, not ignored. M2a defended an `accentSecondary` tint
            // over the whole block on the grounds that without it a fence would
            // read as a blockquote. `MarkdownBlockBackgrounds` now draws a
            // full-width panel for code and a bar for quotes, so the two are
            // unmistakable by shape and that argument no longer holds — and the
            // tint's own cost (it repainted every note into coloured bands) is
            // exactly what this milestone exists to undo. A per-glyph
            // `.backgroundColor` is not used here either: it stops at the end of
            // each line, giving a ragged staircase instead of a panel.
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current),
                    to: .monospacedSystemFont(
                        ofSize: Self.monoSize(replacing: current, theme: theme),
                        weight: .regular))
            }
            // Over the PARAGRAPH, for the same reason the list case is — and
            // now for a reason that is reachable rather than theoretical. A
            // fence INSIDE a list item is indented, so its paragraph's first
            // character is the item's leading whitespace, which carries the
            // listItem style; `endEditing` then extends that over the fence and
            // the code style loses. Nothing made that possible until list items
            // started writing a paragraph style at all.
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.style(
                    for: .codeBlock,
                    theme: theme),
                range: (storage.string as NSString).paragraphRange(for: r))
            // Token colouring BEFORE the language label, so the label — which
            // sits on the opening fence line and is styled as a label, not as
            // code — wins where the two overlap.
            if let language, !language.isEmpty,
                let grammar = CodeGrammar.named(language)
            {
                highlightCode(in: r, grammar: grammar, storage: storage, theme: theme)
            }
            if let language, !language.isEmpty {
                styleLanguageLabel(
                    language, in: r, storage: storage,
                    theme: theme)
            }

        case .blockQuote:
            // 0.85, not the 0.65 this used to be. `LoreMetrics.secondaryText`
            // names 0.75 as the floor at which supporting text still meets
            // 4.5:1, and quote BODY is not supporting text — it is prose the
            // reader is meant to read. The bar and the indent already say
            // "quote"; dimming below the floor as well was saying it twice, the
            // second time by making it harder to read.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o85),
                range: r)
            // The indent leaves room for the bar `MarkdownBlockBackgrounds`
            // draws in the margin; the bar is what says "quote". Paragraph
            // scoped for the same reason as the code case above: a quote nested
            // in a list item is indented, and its paragraph's first character
            // belongs to the item.
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.style(
                    for: .blockQuote,
                    theme: theme),
                range: (storage.string as NSString).paragraphRange(for: r))

        case .callout(let kind):
            // NOT the quote's dimmed foreground: a callout is emphasis, and
            // greying its body would work against the panel drawn behind it.
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.foreground), range: r)
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.style(
                    for: .callout(kind),
                    theme: theme),
                range: (storage.string as NSString).paragraphRange(for: r))

        case .calloutTitle(let kind):
            storage.addAttribute(.font, value: theme.boldBodyFont, range: r)
            storage.addAttribute(
                .foregroundColor,
                value: MarkdownBlockBackgrounds.Palette.calloutTint(
                    kind,
                    theme: theme),
                range: r)

        case .thematicBreak:
            // No text styling at all: every character of the line is notation,
            // it collapses whole, and what the reader sees is the rule
            // `MarkdownBlockBackgrounds` draws. Reserving the line's HEIGHT is
            // the one thing needed here, or a collapsed rule leaves a 0.01 pt
            // line with a rule painted through the paragraph below it.
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.thematicBreakStyle(theme: theme),
                range: (storage.string as NSString).paragraphRange(for: r))

        case .table:
            // The table itself carries no text styling: its cells are ordinary
            // prose and style as such. What makes it a table is the alignment
            // (`MarkdownTableStyling`) and the rule drawn under its header, and
            // both need the collapse state, so neither can happen here.
            break

        case .tableHeader:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current).union(.boldFontMask),
                    to: current)
            }

        case .math(let isRendered):
            // Tinted either way, so an expression reads as mathematics rather
            // than as prose. When it does NOT render, this tint is the only
            // thing that happens to it — its `$` and its commands stay visible,
            // which is the honest presentation of something this editor cannot
            // draw. See `MarkdownMath`.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.accentSecondary)
                    .withAlphaComponent(isRendered ? 1.0 : theme.skin.opacity.o85),
                range: r)

        case .checkbox(let done):
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: r)
            // A DONE task strikes and fades its own line — which is most of
            // what makes a task list scannable, and the part a drawn box
            // cannot say on its own. Obsidian does the same.
            //
            // Over the PARAGRAPH, for the reason the list case spells out:
            // `endEditing` extends each paragraph's FIRST character's
            // attributes across it, and the checkbox span starts partway in.
            // The item's own children (a link, inline code) are appended after
            // this span and still win over their own ranges, so a link inside
            // a finished task keeps its colour and merely gains the line.
            guard done else { break }
            let paragraph = (storage.string as NSString).paragraphRange(for: r)
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue, range: paragraph)
            storage.addAttribute(
                .foregroundColor,
                value: theme.color(theme.skin.text.muted),
                range: paragraph)

        case .listItem:
            // Foreground unchanged by design: a list item is most of a note, and
            // tinting it would tint the note. Its children still style.
            //
            // The INDENT is the whole of a list's appearance, and until now
            // nothing supplied a depth, so `MarkdownParagraphStyles`' list case
            // was unreachable in practice. `listDepth` comes from containment —
            // see `MarkdownListDepth` — and because spans are applied
            // parent-first a nested item's deeper indent lands on top of its
            // parent's, over its own range only.
            //
            // Applied over the PARAGRAPH, not the span. A nested item's range
            // begins at its bullet, after the line's leading indent — but
            // `NSTextStorage.endEditing` fixes paragraph attributes by
            // extending the style of each paragraph's FIRST character across
            // the whole paragraph. The leading spaces belong only to the
            // ancestor's span, so the ancestor's shallower indent won every
            // nested line and lists rendered flat no matter what depth said.
            let full = storage.string as NSString
            let paragraph = full.paragraphRange(for: r)
            // The HANG is derived, not assumed. A nested item's source
            // indentation is real, visible characters that no marker collapses,
            // so its first line starts at `firstLineHeadIndent` PLUS the width
            // of that whitespace — and a fixed `headIndent` therefore put every
            // wrapped nested line to the LEFT of the text it should hang under.
            let leading = leadingIndentWidth(
                from: paragraph.location,
                upTo: r.location, in: full,
                spaceAdvance: theme.spaceAdvance)
            storage.addAttribute(
                .paragraphStyle,
                value: MarkdownParagraphStyles.listItemStyle(
                    depth: listDepth, leadingIndent: leading,
                    theme: theme),
                range: paragraph)

        case .marker:
            // Syntax recedes. Obsidian dims revealed markers rather than
            // showing them at the same contrast as the prose they delimit, and
            // that is most of why entering a construct there feels gentle
            // instead of like a flash of raw source.
            //
            // Costs nothing when the marker is HIDDEN: `collapse` puts a
            // 0.01 pt font on it, at which a foreground colour is unobservable.
            // So this only ever describes the revealed state.
            //
            // 0.40 is below `LoreMetrics.secondaryText` (0.75) on purpose.
            // That floor is about TEXT — captions, hints, prose the reader
            // reads. These are syntax characters standing next to their own
            // content, and the same exemption `.blockID` (0.25) already takes
            // applies: they must be findable, not readable.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o40),
                range: r)

        case .strong, .emphasis, .strikethrough, .highlight, .footnoteReference, .tag, .blockID,
            .inlineCode, .link, .wikilink, .embed:
            break
        }
    }

    /// The rendered width of the whitespace between a paragraph's start and
    /// `end` — i.e. how far a nested list item's bullet has been pushed right
    /// by source indentation alone.
    ///
    /// Counted here, MEASURED by the theme. Leading indentation is spaces and
    /// tabs only, so one space's advance times the count is exact for any
    /// font, proportional or not — what changes is that the advance is no
    /// longer a constant, because the font now moves with density and zoom.
    ///
    /// The advance arrives as a parameter rather than being measured here.
    /// This runs once per list-item span on the styling path, and
    /// `size(withAttributes:)` per span was measurable on a list-heavy
    /// document; `MarkdownTheme.spaceAdvance` measures it once per theme
    /// instead. A non-whitespace character before `end` means this is not
    /// leading indentation and the answer is zero.
    private static func leadingIndentWidth(
        from start: Int, upTo end: Int,
        in text: NSString,
        spaceAdvance: CGFloat
    ) -> CGFloat {
        guard end > start, end <= text.length else { return 0 }
        var count = 0
        for offset in start..<end {
            let unit = text.character(at: offset)
            // A tab counts as one indent unit here rather than being expanded:
            // tab stops are a paragraph-style concern this does not own, and
            // under-counting hangs the line slightly left rather than wrongly.
            guard unit == 0x20 || unit == 0x09 else { return 0 }
            count += 1
        }
        return CGFloat(count) * spaceAdvance
    }
}
