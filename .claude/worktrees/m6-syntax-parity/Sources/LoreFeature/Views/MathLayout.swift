import AppKit

/// A laid-out math expression, flattened to things a drawing pass can paint
/// without thinking.
///
/// FLAT on purpose. Layout is the part that can be subtly wrong — a fraction
/// bar half a point off, a numerator that does not centre — and a flat box of
/// positioned glyphs can be ASSERTED: the bar's y sits between the two parts,
/// the box is taller than either, the width is the wider one. A tree that drew
/// itself recursively would need a screen to check.
///
/// Coordinates are relative to the expression's own BASELINE at the origin:
/// `ascent` above, `descent` below, x growing right. The drawing pass adds the
/// text view's origin and nothing else.
struct MathBox: Equatable {
    struct Glyph: Equatable {
        /// Baseline-left of this run, in box coordinates.
        let origin: CGPoint
        let text: String
        let font: NSFont
    }

    var width: CGFloat = 0
    /// Above the baseline. Positive.
    var ascent: CGFloat = 0
    /// Below the baseline. Positive.
    var descent: CGFloat = 0
    var glyphs: [Glyph] = []
    /// Fraction bars and square-root bars, in box coordinates with y measured
    /// the same way as a glyph origin.
    var rules: [CGRect] = []

    var height: CGFloat { ascent + descent }

    /// Moves everything by `dx`/`dy`, which is how the composing functions
    /// place a child box inside a parent.
    func offset(dx: CGFloat, dy: CGFloat) -> MathBox {
        MathBox(width: width, ascent: ascent - dy, descent: descent + dy,
                glyphs: glyphs.map {
                    Glyph(origin: CGPoint(x: $0.origin.x + dx, y: $0.origin.y + dy),
                          text: $0.text, font: $0.font)
                },
                rules: rules.map { $0.offsetBy(dx: dx, dy: dy) })
    }
}

/// Turns a `MathNode` into a `MathBox`.
///
/// The proportions follow TeX's, loosely: a script is 70% of its base, a
/// fraction's parts are full size inline (TeX shrinks them in text style, but
/// in an editor where the expression sits amid prose the shrunken version is
/// hard to read at 14 pt), and the bar sits on the maths axis — roughly the
/// height of a minus sign — which is what makes `a/b` look centred rather than
/// low.
@MainActor
enum MathLayout {

    static let scriptScale: CGFloat = 0.7
    /// Gap above and below a fraction bar, as a fraction of the font size.
    static let fractionGap: CGFloat = 0.22
    static let ruleThickness: CGFloat = 1

    static func layout(_ node: MathNode, font: NSFont) -> MathBox {
        switch node {
        case .symbol(let text, let isVariable):
            return symbolBox(text, isVariable: isVariable, font: font)
        case .row(let children):
            return rowBox(children, font: font)
        case .fraction(let numerator, let denominator):
            return fractionBox(numerator, denominator, font: font)
        case .squareRoot(let inner):
            return squareRootBox(inner, font: font)
        case .script(let base, let superscript, let subscript_):
            return scriptBox(base, superscript, subscript_, font: font)
        }
    }

    // MARK: - Leaves

    private static func symbolBox(_ text: String, isVariable: Bool,
                                  font: NSFont) -> MathBox {
        let face = isVariable ? italic(font) : font
        let size = (text as NSString).size(withAttributes: [.font: face])
        var box = MathBox()
        box.width = size.width
        box.ascent = face.ascender
        box.descent = -face.descender
        box.glyphs = [MathBox.Glyph(origin: .zero, text: text, font: face)]
        return box
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    // MARK: - Composites

    private static func rowBox(_ children: [MathNode], font: NSFont) -> MathBox {
        var out = MathBox()
        var x: CGFloat = 0
        for child in children {
            let box = layout(child, font: font).offset(dx: x, dy: 0)
            out.glyphs += box.glyphs
            out.rules += box.rules
            out.ascent = max(out.ascent, box.ascent)
            out.descent = max(out.descent, box.descent)
            x += box.width + spacing(around: child, font: font)
        }
        out.width = max(0, x)
        return out
    }

    /// A thin gap after operators and relations, which is most of what makes
    /// `a+b` read as mathematics rather than as a word.
    private static func spacing(around node: MathNode, font: NSFont) -> CGFloat {
        guard case .symbol(let text, let isVariable) = node, !isVariable,
              text.count == 1, let character = text.first,
              "+−-=×·÷±∓≤≥≠≈≡→←↔⇒∈∉⊂⊃∪∩".contains(character)
        else { return 0 }
        return font.pointSize * 0.16
    }

    private static func fractionBox(_ numerator: MathNode, _ denominator: MathNode,
                                    font: NSFont) -> MathBox {
        let top = layout(numerator, font: font)
        let bottom = layout(denominator, font: font)
        let gap = font.pointSize * fractionGap
        // The bar sits on the maths axis, a little above the baseline, so the
        // whole fraction reads as centred against the prose beside it.
        let axis = font.xHeight / 2
        let width = max(top.width, bottom.width)

        var out = MathBox()
        out.width = width
        // Numerator: its BOTTOM sits `gap` above the bar.
        let topShift = axis + gap + top.descent
        out.glyphs += top.offset(dx: (width - top.width) / 2, dy: topShift).glyphs
        out.rules += top.offset(dx: (width - top.width) / 2, dy: topShift).rules
        // Denominator: its TOP sits `gap` below the bar.
        let bottomShift = -(gap + bottom.ascent - axis)
        out.glyphs += bottom.offset(dx: (width - bottom.width) / 2, dy: bottomShift).glyphs
        out.rules += bottom.offset(dx: (width - bottom.width) / 2, dy: bottomShift).rules

        out.rules.append(CGRect(x: 0, y: axis - ruleThickness / 2,
                                width: width, height: ruleThickness))
        out.ascent = topShift + top.ascent
        out.descent = -bottomShift + bottom.descent
        return out
    }

    private static func squareRootBox(_ inner: MathNode, font: NSFont) -> MathBox {
        let body = layout(inner, font: font)
        let gap = font.pointSize * 0.12
        let radical = "√"
        let radicalFont = font
        let radicalWidth = (radical as NSString).size(withAttributes: [.font: radicalFont]).width

        var out = MathBox()
        out.width = radicalWidth + body.width + gap
        out.glyphs = [MathBox.Glyph(origin: .zero, text: radical, font: radicalFont)]
        let shifted = body.offset(dx: radicalWidth + gap, dy: 0)
        out.glyphs += shifted.glyphs
        out.rules += shifted.rules
        out.ascent = max(radicalFont.ascender, body.ascent + gap)
        out.descent = max(-radicalFont.descender, body.descent)
        // The bar over the radicand, joining the tick of the √.
        out.rules.append(CGRect(x: radicalWidth, y: out.ascent - ruleThickness,
                                width: body.width + gap, height: ruleThickness))
        return out
    }

    private static func scriptBox(_ base: MathNode, _ superscript: MathNode?,
                                  _ subscript_: MathNode?, font: NSFont) -> MathBox {
        let baseBox = layout(base, font: font)
        let smallFont = NSFont(descriptor: font.fontDescriptor,
                               size: font.pointSize * scriptScale) ?? font
        var out = baseBox
        var scriptWidth: CGFloat = 0

        if let superscript {
            let box = layout(superscript, font: smallFont)
                .offset(dx: baseBox.width, dy: font.pointSize * 0.42)
            out.glyphs += box.glyphs
            out.rules += box.rules
            out.ascent = max(out.ascent, box.ascent)
            scriptWidth = max(scriptWidth, box.width)
        }
        if let subscript_ {
            let box = layout(subscript_, font: smallFont)
                .offset(dx: baseBox.width, dy: -font.pointSize * 0.16)
            out.glyphs += box.glyphs
            out.rules += box.rules
            out.descent = max(out.descent, box.descent)
            scriptWidth = max(scriptWidth, box.width)
        }
        out.width = baseBox.width + scriptWidth
        return out
    }
}
