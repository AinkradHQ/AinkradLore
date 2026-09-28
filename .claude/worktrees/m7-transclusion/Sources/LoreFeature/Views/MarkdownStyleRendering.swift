import AppKit
import SwiftUI
import AinkradAppKit

/// Turns style spans into text attributes.
///
/// Split out of `MarkdownEditor` so that file stays about the editor's AppKit
/// wiring — completion panel, Cmd-click, scroll observation — and this one about
/// appearance, which Task 9 will keep changing.
@MainActor
enum MarkdownStyleRenderer {
    /// `nonisolated` so the paragraph styles — which are computed off the main
    /// actor — can size a callout's indent from the SAME number the drawing
    /// uses. An immutable `CGFloat` is safe to read from anywhere; the point is
    /// that there is exactly one of it.
    nonisolated static let baseSize: CGFloat = 14
    static var baseFont: NSFont { .monospacedSystemFont(ofSize: baseSize, weight: .regular) }
    /// The base font at semibold, for a callout's title.
    static var boldBaseFont: NSFont {
        .monospacedSystemFont(ofSize: baseSize, weight: .semibold)
    }

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
    static func apply(_ spans: [StyleSpan], to storage: NSTextStorage,
                      tokens: HostThemeTokens, theme: MarkdownTheme,
                      limitedTo window: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(tokens.foreground),
            // Body rhythm as the FLOOR, so line height and paragraph spacing
            // exist for ordinary prose — which is most of a note — and each
            // block kind then overrides only what it needs.
            .paragraphStyle: MarkdownParagraphStyles.style(for: .body, theme: theme)
        ], range: full)

        // Derived over ALL spans, before any windowing: nesting depth is a
        // property of the document, and counting only the spans that survive
        // the viewport window would make an indent change with the scroll.
        let depths = MarkdownListDepth.depths(of: spans)

        for (index, span) in spans.enumerated() {
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= full.length else { continue }
            if let window, NSIntersectionRange(r, window).length == 0 { continue }
            add(span.kind, in: r, to: storage, tokens: tokens, theme: theme,
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
    static func restyle(_ spans: [StyleSpan], at spanIndices: [Int],
                        depths: [Int], in range: NSRange, to storage: NSTextStorage,
                        tokens: HostThemeTokens, theme: MarkdownTheme) {
        let clamped = NSIntersectionRange(range,
                                          NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(tokens.foreground),
            .paragraphStyle: MarkdownParagraphStyles.style(for: .body, theme: theme)
        ], range: clamped)
        for index in spanIndices {
            guard index < spans.count else { continue }
            let span = spans[index]
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= storage.length else { continue }
            add(span.kind, in: r, to: storage, tokens: tokens, theme: theme,
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
    static func composeFont(in r: NSRange, storage: NSTextStorage,
                                    _ transform: (NSFont) -> NSFont) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: r) { value, sub, _ in
            runs.append((sub, (value as? NSFont) ?? baseFont))
        }
        for (sub, font) in runs {
            storage.addAttribute(.font, value: transform(font), range: sub)
        }
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
    private static func add(_ kind: StyleSpan.Kind, in r: NSRange,
                            to storage: NSTextStorage, tokens: HostThemeTokens,
                            theme: MarkdownTheme, listDepth: Int) {
        switch kind {
        case .heading(let level):
            // Foreground, not accentPrimary. Size and weight carry hierarchy;
            // colour is reserved for what is clickable. Reversing M2a here is
            // deliberate: a note should read as text, not as coloured bands.
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.boldFontMask),
                              to: .systemFont(ofSize: theme.headingSize(level)))
            }
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.foreground), range: r)
            storage.addAttribute(.paragraphStyle,
                                 value: MarkdownParagraphStyles.style(for: .heading(level),
                                                                      theme: theme),
                                 range: r)

        case .strong:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.boldFontMask),
                              to: .systemFont(ofSize: current.pointSize))
            }

        case .emphasis:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.italicFontMask),
                              to: .systemFont(ofSize: current.pointSize))
            }

        case .strikethrough:
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: r)

        case .highlight:
            // A tinted BACKGROUND, not a foreground change: highlighted text
            // must stay as readable as the prose around it, which a colour
            // swap does not guarantee against every theme.
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(tokens.accentSecondary).withAlphaComponent(0.28),
                                 range: r)

        case .footnoteReference:
            // Superscript, via baseline offset only — a DRAWING change, not
            // a text change. NOT at "the same size reduction Obsidian uses":
            // no font-size attribute is applied here, so the glyph stays
            // full size, just raised. See the M6 final review, Finding 5 —
            // that gap is a design decision left for the owner to make, not
            // fixed here; only the comment overclaiming it was wrong.
            storage.addAttribute(.baselineOffset, value: 4.0, range: r)
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.accentPrimary), range: r)

        case .footnoteDefinition:
            storage.addAttribute(.foregroundColor,
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
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.accentPrimary), range: r)
            if theme.renderTagsAsChips {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor(tokens.accentPrimary).withAlphaComponent(0.14),
                                     range: r)
            }

        case .blockID:
            // Near-invisible when the caret is elsewhere. It is machinery the
            // author needs to be able to find, not something to read past.
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.foreground).withAlphaComponent(0.25),
                                 range: r)

        case .inlineCode:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current),
                              to: .monospacedSystemFont(ofSize: current.pointSize,
                                                        weight: .regular))
            }
            // No accent tint. Mono plus a background already says "code", and
            // the tint is what made every `code` span read as a coloured word
            // in the middle of a sentence.
            storage.addAttribute(.backgroundColor,
                                 value: NSColor(tokens.surfaceElevated).withAlphaComponent(0.6),
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
                Self.applying(Self.inheritedTraits(of: current),
                              to: .monospacedSystemFont(ofSize: current.pointSize,
                                                        weight: .regular))
            }
            // Over the PARAGRAPH, for the same reason the list case is — and
            // now for a reason that is reachable rather than theoretical. A
            // fence INSIDE a list item is indented, so its paragraph's first
            // character is the item's leading whitespace, which carries the
            // listItem style; `endEditing` then extends that over the fence and
            // the code style loses. Nothing made that possible until list items
            // started writing a paragraph style at all.
            storage.addAttribute(.paragraphStyle,
                                 value: MarkdownParagraphStyles.style(for: .codeBlock,
                                                                      theme: theme),
                                 range: (storage.string as NSString).paragraphRange(for: r))
            // Token colouring BEFORE the language label, so the label — which
            // sits on the opening fence line and is styled as a label, not as
            // code — wins where the two overlap.
            if let language, !language.isEmpty,
               let grammar = CodeGrammar.named(language) {
                highlightCode(in: r, grammar: grammar, storage: storage, tokens: tokens)
            }
            if let language, !language.isEmpty {
                styleLanguageLabel(language, in: r, storage: storage, tokens: tokens)
            }

        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: r)

        case .wikilink:
            // Colour, no underline. A wikilink already carries its own visible
            // `[[…]]` delimiters in Live Preview, so the underline was pure
            // noise on top of a marker the reader can already see.
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
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.foreground).withAlphaComponent(0.65),
                                 range: r)
            // The indent leaves room for the bar `MarkdownBlockBackgrounds`
            // draws in the margin; the bar is what says "quote". Paragraph
            // scoped for the same reason as the code case above: a quote nested
            // in a list item is indented, and its paragraph's first character
            // belongs to the item.
            storage.addAttribute(.paragraphStyle,
                                 value: MarkdownParagraphStyles.style(for: .blockQuote,
                                                                      theme: theme),
                                 range: (storage.string as NSString).paragraphRange(for: r))

        case .callout(let kind):
            // NOT the quote's dimmed foreground: a callout is emphasis, and
            // greying its body would work against the panel drawn behind it.
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.foreground), range: r)
            storage.addAttribute(.paragraphStyle,
                                 value: MarkdownParagraphStyles.style(for: .callout(kind),
                                                                      theme: theme),
                                 range: (storage.string as NSString).paragraphRange(for: r))

        case .calloutTitle(let kind):
            storage.addAttribute(.font, value: MarkdownStyleRenderer.boldBaseFont, range: r)
            storage.addAttribute(.foregroundColor,
                                 value: MarkdownBlockBackgrounds.Palette.calloutTint(kind,
                                                                                     tokens: tokens),
                                 range: r)

        case .table:
            // The table itself carries no text styling: its cells are ordinary
            // prose and style as such. What makes it a table is the alignment
            // (`MarkdownTableStyling`) and the rule drawn under its header, and
            // both need the collapse state, so neither can happen here.
            break

        case .tableHeader:
            composeFont(in: r, storage: storage) { current in
                Self.applying(Self.inheritedTraits(of: current).union(.boldFontMask),
                              to: current)
            }

        case .math(let isRendered):
            // Tinted either way, so an expression reads as mathematics rather
            // than as prose. When it does NOT render, this tint is the only
            // thing that happens to it — its `$` and its commands stay visible,
            // which is the honest presentation of something this editor cannot
            // draw. See `MarkdownMath`.
            storage.addAttribute(.foregroundColor,
                                 value: NSColor(tokens.accentSecondary)
                                     .withAlphaComponent(isRendered ? 1.0 : 0.85),
                                 range: r)

        case .checkbox:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: r)

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
            let leading = leadingIndentWidth(from: paragraph.location,
                                             upTo: r.location, in: full)
            storage.addAttribute(.paragraphStyle,
                                 value: MarkdownParagraphStyles.listItemStyle(
                                    depth: listDepth, leadingIndent: leading,
                                    theme: theme),
                                 range: paragraph)

        case .marker:
            // Deliberately inert HERE. Marker spans exist so a later task can
            // dim or collapse syntax characters; giving them an appearance now
            // would change every note's look ahead of that decision, and the
            // rendering above already styles the whole source range including
            // its markers.
            break
        }
    }

    /// The rendered width of the whitespace between a paragraph's start and
    /// `end` — i.e. how far a nested list item's bullet has been pushed right
    /// by source indentation alone.
    ///
    /// Measured, not counted: the base font is monospaced, so one space's
    /// advance times the count is exact, and caching that advance keeps this
    /// off the per-span allocation path. A non-whitespace character before
    /// `end` means this is not leading indentation and the answer is zero.
    private static let spaceAdvance: CGFloat =
        (" " as NSString).size(withAttributes: [.font: baseFont]).width

    private static func leadingIndentWidth(from start: Int, upTo end: Int,
                                           in text: NSString) -> CGFloat {
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
            $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound
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

