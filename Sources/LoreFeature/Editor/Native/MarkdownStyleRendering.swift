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
        case .strong, .emphasis, .strikethrough, .highlight, .footnoteReference, .tag, .blockID,
            .inlineCode, .link, .wikilink, .embed:
            addInline(kind, in: r, to: storage, tokens: tokens, theme: theme)
        default:
            addBlock(kind, in: r, to: storage, tokens: tokens, theme: theme, listDepth: listDepth)
        }
    }
}
