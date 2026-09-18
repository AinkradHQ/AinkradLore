import AppKit
import SwiftUI
import AinkradAppKit

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
    static func drawCallout(_ kind: MarkdownCallout.Kind, title: String?,
                                    drawsIcon: Bool,
                                    at range: NSRange, columnX x: CGFloat,
                                    columnWidth width: CGFloat,
                                    tokens: HostThemeTokens,
                                    in textView: NSTextView, origin: NSPoint,
                                    dirtyRect: NSRect) {
        var rect = boundingRect(of: range, in: textView)
        guard !rect.isNull, !rect.isEmpty else { return }
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let tint = Palette.calloutTint(kind, tokens: tokens)

        let panel = NSRect(x: x, y: rect.minY - 2, width: width, height: rect.height + 4)
        guard panel.intersects(dirtyRect) else { return }
        // A wash, not a fill: the body text sits on this, and a callout that
        // out-shouts its own contents is decoration rather than emphasis.
        tint.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: panel, xRadius: cornerRadius,
                     yRadius: cornerRadius).fill()
        tint.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: panel.minY, width: barWidth,
                                         height: panel.height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()

        // The FIRST LINE's rect, for the icon and the drawn name. Taken from
        // the first character rather than from the block, whose rect spans
        // every line in it.
        let firstCharacter = NSRange(location: range.location,
                                     length: min(1, range.length))
        var line = boundingRect(of: firstCharacter, in: textView)
        guard !line.isNull, line.height > 0 else { return }
        line = line.offsetBy(dx: origin.x, dy: origin.y)

        let font = MarkdownStyleRenderer.boldBaseFont
        let iconSize = MarkdownStyleRenderer.baseSize
        let iconX = x + barWidth + calloutIconGap
        if drawsIcon,
           let icon = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) {
            let configured = icon.withSymbolConfiguration(
                .init(pointSize: iconSize, weight: .semibold)) ?? icon
            let box = NSRect(x: iconX,
                             y: line.midY - iconSize / 2,
                             width: iconSize, height: iconSize)
            configured.isTemplate = true
            tint.set()
            configured.draw(in: box, from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
        }

        // The author's own title is real text and is styled as
        // `.calloutTitle`; only its absence is drawn over.
        guard let title else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: tint
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: iconX + iconSize + calloutIconGap,
                                             y: line.midY - size.height / 2),
                                 withAttributes: attributes)
    }
}
