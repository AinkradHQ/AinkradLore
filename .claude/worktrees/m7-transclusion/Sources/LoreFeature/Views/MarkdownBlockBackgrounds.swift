import AppKit
import SwiftUI
import AinkradAppKit

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
            quoteBar = NSColor(tokens.foreground).withAlphaComponent(0.30)
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
        static func calloutTint(_ kind: MarkdownCallout.Kind,
                                tokens: HostThemeTokens) -> NSColor {
            guard !kind.isNeutral else {
                return NSColor(tokens.foreground).withAlphaComponent(0.70)
            }
            let onDark = isDarkSurface(tokens: tokens)
            return NSColor(hue: kind.hue / 360,
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
            let luminance = 0.299 * foreground.redComponent
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
    static func regions(for spans: [StyleSpan], length: Int,
                        limitedTo window: NSRange? = nil,
                        in text: NSString? = nil) -> [Region] {
        spans.compactMap { span in
            var r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= length else { return nil }

            let kind: Kind
            switch span.kind {
            case .codeBlock: kind = .codePanel
            case .blockQuote: kind = .quoteBar
            case .callout(let callout):
                // The heading to draw is decided HERE, where the text is in
                // hand, rather than at draw time: `draw` runs on every redraw
                // and must not be re-reading the document to find out whether
                // the author wrote a title.
                guard let text, NSMaxRange(r) <= text.length else { return nil }
                let header = MarkdownCallout.header(ofQuoteAt: span.range, in: text)
                let marker = header.map {
                    NSRange(location: $0.markerRange.lowerBound,
                            length: $0.markerRange.count)
                } ?? NSRange(location: span.range.lowerBound, length: 0)
                kind = .callout(callout,
                                title: header?.titleRange == nil
                                    ? callout.displayTitle : nil,
                                marker: marker)
            case .marker(of: .listBullet):
                // NOT clipped to the window: a marker is two or three
                // characters, so intersecting it would draw half a `10.`. It is
                // either wholly inside the styled window or it is not drawn.
                guard let text, NSMaxRange(r) <= text.length,
                      let glyph = listMarkerGlyph(for: text.substring(with: r))
                else { return nil }
                if let window,
                   NSIntersectionRange(r, window).length != r.length { return nil }
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
    static func listMarkerGlyph(for source: String) -> String? {
        let body = source.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body == "-" || body == "*" || body == "+" { return "•" }
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
    /// The gap between a drawn list marker and the item's text.
    static let listMarkerGap: CGFloat = 5
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
    nonisolated static var calloutTextIndent: CGFloat {
        barWidth + calloutIconGap + MarkdownStyleRenderer.baseSize + calloutIconGap
    }

    /// Paints `regions` into the current context, behind `textView`'s text.
    ///
    /// Called from `drawBackground(in:)`, so the text is drawn on top of
    /// whatever this leaves behind.
    @MainActor
    static func draw(_ regions: [Region], palette: Palette,
                     in textView: NSTextView, dirtyRect: NSRect) {
        guard !regions.isEmpty else { return }
        let origin = textView.textContainerOrigin
        // ONE coordinate source. `x` is the same `origin.x` the text rects are
        // offset by, so the decoration cannot drift away from the glyphs when
        // the column is capped and centred.
        let x = columnX(in: textView)
        let width = columnWidth(in: textView)
        for region in regions {
            if case .listMarker(let glyph) = region.kind {
                drawListMarker(glyph, at: region.range, columnX: x,
                               palette: palette, in: textView,
                               origin: origin, dirtyRect: dirtyRect)
                continue
            }
            if case .table(let box, let marker) = region.kind {
                if MarkdownMathStyling.drawsExpression(at: marker, in: textView) {
                    MarkdownTableStyling.draw(box, tint: palette.listMarker,
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
                    MarkdownMathStyling.draw(box, at: region.range,
                                             tint: palette.mathTint, in: textView,
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
                    in: textView) {
                    TransclusionStyling.draw(box, at: region.range,
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
                drawCallout(kind, title: drawsHeader ? title : nil,
                            drawsIcon: drawsHeader,
                            at: region.range, columnX: x,
                            columnWidth: width, tokens: palette.tokens,
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
                let panel = NSRect(x: x,
                                   y: rect.minY - 2,
                                   width: width,
                                   height: rect.height + 4)
                guard panel.intersects(dirtyRect) else { continue }
                palette.codePanel.setFill()
                NSBezierPath(roundedRect: panel, xRadius: cornerRadius,
                             yRadius: cornerRadius).fill()
            case .quoteBar:
                let bar = NSRect(x: x, y: rect.minY,
                                 width: barWidth, height: rect.height)
                guard bar.intersects(dirtyRect) else { continue }
                palette.quoteBar.setFill()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2,
                             yRadius: barWidth / 2).fill()
            case .listMarker, .callout, .math, .table, .transclusion:
                break   // handled above, before the rect is taken
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
    private static func drawListMarker(_ glyph: String, at range: NSRange,
                                       columnX x: CGFloat, palette: Palette,
                                       in textView: NSTextView, origin: NSPoint,
                                       dirtyRect: NSRect) {
        let markerRect = boundingRect(of: range, in: textView)
        guard !markerRect.isNull else { return }
        guard markerRect.width < collapsedMarkerWidth else { return }

        let withContent = NSRange(location: range.location,
                                  length: min(range.length + 1,
                                              (textView.string as NSString).length
                                                - range.location))
        var line = boundingRect(of: withContent, in: textView)
        if line.isNull || line.height <= 0 { line = markerRect }
        guard line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)
        let textStart = markerRect.minX + origin.x

        let font = MarkdownStyleRenderer.baseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette.listMarker
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        // Right-aligned into the gutter, but never pushed out of the column: a
        // wide ordinal (`10.`) on a shallow indent runs out of gutter, and
        // clamping keeps it inside the measure instead of under the margin.
        let drawX = max(x, textStart - size.width - listMarkerGap)
        let rect = NSRect(x: drawX, y: line.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard rect.intersects(dirtyRect) else { return }
        (glyph as NSString).draw(in: rect, withAttributes: attributes)
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
           let content = layout.textContentManager {
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
            layout.enumerateTextSegments(in: textRange, type: .standard,
                                         options: []) { _, frame, _, _ in
                if !frame.isEmpty { union = union.union(frame) }
                return true
            }
            return union
        }
        guard let manager = textView.layoutManager,
              let container = textView.textContainer else { return .null }
        let glyphs = manager.glyphRange(forCharacterRange: range,
                                        actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .null }
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
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
