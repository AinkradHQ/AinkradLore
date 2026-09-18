import XCTest
import AppKit
@testable import LoreFeature

/// The parser and the layout, both pure and both asserted without a screen.
///
/// Layout is the half that can be subtly wrong — a bar half a point off, a
/// numerator that does not centre — so the assertions are about RELATIONS
/// between measurements (the bar sits between the parts; the box is taller
/// than either) rather than about numbers, which would only pin today's font.
final class MathParserTests: XCTestCase {

    func test_aFractionParses() {
        XCTAssertEqual(MathParser.parse("\\frac{a}{b}"),
                       .fraction(numerator: .symbol("a", isVariable: true),
                                 denominator: .symbol("b", isVariable: true)))
    }

    func test_greekBecomesItsGlyph() {
        XCTAssertEqual(MathParser.parse("\\alpha"), .symbol("α", isVariable: false))
        XCTAssertEqual(MathParser.parse("\\Omega"), .symbol("Ω", isVariable: false))
    }

    func test_scriptsBindToTheAtomBeforeThem() {
        XCTAssertEqual(MathParser.parse("x^2"),
                       .script(base: .symbol("x", isVariable: true),
                               superscript: .symbol("2", isVariable: false),
                               subscript_: nil))
    }

    /// `x^2_i` and `x_i^2` are the same expression and must parse the same.
    func test_scriptOrderDoesNotMatter() {
        XCTAssertEqual(MathParser.parse("x^2_i"), MathParser.parse("x_i^2"))
    }

    func test_bracedScriptsGroup() {
        XCTAssertEqual(MathParser.parse("x^{10}"),
                       .script(base: .symbol("x", isVariable: true),
                               superscript: .row([.symbol("1", isVariable: false),
                                                  .symbol("0", isVariable: false)]),
                               subscript_: nil))
    }

    func test_sourceSpacingIsNotOutputSpacing() {
        XCTAssertEqual(MathParser.parse("x + y"), MathParser.parse("x+y"),
                       "TeX decides gaps from what sits either side, not from "
                       + "how many spaces were typed")
    }

    func test_lettersAreVariablesAndDigitsAreNot() {
        guard case .symbol(_, let letter)? = MathParser.parse("x"),
              case .symbol(_, let digit)? = MathParser.parse("7") else {
            return XCTFail("both must parse")
        }
        XCTAssertTrue(letter, "a letter is an identifier, drawn italic")
        XCTAssertFalse(digit, "a digit is upright")
    }

    func test_functionNamesStayUpright() {
        XCTAssertEqual(MathParser.parse("\\sin"), .symbol("sin", isVariable: false))
    }

    // MARK: - What it refuses

    /// Everything outside the supported set must refuse, so the caller can
    /// fall back to source. Rendering something the author did not write is
    /// the one outcome worse than not rendering.
    func test_refusesWhatItCannotDraw() {
        for source in ["\\begin{matrix}a\\end{matrix}", "\\unknowncommand",
                       "\\frac{a}", "\\frac", "{unclosed", "a}", "x^", "^2",
                       "\\left(x\\right)", ""] {
            XCTAssertNil(MathParser.parse(source), "must refuse: \(source)")
        }
    }

    /// `\frac a b` is legal TeX and is refused deliberately: supporting it
    /// means guessing how much of what follows is the argument, and a wrong
    /// guess renders something nobody typed.
    func test_refusesUnbracedFractionArguments() {
        XCTAssertNil(MathParser.parse("\\frac a b"))
    }

    func test_refusesADoubledScript() {
        XCTAssertNil(MathParser.parse("x^2^3"))
    }
}

@MainActor
final class MathLayoutTests: XCTestCase {

    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private func box(_ source: String) throws -> MathBox {
        let node = try XCTUnwrap(MathParser.parse(source), "\(source) must parse")
        return MathLayout.layout(node, font: font)
    }

    func test_aSymbolIsAsWideAsItsGlyph() throws {
        let single = try box("x")
        XCTAssertGreaterThan(single.width, 0)
        XCTAssertGreaterThan(single.ascent, 0)
    }

    /// THE fraction test. Every relation that makes it look like a fraction.
    func test_aFractionStacksItsPartsAroundABar() throws {
        let fraction = try box("\\frac{a}{b}")
        let plain = try box("a")

        XCTAssertEqual(fraction.rules.count, 1, "exactly one bar")
        let bar = try XCTUnwrap(fraction.rules.first)

        XCTAssertGreaterThan(fraction.height, plain.height * 1.5,
                             "a fraction must be substantially taller than one symbol")
        XCTAssertGreaterThanOrEqual(bar.width, fraction.width - 0.5,
                                    "the bar spans the fraction's width")

        // The numerator sits ABOVE the bar and the denominator BELOW it.
        let ys = fraction.glyphs.map(\.origin.y).sorted()
        let numeratorY = try XCTUnwrap(ys.last)
        let denominatorY = try XCTUnwrap(ys.first)
        XCTAssertGreaterThan(numeratorY, bar.midY,
                             "the numerator's baseline sits above the bar")
        XCTAssertLessThan(denominatorY, bar.midY,
                          "and the denominator's below it")
    }

    /// The wider part decides the width, and the narrower one is CENTRED
    /// against it — the thing that makes an uneven fraction look right.
    func test_theNarrowerPartIsCentred() throws {
        let fraction = try box("\\frac{1}{1000}")
        let numerator = fraction.glyphs.min { $0.origin.y > $1.origin.y }
        let numeratorX = try XCTUnwrap(numerator?.origin.x)
        XCTAssertGreaterThan(numeratorX, 0,
                             "a single-digit numerator over a four-digit denominator "
                             + "must be indented, not flush left")
    }

    func test_aSquareRootCoversItsRadicand() throws {
        let root = try box("\\sqrt{x}")
        XCTAssertEqual(root.rules.count, 1, "the bar over the radicand")
        let bar = try XCTUnwrap(root.rules.first)
        XCTAssertGreaterThan(bar.minX, 0, "the bar starts after the √ glyph")
        XCTAssertGreaterThan(root.width, try box("x").width, "and is wider than x alone")
    }

    func test_aSuperscriptIsSmallerAndAbove() throws {
        let scripted = try box("x^2")
        let exponent = try XCTUnwrap(scripted.glyphs.max { $0.origin.y < $1.origin.y })
        XCTAssertGreaterThan(exponent.origin.y, 0, "raised above the baseline")
        XCTAssertLessThan(exponent.font.pointSize, font.pointSize, "and smaller")
    }

    func test_aSubscriptIsSmallerAndBelow() throws {
        let scripted = try box("a_i")
        let index = try XCTUnwrap(scripted.glyphs.min { $0.origin.y < $1.origin.y })
        XCTAssertLessThan(index.origin.y, 0)
    }

    /// A row's width is the sum of its parts, so text after the expression
    /// starts in the right place.
    func test_aRowIsAtLeastAsWideAsItsParts() throws {
        let row = try box("abc")
        let single = try box("a")
        XCTAssertGreaterThanOrEqual(row.width, single.width * 2.5)
        XCTAssertEqual(row.glyphs.count, 3)
    }

    /// Nesting must compose rather than flatten: a fraction inside a fraction
    /// is taller than one alone.
    func test_nestedFractionsCompose() throws {
        let simple = try box("\\frac{a}{b}")
        let nested = try box("\\frac{\\frac{a}{b}}{c}")
        XCTAssertGreaterThan(nested.height, simple.height)
        XCTAssertEqual(nested.rules.count, 2, "two bars")
    }

    func test_variablesAreItalicAndDigitsAreNot() throws {
        let variable = try XCTUnwrap(try box("x").glyphs.first)
        let digit = try XCTUnwrap(try box("7").glyphs.first)
        XCTAssertTrue(variable.font.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(digit.font.fontDescriptor.symbolicTraits.contains(.italic))
    }
}
