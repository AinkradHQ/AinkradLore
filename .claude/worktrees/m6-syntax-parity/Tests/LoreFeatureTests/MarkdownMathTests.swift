import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// `$…$` math.
///
/// Two halves, and the second matters more. The first is that `$x^2$` renders.
/// The second is that the enormous number of dollar signs in ordinary prose —
/// prices, shell variables, currency — do NOT, because a false positive here
/// does not merely fail to render: it tints and collapses a stretch of someone's
/// writing.
final class MarkdownMathTests: XCTestCase {

    private func spans(_ body: String) -> [MarkdownMath.Span] {
        MarkdownMath.spans(in: body as NSString)
    }

    private func styleSpans(_ body: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: body).styleSpans
    }

    // MARK: - Not mathematics

    /// The case that would be worst to get wrong, because it is so common.
    func test_pricesInProseAreNotMath() {
        XCTAssertTrue(spans("it costs $5 and $7 in total\n").isEmpty,
                      "a closing delimiter preceded by a space is not a delimiter")
        XCTAssertTrue(spans("between $10 and $20 per unit\n").isEmpty)
    }

    /// An inline expression may not cross a line. A stray `$` would otherwise
    /// reach for one paragraphs away and tint everything between.
    func test_anInlineExpressionDoesNotCrossALine() {
        XCTAssertTrue(spans("a stray $ here\nand another $ there\n").isEmpty)
    }

    func test_anEmptyExpressionIsNotMath() {
        XCTAssertTrue(spans("$$\n").isEmpty)
        XCTAssertTrue(spans("nothing $$ here\n").isEmpty)
    }

    /// A `$` in a code fence is a shell variable. Without suppression `$PATH`
    /// opens an expression that runs to the next `$` anywhere in the file.
    func test_dollarsInsideCodeAreSuppressed() {
        let body = "```bash\necho $PATH and $HOME\n```\n"
        XCTAssertFalse(styleSpans(body).contains {
            if case .math = $0.kind { return true }
            return false
        }, "a shell variable must not be read as mathematics")
    }

    // MARK: - Mathematics, rendered

    func test_aSimpleSuperscriptRenders() throws {
        let found = spans("area is $x^2$ exactly\n")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(try XCTUnwrap(found.first).isRenderable)
    }

    func test_aFractionIsRenderable() throws {
        XCTAssertTrue(try XCTUnwrap(spans("$\\frac{a}{b}$\n").first).isRenderable)
    }

    func test_greekIsRenderable() throws {
        XCTAssertTrue(try XCTUnwrap(spans("$\\alpha + \\beta$\n").first).isRenderable)
    }

    func test_subscriptsRenderToo() throws {
        XCTAssertTrue(try XCTUnwrap(spans("$a_i$\n").first).isRenderable)
    }

    /// A drawable expression collapses WHOLE — delimiters, commands and all —
    /// because the drawn box stands in for the entire thing. Collapsing only
    /// the syntax would leave `frac` and its braces on screen underneath.
    func test_theWholeExpressionIsAMarker() {
        let body = "intro\n\n$\\frac{a}{b}$\n"
        let expression = (body as NSString).range(of: "$\\frac{a}{b}$")
        XCTAssertTrue(styleSpans(body).contains {
            $0.kind == .marker(of: .math)
                && $0.range.lowerBound == expression.location
                && $0.range.upperBound == NSMaxRange(expression)
        })
    }

    func test_theSpansReachTheStyleLayer() {
        let found = styleSpans("area is $x^2$ exactly\n")
        XCTAssertTrue(found.contains { $0.kind == .math(isRendered: true) })
        XCTAssertTrue(found.contains { $0.kind == .marker(of: .math) })
    }

    // MARK: - Mathematics this editor cannot draw

    /// The all-or-nothing rule. A `\\frac` cannot be rendered without inserting
    /// characters, so the WHOLE expression stays as source — delimiters and all
    /// — rather than being half-rendered.
    func test_anExpressionWithACommandIsLeftAsSource() throws {
        let math = try XCTUnwrap(spans("$\\begin{matrix}a\\end{matrix}$\n").first)
        XCTAssertFalse(math.isRenderable, "a matrix is outside what can be drawn")
        XCTAssertNil(math.tree, "so there is no tree, and nothing collapses")
    }

    /// And its `$` delimiters must stay VISIBLE — collapsing them would leave
    /// `\\frac{a}{b}` looking like prose someone typed by accident.
    func test_anUnrenderableExpressionKeepsItsDelimiters() {
        let body = "$\\begin{matrix}a\\end{matrix}$\n"
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: styleSpans(body), selection: NSRange(location: 0, length: 0),
            text: body, isFocused: false)
        XCTAssertTrue(hidden.isEmpty, "nothing in an unrenderable expression collapses")
    }

    /// It is still TINTED, so the reader can see it is mathematics rather than
    /// a typo — the whole value of recognising it at all.
    func test_anUnrenderableExpressionIsStillMarkedAsMath() {
        XCTAssertTrue(styleSpans("$\\begin{matrix}a\\end{matrix}$\n")
            .contains { $0.kind == .math(isRendered: false) })
    }

    /// `$a + b$` renders now, where the attribute-only version could not: the
    /// layout draws `a` and `b` italic with a spaced `+`, which is what the
    /// expression means and what every other editor shows.
    func test_plainArithmeticRendersToo() throws {
        XCTAssertTrue(try XCTUnwrap(spans("$a + b$\n").first).isRenderable)
    }

    // MARK: - On screen

    /// ON SCREEN: a drawn fraction must make the line TALLER and push the text
    /// after it along.
    ///
    /// Both are what the reader actually sees, and neither can be checked from
    /// the attributes alone. A real window and a layout pass, because a
    /// windowless text view returns a zero rect for every range and the
    /// comparison would be 0 against 0 — how a table test in the previous
    /// milestone passed with its feature switched off.
    @MainActor
    func test_aDrawnFractionReservesRoom() throws {
        // The expression must NOT be on the caret's line, or it reveals and is
        // correctly left as source — which is how the first version of this
        // test failed, measuring the un-drawn case and blaming the code.
        let plainBody = "intro\n\nbefore x after\n"
        let mathBody = "intro\n\nbefore $\\frac{a}{b}$ after\n"

        func measure(_ body: String) throws -> (lineHeight: CGFloat, afterX: CGFloat) {
            var stored = body
            let binding = Binding<String>(get: { stored }, set: { stored = $0 })
            let c = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
            let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
            tv.isRichText = false
            tv.delegate = c
            let w = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.contentView = tv
            w.makeFirstResponder(tv)
            windows.append(w)
            tv.string = body
            c.textView = tv
            c.applyStyles()
            // Caret away, so the expression stays collapsed and drawn.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.revealForSelectionChange()
            tv.layoutSubtreeIfNeeded()
            return try withExtendedLifetime(c) { () -> (CGFloat, CGFloat) in
                let ns = body as NSString
                let after = ns.range(of: "after")
                let rect = tv.firstRect(forCharacterRange: after, actualRange: nil)
                XCTAssertGreaterThan(rect.width, 0, "\(body) must have been laid out")
                return (rect.height, rect.minX)
            }
        }

        let plain = try measure(plainBody)
        let math = try measure(mathBody)
        XCTAssertGreaterThan(math.lineHeight, plain.lineHeight,
                             "a fraction is taller than a line of prose, and the line "
                             + "must grow or it is drawn over the one above")
        XCTAssertGreaterThan(math.afterX, plain.afterX,
                             "and the text after it must start past the reserved width")
    }

    /// A collapsed expression must actually be DRAWN.
    ///
    /// This is the defect in image 7 of 2026-08-17: the source collapsed, the
    /// width was reserved, and nothing was painted into the gap — a blank
    /// space where the fraction should have been. The cause was the reveal
    /// test measuring the WHOLE run, whose last character carries the
    /// space-reserving kern, so a hidden expression measured as wide as its
    /// own drawing and was read as visible.
    @MainActor
    func test_aCollapsedExpressionIsDrawnAndARevealedOneIsNot() throws {
        let body = "intro\n\nbefore $\\frac{a}{b}$ after\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let c = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        tv.isRichText = false
        tv.delegate = c
        let w = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = tv
        w.makeFirstResponder(tv)
        windows.append(w)
        tv.string = body
        c.textView = tv
        c.applyStyles()
        tv.layoutSubtreeIfNeeded()

        try withExtendedLifetime(c) { () -> Void in
            let expression = (body as NSString).range(of: "$\\frac{a}{b}$")
            XCTAssertNotEqual(expression.location, NSNotFound)

            // A region must exist for the drawing layer at all.
            XCTAssertTrue(tv.blockBackgrounds.contains { region in
                if case .math = region.kind { return true }
                return false
            }, "the editor must hand the drawing layer a math region")

            // Caret elsewhere: collapsed, therefore drawn.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.revealForSelectionChange()
            tv.layoutSubtreeIfNeeded()
            XCTAssertTrue(MarkdownMathStyling.drawsExpression(at: expression, in: tv),
                          "a collapsed expression must be drawn, or the reader sees "
                          + "a blank gap where the fraction should be")

            // Caret inside: source is back, so nothing is drawn over it.
            tv.setSelectedRange(NSRange(location: expression.location + 3, length: 0))
            c.revealForSelectionChange()
            tv.layoutSubtreeIfNeeded()
            XCTAssertFalse(MarkdownMathStyling.drawsExpression(at: expression, in: tv),
                           "with the source revealed the drawing must stop")
        }
    }

    private var windows: [NSWindow] = []
}
