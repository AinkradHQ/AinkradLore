import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownBlockBackgrounds {
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
                    columnWidth: width, theme: palette.theme,
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
                    NSColor(palette.theme.tokens.surfaceElevated).withAlphaComponent(0.9).setFill()
                    NSBezierPath(
                        roundedRect: pill, xRadius: inlineCodeRadius,
                        yRadius: inlineCodeRadius
                    ).fill()
                }
            case .tagPill:
                let pill = rect.insetBy(dx: -tagPillPaddingH, dy: -tagPillPaddingV)
                guard pill.intersects(dirtyRect) else { continue }
                NSColor(palette.theme.tokens.accentPrimary).withAlphaComponent(0.14).setFill()
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
        (done ? NSColor(palette.theme.tokens.accentTertiary) : palette.listMarker).set()
        configured.draw(
            in: box, from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
    }
}
