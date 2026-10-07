import AinkradAppKit
import AppKit
import SwiftUI

/// Turns style spans into text attributes.
///
/// Split out of `MarkdownEditor` so that file stays about the editor's AppKit
/// wiring — completion panel, Cmd-click, scroll observation — and this one about
/// appearance, which Task 9 will keep changing.
@MainActor
enum MarkdownStyleRenderer {
    /// The font a run falls back to when the storage carries none.
    ///
    /// A LAST RESORT, and nothing else. `baseSize`/`baseFont`/`boldBaseFont`
    /// used to live here as the editor's real body font — a monospaced 14 pt
    /// constant that every drawing helper, every measurement and the whole
    /// styling path reached for directly. That made the body font a property
    /// of this enum rather than of the document being rendered, which is why
    /// `EditorSettings.bodySize` could be computed correctly and then change
    /// nothing on screen. The font now belongs to `MarkdownTheme` and arrives
    /// with the `theme` parameter every entry point here already takes.
    ///
    /// `composeFont` still needs an answer for a run with no `.font` attribute
    /// at all, which cannot happen on any path that goes through `apply` or
    /// `restyle` — both set one over their whole range first — but is not
    /// worth a crash if it ever does.
    static let fallbackFont: NSFont = .systemFont(ofSize: 15)

    /// How much text on either side of the visible range is styled in viewport
    /// mode. Big enough that a flick of the scroll wheel lands inside
    /// already-styled text; small enough to stay far cheaper than the document.
    static let viewportMargin = 20_000

    /// Applies `spans` to `storage`.
    ///
    /// ALWAYS clears first, over the whole string, even when `window` limits
    /// what is then styled. Clearing only the window would let an attribute
    /// survive the text that earned it — text that stops being bold but stays
    /// bold on screen — which is the exact failure this guards. `setAttributes`
    /// over the full range collapses the storage to one run, so the clear is
    /// cheap regardless of how much was styled before.
    static func apply(
        _ spans: [StyleSpan], to storage: NSTextStorage,
        tokens: HostThemeTokens, theme: MarkdownTheme,
        limitedTo window: NSRange?
    ) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: theme.bodyFont,
                .foregroundColor: NSColor(tokens.foreground),
                // Body rhythm as the FLOOR, so line height and paragraph spacing
                // exist for ordinary prose — which is most of a note — and each
                // block kind then overrides only what it needs.
                .paragraphStyle: MarkdownParagraphStyles.style(for: .body, theme: theme),
            ], range: full)

        // Derived over ALL spans, before any windowing: nesting depth is a
        // property of the document, and counting only the spans that survive
        // the viewport window would make an indent change with the scroll.
        let depths = MarkdownListDepth.depths(of: spans)

        for (index, span) in spans.enumerated() {
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= full.length else { continue }
            if let window, NSIntersectionRange(r, window).length == 0 { continue }
            add(
                span.kind, in: r, to: storage, tokens: tokens, theme: theme,
                listDepth: depths[index])
        }
        storage.endEditing()
    }

    /// Re-attributes ONE range — a single reveal block — from the spans that
    /// live in it, without touching a character outside it.
    ///
    /// This is the caret path. `apply` clears the whole document before it
    /// styles, deliberately, so that an attribute can never outlive the text
    /// that earned it; running it because the user pressed the down arrow means
    /// re-attributing the entire note every time the caret crosses a blank
    /// line, which on a long note is exactly the lag this milestone exists to
    /// remove. Reveal changes what is COLLAPSED inside two blocks, so only two
    /// blocks need rebuilding.
    ///
    /// Safe because a reveal block is bounded by blank lines and every markdown
    /// span sits inside one: the spans handed in are the block's own, and
    /// nothing they style — including the paragraph ranges the block kinds
    /// expand to — can reach past the block's ends.
    ///
    /// - Parameter spanIndices: positions into `spans`, so the caller's cached
    ///   per-block index and its globally-derived `depths` stay aligned.
    static func restyle(
        _ spans: [StyleSpan], at spanIndices: [Int],
        depths: [Int], in range: NSRange, to storage: NSTextStorage,
        tokens: HostThemeTokens, theme: MarkdownTheme
    ) {
        let clamped = NSIntersectionRange(
            range,
            NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: theme.bodyFont,
                .foregroundColor: NSColor(tokens.foreground),
                .paragraphStyle: MarkdownParagraphStyles.style(for: .body, theme: theme),
            ], range: clamped)
        for index in spanIndices {
            guard index < spans.count else { continue }
            let span = spans[index]
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= storage.length else { continue }
            add(
                span.kind, in: r, to: storage, tokens: tokens, theme: theme,
                listDepth: index < depths.count ? depths[index] : 0)
        }
        storage.endEditing()
    }

    // MARK: - Font composition

    /// Rewrites the `.font` attribute over `r` as a FUNCTION of the font
    /// already there, run by run.
    ///
    /// Spans arrive parent-first (`MarkdownSpanBuilder` appends a node then
    /// `descendInto`s it) and `apply` walks them in array order, so a child's
    /// font landed on top of its parent's and REPLACED it: `# A **B** C` drew
    /// `B` at the base 14 pt inside a 24 pt heading, `**bold _and_ italic**`
    /// drew the inner run italic-and-not-bold, and inline code in a heading
    /// dropped to base size. Composition has to accumulate, so each kind now
    /// states a DELTA — "add bold", "keep the size, switch to monospace" — and
    /// reads the rest from what the ancestors already put there.
    ///
    /// The runs are collected BEFORE any are written: mutating attributes from
    /// inside `enumerateAttribute`'s block mutates the thing being enumerated.
    /// Internal rather than `private` since the code-highlighting half moved to
    /// `MarkdownCodeStyling.swift` for the 500-line ceiling — Swift's `private`
    /// is file-scoped, and comments need italics composed onto the monospaced
    /// font the same way every other kind composes its traits. Still an
    /// implementation detail outside this module.
    static func composeFont(
        in r: NSRange, storage: NSTextStorage,
        _ transform: (NSFont) -> NSFont
    ) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: r) { value, sub, _ in
            runs.append((sub, (value as? NSFont) ?? fallbackFont))
        }
        for (sub, font) in runs {
            storage.addAttribute(.font, value: transform(font), range: sub)
        }
    }

    /// The size a monospaced run takes, given the font it is replacing.
    ///
    /// In ordinary prose the answer is `theme.monoFont`'s own size — already
    /// scaled below the body size, since SF Mono reads larger than SF Text at
    /// equal points. Inside a HEADING the run is bigger than body, and must
    /// stay proportional to the heading rather than snapping down to the code
    /// size: `# A `code` C` sets the code at the heading's size, which is what
    /// `M2aMergeFixTests` has pinned since M2a. The same ratio applies either
    /// way, so the two cases differ only in what they scale FROM.
    static func monoSize(replacing current: NSFont, theme: MarkdownTheme) -> CGFloat {
        current.pointSize == theme.bodyFont.pointSize
            ? theme.monoFont.pointSize
            : current.pointSize * MarkdownTheme.monoRatio
    }

    /// The traits a child span must carry over from its ancestors. Bold and
    /// italic only — those are the two the markdown kinds compose. Anything
    /// else (a condensed or expanded face) is not something this renderer sets,
    /// so re-applying it would be inventing state.
    static func inheritedTraits(of font: NSFont) -> NSFontTraitMask {
        let traits = NSFontManager.shared.traits(of: font)
        var inherited: NSFontTraitMask = []
        if traits.contains(.boldFontMask) { inherited.insert(.boldFontMask) }
        if traits.contains(.italicFontMask) { inherited.insert(.italicFontMask) }
        return inherited
    }

    /// `convert` returns the font UNCHANGED when the family has no such face,
    /// so an unavailable monospaced-italic degrades to upright rather than
    /// falling back to a different family and changing the metrics mid-line.
    static func applying(_ traits: NSFontTraitMask, to font: NSFont) -> NSFont {
        var result = font
        if traits.contains(.boldFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    /// Syntax markers stay VISIBLE — this is Live Preview, not WYSIWYG — so
    /// every case styles the span's whole source range, markers included.
    private static func add(
        _ kind: StyleSpan.Kind, in r: NSRange,
        to storage: NSTextStorage, tokens: HostThemeTokens,
        theme: MarkdownTheme, listDepth: Int
    ) {
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
                    : NSColor(tokens.foreground).withAlphaComponent(0.85),
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

        // Both compose onto `current` ITSELF, not onto a fresh
        // `.systemFont(ofSize: current.pointSize)`. Re-basing kept the size and
        // discarded the FAMILY, which was invisible while the body font was the
        // only family in play and became a bug the moment it was not: bold
        // inside a monospaced code span, or inside a heading, switched typeface
        // mid-run. `.tableHeader` below already did it this way and is the
        // model being followed.
        case .strong:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current).union(.boldFontMask),
                    to: current)
            }

        case .emphasis:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current).union(.italicFontMask),
                    to: current)
            }

        case .strikethrough:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: r)
            // Struck text recedes as well as being crossed out, which is what
            // Obsidian's `--text-faint` does for it. A line through text at
            // full contrast reads as emphasis; the point of the construct is
            // the opposite.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(0.55),
                range: r)

        case .highlight:
            // A tinted BACKGROUND, not a foreground change: highlighted text
            // must stay as readable as the prose around it, which a colour
            // swap does not guarantee against every theme.
            storage.addAttribute(
                .backgroundColor,
                value: NSColor(tokens.accentSecondary).withAlphaComponent(0.28),
                range: r)

        case .footnoteReference:
            // A real superscript: raised AND reduced. Both are drawing changes,
            // never text changes — no character is added, removed or replaced.
            //
            // The size reduction is what M6 left undone (final review, Finding
            // 5) and it is done now, so the reference reads as a mark on the
            // sentence rather than as a bracketed word inside it. The offset is
            // theme-relative rather than the flat 4.0 it was: at Comfortable's
            // 17 pt body a fixed 4 pt barely clears the baseline.
            composeFont(in: r, storage: storage) { $0.withSize($0.pointSize * 0.75) }
            storage.addAttribute(.baselineOffset, value: theme.bodySize * 0.28, range: r)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.accentPrimary), range: r)

        case .footnoteDefinition:
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground)
                    .withAlphaComponent(LoreMetrics.secondaryText),
                range: r)

        case .tag:
            // The `#` STAYS VISIBLE — Obsidian keeps it, and without it a tag
            // chip is indistinguishable from a link chip.
            //
            // `theme.renderTagsAsChips`, not `settings` — `settings` is never
            // in scope here; `MarkdownTheme` resolves it at construction. See
            // `EditorSettings.renderTagsAsChips`.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.accentPrimary), range: r)
        // The chip itself is DRAWN — see `MarkdownBlockBackgrounds.Kind
        // .tagPill`. It used to be a `.backgroundColor` here, which is a
        // per-glyph attribute and therefore cannot round its corners or
        // pad its ends: the result was a tight rectangle around the
        // letters that read as a selection, not as a tag. Nothing is
        // written here for the chip any more; the setting is honoured
        // where the region is built.

        case .blockID:
            // Near-invisible when the caret is elsewhere. It is machinery the
            // author needs to be able to find, not something to read past.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(0.25),
                range: r)

        case .inlineCode:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current),
                    to: .monospacedSystemFont(
                        ofSize: Self.monoSize(replacing: current, theme: theme),
                        weight: .regular))
            }
        // The pill is DRAWN — see `MarkdownBlockBackgrounds.Kind
        // .inlineCodePill`. It was a `.backgroundColor` here, which is a
        // per-glyph attribute: it cannot round its corners, cannot pad its
        // ends, and fills the whole LINE BOX rather than the text. At a
        // 1.5 line height that is half again as tall as the glyphs, which
        // is why the highlight looked like it belonged to the line above.
        // Nothing is written here for it any more.

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
                highlightCode(in: r, grammar: grammar, storage: storage, tokens: tokens)
            }
            if let language, !language.isEmpty {
                styleLanguageLabel(
                    language, in: r, storage: storage, tokens: tokens,
                    theme: theme)
            }

        // Both links: colour at rest, underline ON HOVER only — see
        // `MarkdownEditor.Coordinator.hoverChanged(to:)`.
        //
        // `.link` used to carry a PERSISTENT underline and `.wikilink` none,
        // justified by the wikilink's own visible `[[…]]`. But in the state
        // the reader actually looks at, those brackets are COLLAPSED, so the
        // asymmetry amounted to underlining one kind of link and not the
        // other for a reason that is invisible at the moment it applies.
        // Obsidian underlines both, and only under the pointer.
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .wikilink:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .embed:
            // The FALLBACK look — plain wikilink colouring, over the TARGET
            // text only (the `![[`/`]]` markers are separate `.marker(of:
            // .wikilink)` spans and style themselves) — for an embed that
            // `EmbedRendering` has not decorated: an unresolved target, a
            // resolver-less caller (a test, a plain-text engine), or a block
            // the caret is currently INSIDE, which `EmbedRendering.
            // applyEmbeds` deliberately leaves as plain revealed source so a
            // typo'd target can be edited — see that function's doc comment.
            // `applyEmbeds` runs immediately after this in both `renderStyles`
            // (a full render) and `restyleBlock` (the per-block caret path,
            // fix round 1 Critical 2), and overwrites this wherever it can
            // resolve the target AND the block is not the one being edited.
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .blockQuote:
            // 0.85, not the 0.65 this used to be. `LoreMetrics.secondaryText`
            // names 0.75 as the floor at which supporting text still meets
            // 4.5:1, and quote BODY is not supporting text — it is prose the
            // reader is meant to read. The bar and the indent already say
            // "quote"; dimming below the floor as well was saying it twice, the
            // second time by making it harder to read.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(0.85),
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
                    tokens: tokens),
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
                    .withAlphaComponent(isRendered ? 1.0 : 0.85),
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
                value: NSColor(tokens.foreground).withAlphaComponent(0.55),
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
                value: NSColor(tokens.foreground).withAlphaComponent(0.40),
                range: r)
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

    // MARK: - Collapsing hidden markers

    /// Merges overlapping and adjacent ranges into a minimal covering set.
    ///
    /// Marker ranges are NOT disjoint. A nested blockquote `>> a` emits an
    /// outer `">> "` marker and an inner `"> "` marker that overlap, and two
    /// abutting markers (`**` immediately followed by `*`) produce ranges that
    /// touch. Applying attributes range-by-range would still be correct for
    /// `.font`, but the overlap makes the work quadratic in the worst case and
    /// makes any future non-idempotent attribute (a width reservation, a
    /// count) silently wrong. Coalescing first removes the whole class.
    ///
    /// Adjacent ranges are merged too (`<=`, not `<`): `a..<b` and `b..<c`
    /// describe one contiguous stretch of hidden syntax.
    static func coalesce(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Makes `ranges` take no visual space, WITHOUT altering the text.
    ///
    /// A near-zero font rather than a zero font: AppKit treats a zero-point
    /// font as invalid and substitutes the system default, which would make
    /// hidden markers render at FULL size — the opposite of the intent.
    ///
    /// The document string is never touched. Collapsing is attributes and
    /// visibility only, so every offset the search index, the link graph and
    /// the MCP tools hold stays valid by construction. If this ever starts
    /// deleting or rewriting characters, a display concern has reached the
    /// document — after fourteen data-loss defects in M0/M1, that is the one
    /// trade this codebase does not make.
    static func collapse(_ ranges: [Range<Int>], in storage: NSTextStorage) {
        let length = storage.length
        let collapsedFont = NSFont.systemFont(ofSize: 0.01)
        storage.beginEditing()
        for range in coalesce(ranges) {
            let ns = NSRange(location: range.lowerBound, length: range.count)
            guard ns.location >= 0, ns.location + ns.length <= length else { continue }
            storage.addAttribute(.font, value: collapsedFont, range: ns)
            storage.addAttribute(.kern, value: CGFloat(0), range: ns)
        }
        storage.endEditing()
    }

    /// The visible character range plus a margin.
    ///
    /// Deliberately does NOT touch `tv.layoutManager`: reading that property on
    /// a TextKit 2 text view silently downgrades the whole view to TextKit 1.
    /// `characterIndexForInsertion(at:)` is the version-agnostic answer, and is
    /// already the API `LinkTextView` uses for Cmd-click.
    static func viewportWindow(of tv: NSTextView) -> NSRange {
        let length = (tv.string as NSString).length
        let visible = tv.visibleRect
        guard !visible.isEmpty else { return NSRange(location: 0, length: length) }
        let a = tv.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: visible.minY))
        let b = tv.characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY))
        let lower = max(0, min(a, b) - viewportMargin)
        let upper = min(length, max(a, b) + viewportMargin)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

}
