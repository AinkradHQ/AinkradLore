import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// The inline code background: a drawn pill, not a per-glyph attribute.
final class InlineCodePillTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func editor(_ body: String, width: CGFloat = 900)
        -> (MarkdownEditor.Coordinator, LinkTextView)
    {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(
            contentRect: tv.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyContainerGeometry(forWidth: width)
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    /// The attribute is gone and a region takes its place.
    @MainActor
    func test_inlineCodeDrawsAPillInsteadOfAGlyphBackground() throws {
        let body = "run `docker compose up` to start\n"
        let (_, tv) = editor(body)
        let inside = (body as NSString).range(of: "docker").location

        XCTAssertNil(
            try XCTUnwrap(tv.textStorage).attribute(
                .backgroundColor, at: inside,
                effectiveRange: nil),
            "a per-glyph background cannot round, pad, or avoid the line box")
        XCTAssertTrue(
            tv.blockBackgrounds.contains {
                if case .inlineCodePill = $0.kind { return true }
                return false
            })
    }

    /// A code span that WRAPS gets one pill per line, not one block covering
    /// both lines and the gap between them. This is the difference from the
    /// tag pill, which can never wrap.
    @MainActor
    func test_aWrappedCodeSpanGetsOnePillPerLine() throws {
        // Narrow column, long span: this is forced to break.
        let body = "text `aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee` end\n"
        let (_, tv) = editor(body, width: 260)
        let span = (body as NSString).range(of: "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee")
        let rects = MarkdownBlockBackgrounds.lineRects(of: span, in: tv)
        XCTAssertGreaterThan(rects.count, 1, "precondition: the span really does wrap")

        // Each fragment is its own rect, and they do not overlap vertically —
        // which is what stops the gap between lines being painted.
        for (a, b) in zip(rects, rects.dropFirst()) {
            XCTAssertLessThanOrEqual(
                a.maxY, b.minY + 0.5,
                "fragments must not overlap into one block")
        }
    }

    /// One pill per line, not one per style run. A span containing a collapsed
    /// marker is several runs to TextKit 2, and three touching pills on one
    /// line would show as darker overlaps at the seams.
    @MainActor
    func test_oneLineYieldsOneRectEvenWithSeveralRuns() throws {
        let body = "see `a **b** c` here\n"
        let (_, tv) = editor(body)
        let span = (body as NSString).range(of: "a **b** c")
        XCTAssertEqual(MarkdownBlockBackgrounds.lineRects(of: span, in: tv).count, 1)
    }

    /// A pill is shorter than the line box it sits in — that gap is the whole
    /// visual defect being fixed.
    @MainActor
    func test_theRectIsTheLineFragmentSoThePillCanBeInsetToTheText() throws {
        let body = "run `x` now\n"
        let (coordinator, tv) = editor(body)
        let span = (body as NSString).range(of: "x")
        let rect = try XCTUnwrap(MarkdownBlockBackgrounds.lineRects(of: span, in: tv).first)
        let textHeight =
            coordinator.theme.bodyFont.ascender
            - coordinator.theme.bodyFont.descender
        XCTAssertGreaterThan(
            rect.height, textHeight,
            "the fragment is taller than the glyphs at a 1.5 line "
                + "height, which is why the pill is inset to them")
    }
}
