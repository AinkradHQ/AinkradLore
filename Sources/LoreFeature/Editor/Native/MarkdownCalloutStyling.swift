import AinkradAppKit
import AppKit
import SwiftUI

/// Drawing a callout: its panel, its bar, its icon and its heading.
///
/// Split out of `MarkdownBlockBackgrounds.swift` at the 500-line ceiling. The
/// division is by subject rather than by line count — that file decides WHICH
/// regions exist and draws the simple ones, this one draws the only region with
/// a glyph, a symbol and a substituted heading in it.
extension MarkdownBlockBackgrounds {

    /// Draws a callout: the tinted panel, the coloured bar, the icon on the
    /// first line, and — only when the author wrote no title — the type's name.
    ///
    /// The icon and the name are DRAWN, never inserted. Inserting them would
    /// change the document text and with it every offset the index, the link
    /// graph and the MCP tools hold, which is the rule the whole of this file
    /// exists to honour.
    @MainActor
    static func drawCallout(
        _ kind: MarkdownCallout.Kind, title: String?,
        drawsIcon: Bool,
        at range: NSRange, columnX x: CGFloat,
        columnWidth width: CGFloat,
        theme: MarkdownTheme,
        font: NSFont,
        in textView: NSTextView, origin: NSPoint,
        dirtyRect: NSRect
    ) {
        var rect = boundingRect(of: range, in: textView)
        guard !rect.isNull, !rect.isEmpty else { return }
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let tint = Palette.calloutTint(kind, theme: theme)

        let panel = NSRect(x: x, y: rect.minY - 2, width: width, height: rect.height + 4)
        guard panel.intersects(dirtyRect) else { return }
        // A wash, not a fill: the body text sits on this, and a callout that
        // out-shouts its own contents is decoration rather than emphasis.
        tint.withAlphaComponent(theme.skin.opacity.o10).setFill()
        let outline = NSBezierPath(
            roundedRect: panel, xRadius: cornerRadius,
            yRadius: cornerRadius)
        outline.fill()
        // A border as well as the wash. Obsidian draws both, and the wash
        // alone at 0.10 leaves the panel's edge undefined against a surface
        // that is nearly the same value — the callout reads as a smudge behind
        // the text rather than as a box around it.
        tint.withAlphaComponent(theme.skin.opacity.o25).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        tint.withAlphaComponent(theme.skin.opacity.o85).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: x, y: panel.minY, width: barWidth,
                height: panel.height),
            xRadius: barWidth / 2, yRadius: barWidth / 2
        ).fill()

        // The FIRST LINE's rect, for the icon and the drawn name. Taken from
        // the first character rather than from the block, whose rect spans
        // every line in it.
        let firstCharacter = NSRange(
            location: range.location,
            length: min(1, range.length))
        var line = boundingRect(of: firstCharacter, in: textView)
        guard !line.isNull, line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)

        // The icon matches the TEXT's size, and the drawn title matches its
        // weight — both from the theme's own face, so a callout at Comfortable
        // is not decorated at Compact's scale.
        let titleFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let iconSize = font.pointSize
        let iconX = x + barWidth + calloutIconGap
        if drawsIcon,
            let icon = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
        {
            let configured =
                icon.withSymbolConfiguration(
                    .init(pointSize: iconSize, weight: .semibold)) ?? icon
            let box = NSRect(
                x: iconX,
                y: line.midY - iconSize / 2,
                width: iconSize, height: iconSize)
            configured.isTemplate = true
            tint.set()
            configured.draw(
                in: box, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
        }

        // The author's own title is real text and is styled as
        // `.calloutTitle`; only its absence is drawn over.
        guard let title else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: tint,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(
                x: iconX + iconSize + calloutIconGap,
                y: line.midY - size.height / 2),
            withAttributes: attributes)
    }
}
