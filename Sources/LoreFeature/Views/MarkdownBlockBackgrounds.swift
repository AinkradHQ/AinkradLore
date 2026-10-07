import AinkradAppKit
import AppKit
import SwiftUI

/// Block decoration that is DRAWN, not attributed.
///
/// `.backgroundColor` is a per-glyph attribute, so a fenced block whose lines
/// differ in length gets a ragged right edge — a staircase, not a panel. That
/// raggedness is a large part of why the M2a editor read as "messed up". The
/// same applies to a blockquote: an indent alone does not say "quote", and the
/// bar that does say it exists between the text and the margin, where no
/// character lives.
///
/// Drawing is display-only by construction: nothing here touches the text
/// storage's string, and nothing here adds an attribute. The regions are
/// derived from style spans by the caller and handed over as plain ranges.
enum MarkdownBlockBackgrounds {

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
        let tokens: HostThemeTokens

        init(tokens: HostThemeTokens) {
            self.tokens = tokens
            codePanel = NSColor(tokens.surfaceElevated).withAlphaComponent(0.55)
            // 0.45, not 0.30. At 0.30 on a dark surface the bar was close to
            // invisible, which left an indent doing the whole job of saying
            // "quote" — and an indent alone is what a list looks like.
            quoteBar = NSColor(tokens.foreground).withAlphaComponent(0.45)
            listMarker = NSColor(tokens.foreground).withAlphaComponent(0.55)
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
            tokens: HostThemeTokens
        ) -> NSColor {
            guard !kind.isNeutral else {
                return NSColor(tokens.foreground).withAlphaComponent(0.70)
            }
            let onDark = isDarkSurface(tokens: tokens)
            return NSColor(
                hue: kind.hue / 360,
                saturation: onDark ? 0.55 : 0.75,
                brightness: onDark ? 0.95 : 0.70,
                alpha: 1)
        }

        /// Whether the editor is painting on a dark surface, judged from the
        /// FOREGROUND rather than from a theme name: a light foreground implies
        /// a dark background, and this works for any host theme without the
        /// tokens having to declare an appearance.
        static func isDarkSurface(tokens: HostThemeTokens) -> Bool {
            let foreground = NSColor(tokens.foreground).usingColorSpace(.sRGB)
            guard let foreground else { return true }
            let luminance =
                0.299 * foreground.redComponent
                + 0.587 * foreground.greenComponent
                + 0.114 * foreground.blueComponent
            return luminance > 0.5
        }
    }

    /// The regions implied by a document's style spans.
    ///
    /// Spans arrive parent-first and may nest; only the two block kinds matter
    /// here, and each contributes exactly one region, so nesting cannot
    /// multiply the drawing.
    ///
    /// - Parameter window: the range whose ATTRIBUTES were applied, on an
    ///   over-cap document. Regions are intersected with it rather than merely
    ///   filtered by it, for two reasons: a panel must never be painted behind
    ///   text that was left unstyled, and asking the layout manager for the
    ///   bounding rect of a region far outside the viewport is exactly the work
    ///   that makes a long note stutter. `nil` means "the whole document was
    ///   styled", which is the ordinary case.
    /// - Parameter text: the document, needed only to read what a list marker
    ///   actually SAYS — `1.` and `7.` must not both draw as `1.`. `nil` (the
    ///   default, used by callers that only care about the block decorations)
    ///   emits no list markers rather than guessing at one.
    /// - Parameter tagPills: `EditorSettings.renderTagsAsChips`, resolved by
    ///   the theme. The setting is honoured HERE rather than at the styling
    ///   call site because the chip is now a drawn region rather than a text
    ///   attribute — with it off, no region is emitted at all and a tag is
    ///   simply tinted text.
    static func regions(
        for spans: [StyleSpan], length: Int,
        limitedTo window: NSRange? = nil,
        in text: NSString? = nil,
        tagPills: Bool = false
    ) -> [Region] {
        // The lines that carry a checkbox, so the bullet on those lines can be
        // suppressed. Collected in one pass up front rather than searched per
        // bullet, which would be quadratic on a long task list.
        // Nesting depth per list item, keyed by where the item STARTS — which
        // is also where its bullet marker starts, since `visitListItem` emits
        // both from the same range. That shared origin is what lets a marker
        // find its own depth without a second containment scan.
        let depths = MarkdownListDepth.depths(of: spans)
        var depthByItemStart: [Int: Int] = [:]
        for (index, span) in spans.enumerated() {
            guard case .listItem = span.kind else { continue }
            depthByItemStart[span.range.lowerBound] = depths[index]
        }

        var taskLines: Set<Int> = []
        if let text {
            for span in spans {
                guard case .checkbox = span.kind else { continue }
                let r = NSRange(location: span.range.lowerBound, length: span.range.count)
                guard NSMaxRange(r) <= text.length else { continue }
                taskLines.insert(text.lineRange(for: r).location)
            }
        }
        return spans.compactMap { span in
            var r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= length else { return nil }

            let kind: Kind
            switch span.kind {
            case .thematicBreak: kind = .rule
            case .inlineCode: kind = .inlineCodePill
            case .tag:
                guard tagPills else { return nil }
                kind = .tagPill
            case .codeBlock: kind = .codePanel
            case .blockQuote: kind = .quoteBar
            case .callout(let callout):
                // The heading to draw is decided HERE, where the text is in
                // hand, rather than at draw time: `draw` runs on every redraw
                // and must not be re-reading the document to find out whether
                // the author wrote a title.
                guard let text, NSMaxRange(r) <= text.length else { return nil }
                let header = MarkdownCallout.header(ofQuoteAt: span.range, in: text)
                let marker =
                    header.map {
                        NSRange(
                            location: $0.markerRange.lowerBound,
                            length: $0.markerRange.count)
                    } ?? NSRange(location: span.range.lowerBound, length: 0)
                kind = .callout(
                    callout,
                    title: header?.titleRange == nil
                        ? callout.displayTitle : nil,
                    marker: marker)
            case .checkbox(let done):
                // Drawn only where the source is collapsed, decided at draw
                // time from geometry — the same self-correcting witness the
                // callout heading and the list marker use, and for the same
                // reason: reveal moves on a caret press, which does not
                // rebuild these regions.
                guard NSMaxRange(r) <= length else { return nil }
                return Region(kind: .checkbox(done), range: r)

            case .marker(of: .listBullet):
                // A TASK item's bullet is not drawn: its checkbox stands where
                // the bullet would, and drawing both would put `• ☐` on every
                // line of a task list.
                if let text, taskLines.contains(text.lineRange(for: r).location) {
                    return nil
                }
                // NOT clipped to the window: a marker is two or three
                // characters, so intersecting it would draw half a `10.`. It is
                // either wholly inside the styled window or it is not drawn.
                guard let text, NSMaxRange(r) <= text.length,
                    let glyph = listMarkerGlyph(
                        for: text.substring(with: r),
                        depth: depthByItemStart[span.range.lowerBound] ?? 0)
                else { return nil }
                if let window,
                    NSIntersectionRange(r, window).length != r.length
                {
                    return nil
                }
                return Region(kind: .listMarker(glyph), range: r)
            default: return nil
            }
            if let window {
                r = NSIntersectionRange(r, window)
                guard r.length > 0 else { return nil }
            }
            return Region(kind: kind, range: r)
        }
    }

    /// What a list marker's SOURCE draws as once collapsed.
    ///
    /// `- `, `* `, `+ ` become a real bullet; an ordinal keeps its own number
    /// and is normalised to a trailing `.` so a `1)` list and a `1.` list read
    /// alike. Anything else returns nil — the same "emit nothing rather than a
    /// guess" rule `MarkdownMarkers` follows, since a wrong glyph in the gutter
    /// is worse than none.
    /// - Parameter depth: nesting level, 0 for a top-level item. An UNORDERED
    ///   bullet cycles with it — Obsidian draws a filled disc, then a hollow
    ///   one, then a small square — which is what lets a reader tell a nested
    ///   list from a wrapped line at a glance. An ordinal does not cycle: a
    ///   number is already its own distinguishing mark.
    static func listMarkerGlyph(for source: String, depth: Int = 0) -> String? {
        let body = source.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body == "-" || body == "*" || body == "+" {
            let cycle = ["•", "◦", "▪"]
            return cycle[max(0, depth) % cycle.count]
        }
        let digits = body.dropLast()
        guard let last = body.last, last == "." || last == ")",
            !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return digits + "."
    }

    /// The left edge of the text column, in the text view's own coordinates.
    ///
    /// `textContainerOrigin` and nothing else. The rects this decoration is
    /// drawn against come from the LAYOUT, in container coordinates, and are
    /// offset by that same origin — so taking the panel's x from
    /// `textContainerInset.width` instead was a second coordinate source that
    /// happened to agree only while the column was not centred. Once
    /// `MarkdownEditorLayout` centres a capped column the two part company and
    /// every panel and bar detaches from its text.
    @MainActor
    static func columnX(in textView: NSTextView) -> CGFloat {
        textView.textContainerOrigin.x
    }

    /// The width of the text column — the container's, not the view's.
    ///
    /// A code panel is full width OF THE COLUMN. Using the view's bounds would
    /// make it overhang the text on a wide window by exactly the amount the
    /// measure cap took away.
    @MainActor
    static func columnWidth(in textView: NSTextView) -> CGFloat {
        if let container = textView.textContainer, container.size.width > 0 {
            return container.size.width
        }
        return max(0, textView.bounds.width - columnX(in: textView) * 2)
    }

    /// The corner radius of a code panel. Enough to read as a panel, little
    /// enough not to read as a button.
    static let cornerRadius: CGFloat = 5
    /// Width of a blockquote's bar.
    static let barWidth: CGFloat = 3
    /// Vertical breathing room inside a code panel, above the first line and
    /// below the last.
    static let codePanelPadding: CGFloat = 8
    /// The gap between a drawn list marker and the item's text.
    static let listMarkerGap: CGFloat = 5
    /// How far a tag's pill extends past the tag's own glyphs. Horizontal is
    /// generous and vertical is not: a pill wants air at its ends, and a tall
    /// one collides with the line above.
    /// How far an inline code pill extends past its glyphs, and how round it
    /// is. Obsidian's is a small radius rather than a capsule — code is often
    /// a single character, and a capsule around `x` reads as a badge.
    static let inlineCodePaddingH: CGFloat = 4
    static let inlineCodePaddingV: CGFloat = 2
    static let inlineCodeRadius: CGFloat = 4
    static let tagPillPaddingH: CGFloat = 5
    static let tagPillPaddingV: CGFloat = 1
    /// Below this rendered width a marker's source is COLLAPSED and its
    /// substitute must be drawn; at or above it the real characters are on
    /// screen — the caret is in the block — and drawing would double them.
    ///
    /// Geometry rather than bookkeeping, deliberately: reveal state changes on
    /// a caret move, which does not rebuild the regions, so a cached flag would
    /// go stale exactly when the user looked at it. The collapsed font is
    /// 0.01pt (see `MarkdownStyleRenderer.collapse`) and the revealed one is
    /// 14pt monospaced, so any threshold between them separates the two cases
    /// by three orders of magnitude.
    static let collapsedMarkerWidth: CGFloat = 2

    /// The gap between the bar and a callout's icon, and between the icon and
    /// the text.
    static let calloutIconGap: CGFloat = 6

    /// How far a callout's text is indented: exactly the room its decoration
    /// occupies — the bar, a gap, the icon, a gap.
    ///
    /// ONE definition, read by both the paragraph indent
    /// (`MarkdownParagraphStyles`) and the drawing below, because they are two
    /// answers to the same question and were previously computed apart. The
    /// indent was `listIndentStep * 2` = 44 pt against decoration needing 29,
    /// so a callout carried 15 pt of dead space — invisible while the icon
    /// covered it, and an obvious empty gutter the moment the caret revealed
    /// the source and the icon stopped being drawn (2026-08-17, image 9).
    /// - Parameter iconSize: the icon's side, which is the theme's body point
    ///   size — the icon is drawn to match the text beside it. A PARAMETER
    ///   rather than a constant since the font stopped being one: this used to
    ///   read `MarkdownStyleRenderer.baseSize`, and leaving it fixed while the
    ///   drawing scaled would re-open the 15 pt dead gutter of 2026-08-17 at
    ///   every density except the one it was written for.
    nonisolated static func calloutTextIndent(iconSize: CGFloat) -> CGFloat {
        barWidth + calloutIconGap + iconSize + calloutIconGap
    }

    /// Paints `regions` into the current context, behind `textView`'s text.
    ///
    /// Called from `drawBackground(in:)`, so the text is drawn on top of
    /// whatever this leaves behind.
    @MainActor
    /// - Parameter font: the theme's prose face. Everything drawn here is
    ///   sized from it — a substituted list marker, a callout's icon and its
    ///   drawn title, a maths baseline — so decoration and text move together
    ///   when density or zoom changes.
    static func draw(
        _ regions: [Region], palette: Palette, font: NSFont,
        in textView: NSTextView, dirtyRect: NSRect
    ) {
        guard !regions.isEmpty else { return }
        let origin = textView.textContainerOrigin
        // ONE coordinate source. `x` is the same `origin.x` the text rects are
        // offset by, so the decoration cannot drift away from the glyphs when
        // the column is capped and centred.
        let x = columnX(in: textView)
        let width = columnWidth(in: textView)
        for region in regions {
            if case .listMarker(let glyph) = region.kind {
                drawListMarker(
                    glyph, at: region.range, columnX: x,
                    palette: palette, font: font, in: textView,
                    origin: origin, dirtyRect: dirtyRect)
                continue
            }
            if case .checkbox(let done) = region.kind {
                drawCheckbox(
                    done, at: region.range, columnX: x,
                    palette: palette, font: font, in: textView,
                    origin: origin, dirtyRect: dirtyRect)
                continue
            }
            if case .table(let box, let marker) = region.kind {
                if MarkdownMathStyling.drawsExpression(at: marker, in: textView) {
                    MarkdownTableStyling.draw(
                        box, tint: palette.listMarker,
                        rule: palette.quoteBar, in: textView,
                        origin: origin, dirtyRect: dirtyRect)
                }
                continue
            }
            if case .math(let box) = region.kind {
                // The same geometry question as the callout heading: a visible
                // source means the caret is in the expression, and the drawn
                // form must not be painted over the top of it.
                if MarkdownMathStyling.drawsExpression(at: region.range, in: textView) {
                    MarkdownMathStyling.draw(
                        box, at: region.range,
                        tint: palette.mathTint, font: font,
                        in: textView,
                        origin: origin, dirtyRect: dirtyRect)
                }
                continue
            }
            if case .transclusion(let box) = region.kind {
                // Same witness as the table: the FIRST character of the
                // collapsed source is 0.01 pt while hidden and a real glyph
                // once the caret reveals it, so the drawn note is never
                // painted on top of its own `![[…]]` source.
                if MarkdownMathStyling.drawsExpression(
                    at: NSRange(location: region.range.location, length: 1),
                    in: textView)
                {
                    TransclusionStyling.draw(
                        box, at: region.range,
                        columnX: x, columnWidth: width,
                        rule: palette.mathTint,
                        frame: palette.quoteBar,
                        in: textView, origin: origin,
                        dirtyRect: dirtyRect)
                }
                continue
            }
            if case .callout(let kind, let title, let marker) = region.kind {
                // Collapsed marker means the source is hidden, so the icon and
                // heading stand in for it. Visible marker means the caret is
                // on the header line and they must not be drawn at all.
                let drawsHeader = drawsCalloutHeader(marker: marker, in: textView)
                drawCallout(
                    kind, title: drawsHeader ? title : nil,
                    drawsIcon: drawsHeader,
                    at: region.range, columnX: x,
                    columnWidth: width, tokens: palette.tokens,
                    font: font,
                    in: textView, origin: origin, dirtyRect: dirtyRect)
                continue
            }
            var rect = boundingRect(of: region.range, in: textView)
            guard !rect.isNull, !rect.isEmpty else { continue }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch region.kind {
            case .codePanel:
                // Full width, deliberately: the panel is a property of the
                // BLOCK, not of the longest line in it.
                // 8 pt above and below, not the 2 this carried. A fence sat
                // so tight inside its own panel that the panel read as a
                // highlight on the text rather than as a container for it.
                let panel = NSRect(
                    x: x,
                    y: rect.minY - codePanelPadding,
                    width: width,
                    height: rect.height + codePanelPadding * 2)
                guard panel.intersects(dirtyRect) else { continue }
                palette.codePanel.setFill()
                NSBezierPath(
                    roundedRect: panel, xRadius: cornerRadius,
                    yRadius: cornerRadius
                ).fill()
            case .inlineCodePill:
                // Per line fragment, and vertically inset to the TEXT rather
                // than the line box: at a 1.5 line height the fragment is half
                // again as tall as the glyphs, and filling it is what made the
                // old attribute-based background look like it belonged to the
                // line above.
                for fragment in lineRects(of: region.range, in: textView) {
                    var pill = fragment.offsetBy(dx: origin.x, dy: origin.y)
                    let textHeight = font.ascender - font.descender
                    let slack = max(0, pill.height - textHeight)
                    pill = pill.insetBy(dx: 0, dy: slack / 2)
                        .insetBy(dx: -inlineCodePaddingH, dy: -inlineCodePaddingV)
                    guard pill.intersects(dirtyRect) else { continue }
                    NSColor(palette.tokens.surfaceElevated).withAlphaComponent(0.9).setFill()
                    NSBezierPath(
                        roundedRect: pill, xRadius: inlineCodeRadius,
                        yRadius: inlineCodeRadius
                    ).fill()
                }
            case .tagPill:
                let pill = rect.insetBy(dx: -tagPillPaddingH, dy: -tagPillPaddingV)
                guard pill.intersects(dirtyRect) else { continue }
                NSColor(palette.tokens.accentPrimary).withAlphaComponent(0.14).setFill()
                NSBezierPath(
                    roundedRect: pill, xRadius: pill.height / 2,
                    yRadius: pill.height / 2
                ).fill()
            case .rule:
                // Centred in the line the paragraph style reserved, full
                // measure. `barWidth`'s sibling constant rather than a literal
                // 1: on a Retina display a hairline that is not a device pixel
                // renders as a grey smear, and 1 pt is the honest minimum.
                let line = NSRect(x: x, y: rect.midY - 0.5, width: width, height: 1)
                guard line.intersects(dirtyRect) else { continue }
                palette.quoteBar.setFill()
                line.fill()
            case .quoteBar:
                let bar = NSRect(
                    x: x, y: rect.minY,
                    width: barWidth, height: rect.height)
                guard bar.intersects(dirtyRect) else { continue }
                palette.quoteBar.setFill()
                NSBezierPath(
                    roundedRect: bar, xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
            case .listMarker, .checkbox, .callout, .math, .table, .transclusion:
                break  // handled above, before the rect is taken
            }
        }
    }

    /// Draws a collapsed list marker's substitute in the gutter.
    ///
    /// Two rects, for two different questions. The MARKER's own rect answers
    /// "is it collapsed?" and gives the x the item's text starts at; the rect
    /// of the marker plus the first character of the item answers "where is
    /// this line, and how tall?", which a 0.01pt run cannot be trusted to.
    @MainActor
    private static func drawListMarker(
        _ glyph: String, at range: NSRange,
        columnX x: CGFloat, palette: Palette,
        font: NSFont,
        in textView: NSTextView, origin: NSPoint,
        dirtyRect: NSRect
    ) {
        let markerRect = boundingRect(of: range, in: textView)
        guard !markerRect.isNull else { return }
        guard markerRect.width < collapsedMarkerWidth else { return }

        let withContent = NSRange(
            location: range.location,
            length: min(
                range.length + 1,
                (textView.string as NSString).length
                    - range.location))
        var line = boundingRect(of: withContent, in: textView)
        if line.isNull || line.height <= 0 { line = markerRect }
        guard line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)
        let textStart = markerRect.minX + origin.x

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette.listMarker,
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        // Right-aligned into the gutter, but never pushed out of the column: a
        // wide ordinal (`10.`) on a shallow indent runs out of gutter, and
        // clamping keeps it inside the measure instead of under the margin.
        let drawX = max(x, textStart - size.width - listMarkerGap)
        let rect = NSRect(
            x: drawX, y: line.midY - size.height / 2,
            width: size.width, height: size.height)
        guard rect.intersects(dirtyRect) else { return }
        (glyph as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// Draws a collapsed task marker's substitute: a real checkbox.
    ///
    /// Deliberately the same shape as `drawListMarker` — same collapsed-width
    /// witness, same gutter placement, same clamp against running out of
    /// column — because it answers the same question about a different glyph.
    /// The two are not merged into one function: a checkbox is an SF Symbol
    /// with a fill state and a tint that means something, a bullet is a
    /// character, and folding them together would mean a parameter list that
    /// is really two functions wearing one name.
    ///
    /// The symbol is DRAWN, never inserted. The document still says `[x]`.
    @MainActor
    private static func drawCheckbox(
        _ done: Bool, at range: NSRange,
        columnX x: CGFloat, palette: Palette,
        font: NSFont,
        in textView: NSTextView, origin: NSPoint,
        dirtyRect: NSRect
    ) {
        let markerRect = boundingRect(of: range, in: textView)
        guard !markerRect.isNull else { return }
        // Collapsed means the caret is elsewhere and the box stands in for the
        // source. Revealed means the writer is editing `[x]` itself, and
        // painting a checkbox over it would double the control.
        guard markerRect.width < collapsedMarkerWidth else { return }

        let withContent = NSRange(
            location: range.location,
            length: min(
                range.length + 1,
                (textView.string as NSString).length
                    - range.location))
        var line = boundingRect(of: withContent, in: textView)
        if line.isNull || line.height <= 0 { line = markerRect }
        guard line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)
        let textStart = markerRect.minX + origin.x

        let side = font.pointSize
        let drawX = max(x, textStart - side - listMarkerGap)
        let box = NSRect(x: drawX, y: line.midY - side / 2, width: side, height: side)
        guard box.intersects(dirtyRect) else { return }

        guard
            let symbol = NSImage(
                systemSymbolName: done ? "checkmark.square.fill" : "square",
                accessibilityDescription: done ? "checked" : "unchecked")
        else { return }
        let configured =
            symbol.withSymbolConfiguration(
                .init(pointSize: side, weight: .regular)) ?? symbol
        configured.isTemplate = true
        // A done box is tinted; an empty one is quiet foreground, like the
        // bullet it replaced. Colour marks the state, so an unchecked list does
        // not read as a column of controls demanding attention.
        (done ? NSColor(palette.tokens.accentTertiary) : palette.listMarker).set()
        configured.draw(
            in: box, from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The union of the line rects `range` occupies, in TEXT CONTAINER
    /// coordinates, or a null rect if it occupies none.
    ///
    /// TextKit 2 first and by preference. Reading `NSTextView.layoutManager`
    /// on a TextKit 2 view silently downgrades the whole view to TextKit 1 —
    /// the same trap `MarkdownStyleRenderer.viewportWindow(of:)` documents — so
    /// that property is touched ONLY when `textLayoutManager` is already nil,
    /// which means the view is TextKit 1 and there is nothing left to downgrade.
    @MainActor
    /// Internal rather than private since `MarkdownMathStyling` places a drawn
    /// expression from the same rect this returns — one source of geometry, so
    /// the decoration and the text cannot disagree about where a run is.
    static func boundingRect(of range: NSRange, in textView: NSTextView) -> NSRect {
        if let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        {
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length),
                let textRange = NSTextRange(location: start, end: end)
            else { return .null }
            var union = NSRect.null
            // No `ensureLayout(for:)`. Forcing layout from inside
            // `drawBackground(in:)` is a reentrancy hazard — drawing asks the
            // layout manager to change the thing being drawn — and it ran once
            // per region per draw, over ranges that were not clipped to the
            // viewport. Nothing is lost by dropping it: this is only ever
            // called while the visible text is being drawn, and text that is
            // being drawn is by definition laid out. A region that is entirely
            // off screen enumerates no segments, returns a null rect, and is
            // skipped — which is the desired outcome, reached without the work.
            layout.enumerateTextSegments(
                in: textRange, type: .standard,
                options: []
            ) { _, frame, _, _ in
                if !frame.isEmpty { union = union.union(frame) }
                return true
            }
            return union
        }
        guard let manager = textView.layoutManager,
            let container = textView.textContainer
        else { return .null }
        let glyphs = manager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .null }
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// The rect of each LINE FRAGMENT `range` occupies, in text container
    /// coordinates.
    ///
    /// `boundingRect` unions them, which is right for a block panel and wrong
    /// for anything that must not paint the space between two lines. Same
    /// TextKit 2 preference and the same reason: reading `layoutManager` on a
    /// TextKit 2 view downgrades it.
    @MainActor
    static func lineRects(of range: NSRange, in textView: NSTextView) -> [NSRect] {
        if let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        {
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                let end = content.location(start, offsetBy: range.length),
                let textRange = NSTextRange(location: start, end: end)
            else { return [] }
            var rects: [NSRect] = []
            layout.enumerateTextSegments(
                in: textRange, type: .standard,
                options: []
            ) { _, frame, _, _ in
                if !frame.isEmpty { rects.append(frame) }
                return true
            }
            return merged(rects)
        }
        guard let manager = textView.layoutManager,
            let container = textView.textContainer
        else { return [] }
        var rects: [NSRect] = []
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
            let intersection = NSIntersectionRange(lineGlyphs, glyphs)
            guard intersection.length > 0 else { return }
            var rect = manager.boundingRect(forGlyphRange: intersection, in: container)
            rect.origin.y = used.origin.y
            rect.size.height = used.size.height
            rects.append(rect)
        }
        return rects
    }

    /// Joins segments that share a line, so one pill is drawn per line rather
    /// than one per style run. TextKit 2 reports a segment per run, and inline
    /// code containing a collapsed marker is several runs.
    private static func merged(_ rects: [NSRect]) -> [NSRect] {
        var out: [NSRect] = []
        for rect in rects.sorted(by: { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }) {
            if let last = out.last, abs(last.minY - rect.minY) < 0.5 {
                out[out.count - 1] = last.union(rect)
            } else {
                out.append(rect)
            }
        }
        return out
    }

    /// Whether a callout's icon and heading should be drawn: only while its
    /// `[!type]` declaration is collapsed.
    ///
    /// A zero-length marker (a callout whose header could not be re-read)
    /// answers `true`, which keeps the heading — the same direction every
    /// other guard in this file takes when it is unsure.
    @MainActor
    static func drawsCalloutHeader(marker: NSRange, in textView: NSTextView) -> Bool {
        guard marker.length > 0 else { return true }
        let rect = boundingRect(of: marker, in: textView)
        guard !rect.isNull else { return true }
        return rect.width < collapsedMarkerWidth
    }
}
