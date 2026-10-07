import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownBlockBackgrounds {
    /// What a region looks like, which is all the drawing needs to know.
    enum Kind: Equatable {
        /// A full-width panel behind a fenced code block.
        case codePanel
        /// A vertical bar in the left margin of a blockquote.
        case quoteBar
        /// The substitute for a COLLAPSED list marker, drawn in the gutter to
        /// the left of the item's text: `•` for `-`/`*`/`+`, and the item's own
        /// ordinal for a numbered list.
        ///
        /// Lists were the one construct that got its marker hidden with nothing
        /// put back, so an unfocused ordered list lost its numbering entirely.
        /// The associated value is what to DRAW, never what the document says —
        /// the source text is untouched, as everywhere else here.
        case listMarker(String)
        /// The substitute for a COLLAPSED task marker: a real checkbox, drawn
        /// in the gutter where `[ ]` / `[x]` used to be spelled out.
        ///
        /// A task item draws this INSTEAD of a bullet, not as well as one.
        /// Obsidian shows one control per task, and a note that drew `• ☐` on
        /// every line would read as two lists interleaved.
        case checkbox(Bool)
        /// A drawn horizontal rule, standing in for a collapsed `---`.
        case rule
        /// The rounded pill behind an inline `` `code` `` span.
        ///
        /// Drawn for the same reason the tag pill is: `.backgroundColor` is a
        /// per-glyph attribute, so it cannot be rounded or padded and it takes
        /// the FULL LINE BOX — which is why the highlight sat taller than the
        /// text and floated above it, the grey bar visible around
        /// `feat/pr-172-frontend-adoption` in Ahmed's screenshots.
        ///
        /// Unlike a tag, inline code CAN wrap: it may contain spaces, so a
        /// long span breaks across two lines. One union rect would paint a
        /// block over both lines and the gap between them, so this is drawn
        /// per LINE FRAGMENT.
        case inlineCodePill
        /// The rounded pill behind an inline `#tag`.
        ///
        /// DRAWN rather than attributed, unlike the flat `.backgroundColor`
        /// this replaces. A per-glyph background cannot be padded or rounded,
        /// so a "chip" was a tight square rectangle hugging the letters —
        /// which reads as a selection highlight or a rendering fault, not as a
        /// tag. A tag never wraps (it contains no spaces), so one bounding
        /// rect is always the whole of it — which is why this is thirty lines
        /// and the code panel, which does wrap, needed sixty.
        case tagPill
        /// A tinted panel plus a coloured bar behind an Obsidian callout, and
        /// the icon and heading drawn on its first line.
        ///
        /// One case rather than three because all four parts share the callout's
        /// hue and its geometry, and splitting them would mean deriving the same
        /// rect three times and hoping the answers agreed.
        ///
        /// `title` is what to DRAW beside the icon: `nil` when the author wrote
        /// their own — that text is real, is in the document, and is styled as
        /// `.calloutTitle` — and the type's name when they did not, since a
        /// callout whose `[!note]` has collapsed would otherwise show an empty
        /// heading line.
        /// `marker` is the `[!type]` declaration's range, and the icon and
        /// heading are drawn only while it is COLLAPSED.
        ///
        /// Measured at draw time rather than stored, and that is the whole
        /// point: `blockBackgrounds` is rebuilt only on a full render, while
        /// reveal changes on every caret move. A stored flag therefore goes
        /// stale the instant the caret enters the callout, and the icon and
        /// heading get painted on top of the `> [!note]` the reader can now
        /// see — the overlap Ahmed photographed on 2026-08-17. `listMarker`
        /// has always decided this the same way, from geometry, which
        /// self-corrects because the geometry IS the reveal state.
        case callout(MarkdownCallout.Kind, title: String?, marker: NSRange)
        /// A drawn math expression, laid out. Painted only while its source is
        /// COLLAPSED — measured at draw time, never stored, for the reason the
        /// callout case above spells out.
        case math(MathBox)
        /// A pipe table drawn as a real grid, with per-cell wrapping. Painted
        /// only while its source is COLLAPSED, measured at draw time.
        case table(TableBox, marker: NSRange)
        /// A transcluded `![[note]]`, laid out. Painted only while its source
        /// is COLLAPSED, measured at draw time — the same geometry question
        /// the callout case above spells out. The box carries the attributed
        /// string its reserved height was measured from, so the paint and the
        /// gap can never describe different content.
        case transclusion(TransclusionLayout.Box)
    }

    /// A stretch of text to decorate. UTF-16, into the view's own string.
    struct Region: Equatable {
        let kind: Kind
        let range: NSRange
    }

    /// The two colours, resolved from the host theme.
    ///
    /// Neither is an accent: after Task 6 accent means "you can click this".
    /// A code panel is a surface, and a quote bar is quiet foreground.
    struct Palette: Equatable {
        let codePanel: NSColor
        let quoteBar: NSColor
        /// A list marker is quiet foreground too — it is punctuation, not a
        /// control, so it must not read as clickable.
        let listMarker: NSColor
        /// The colour a drawn expression is painted in — the same tint the
        /// `.math` span puts on an expression shown as source, so the two
        /// presentations of mathematics agree with each other.
        let mathTint: NSColor
        /// Kept so a callout's tint can be derived per KIND at draw time.
        /// Thirteen callout types would otherwise mean thirteen stored colours
        /// resolved for every document, almost all of them never used.
        let theme: MarkdownTheme

        init(theme: MarkdownTheme) {
            self.theme = theme
            let tokens = theme.tokens
            codePanel = NSColor(tokens.surfaceElevated).withAlphaComponent(theme.skin.opacity.o55)
            // 0.45, not 0.30. At 0.30 on a dark surface the bar was close to
            // invisible, which left an indent doing the whole job of saying
            // "quote" — and an indent alone is what a list looks like.
            quoteBar = NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o45)
            listMarker = NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o55)
            mathTint = NSColor(tokens.accentSecondary)
        }

        /// A callout's colour: its own hue, at a saturation and brightness that
        /// sit correctly on THIS theme's surface.
        ///
        /// The hue is fixed and the rest is derived, which is the whole trade —
        /// `danger` has to read as red in every theme or it is not saying
        /// danger, but a red picked for a dark surface glares on a light one.
        /// Brightness follows the theme's own foreground: a light foreground
        /// means a dark surface, so the tint is lightened to carry against it.
        ///
        /// `.quote` has no colour of its own and falls back to quiet
        /// foreground, exactly as an ordinary block quote does.
        static func calloutTint(
            _ kind: MarkdownCallout.Kind,
            theme: MarkdownTheme
        ) -> NSColor {
            let tokens = theme.tokens
            guard !kind.isNeutral else {
                return NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o70)
            }
            let callout = theme.skin.syntax.callout
            return theme.syntaxColor(
                forHue: CGFloat(kind.hue(callout)), onDark: callout.onDark, onLight: callout.onLight)
        }
    }
}
