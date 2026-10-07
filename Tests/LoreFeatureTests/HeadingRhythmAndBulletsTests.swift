import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// M9.4: the two things M9.1 left behind.
final class HeadingRhythmAndBulletsTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }
    private let theme = MarkdownTheme(tokens: TestTokens.make())

    @MainActor
    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
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
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    @MainActor
    private func spacingBefore(at offset: Int, in tv: LinkTextView) throws -> CGFloat {
        let style = try XCTUnwrap(
            tv.textStorage?.attribute(
                .paragraphStyle, at: offset,
                effectiveRange: nil)
                as? NSParagraphStyle)
        return style.paragraphSpacingBefore
    }

    // MARK: - T5d heading after heading

    /// A heading following PROSE keeps its full section break.
    @MainActor
    func test_aHeadingAfterProseKeepsItsFullSpacing() throws {
        let body = "some prose here\n\n## Section\n\nmore prose\n"
        let (_, tv) = editor(body)
        let heading = (body as NSString).range(of: "## Section").location
        XCTAssertEqual(
            try spacingBefore(at: heading, in: tv),
            theme.headingSpacingBefore(2), accuracy: 0.01)
    }

    /// A heading following ANOTHER heading collapses it. Both used to stack —
    /// the previous heading's spacing below plus this one's above — leaving a
    /// band of dead air that read as a missing paragraph.
    @MainActor
    func test_aHeadingAfterAHeadingCollapsesItsSpacing() throws {
        let body = "## Section\n\n### Subsection\n\nprose\n"
        let (_, tv) = editor(body)
        let sub = (body as NSString).range(of: "### Subsection").location
        let collapsed = try spacingBefore(at: sub, in: tv)

        XCTAssertEqual(
            collapsed, theme.headingSpacingAfter(2), accuracy: 0.01,
            "the gap becomes the h2's own spacing-after, not a second break")
        XCTAssertLessThan(
            collapsed, theme.headingSpacingBefore(3),
            "and is genuinely smaller than the uncollapsed one")
        XCTAssertGreaterThan(collapsed, 0, "but two headings are still told apart")
    }

    /// With no blank line between them either.
    @MainActor
    func test_immediatelyAdjacentHeadingsAlsoCollapse() throws {
        let body = "# Title\n## Section\n\nprose\n"
        let (_, tv) = editor(body)
        let section = (body as NSString).range(of: "## Section").location
        XCTAssertEqual(
            try spacingBefore(at: section, in: tv),
            theme.headingSpacingAfter(1), accuracy: 0.01)
    }

    /// `#tag` at the start of a line is NOT a heading — CommonMark needs a
    /// space after the hashes — so it must not collapse the heading below it.
    @MainActor
    func test_aTagLineDoesNotCountAsTheHeadingAbove() throws {
        let body = "#project/alpha\n\n## Section\n\nprose\n"
        let (_, tv) = editor(body)
        let heading = (body as NSString).range(of: "## Section").location
        XCTAssertEqual(
            try spacingBefore(at: heading, in: tv),
            theme.headingSpacingBefore(2), accuracy: 0.01)
    }

    func test_theLookbackReadsTheLevelAndRejectsNonHeadings() {
        func level(_ body: String) -> Int? {
            let ns = body as NSString
            return MarkdownParagraphStyles.headingLevelAbove(
                paragraphStart: ns.range(of: "TARGET").location, in: ns)
        }
        XCTAssertEqual(level("### Above\n\nTARGET"), 3)
        XCTAssertEqual(level("# Above\nTARGET"), 1)
        XCTAssertNil(level("plain prose\n\nTARGET"))
        XCTAssertNil(level("#nospace\n\nTARGET"), "a tag is not a heading")
        XCTAssertNil(level("####### seven\n\nTARGET"), "h7 does not exist")
        XCTAssertNil(level("TARGET"), "nothing above at all")
    }

    // MARK: - T16 bullet cycling

    func test_bulletsCycleWithDepthAndOrdinalsDoNot() {
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "- ", depth: 0), "•")
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "* ", depth: 1), "◦")
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "+ ", depth: 2), "▪")
        XCTAssertEqual(
            MarkdownBlockBackgrounds.listMarkerGlyph(for: "- ", depth: 3), "•",
            "the cycle repeats rather than running out")
        // An ordinal keeps its own number at every depth: a number is already
        // its own distinguishing mark.
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "7. ", depth: 1), "7.")
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "7) ", depth: 2), "7.")
    }

    /// End to end: a nested list draws three different glyphs.
    @MainActor
    func test_aNestedListDrawsADifferentGlyphPerLevel() {
        let body = "- one\n    - two\n        - three\n\nfar away\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(
            NSRange(
                location: (body as NSString).range(of: "far").location,
                length: 0))
        coordinator.revealForSelectionChange()

        let glyphs = tv.blockBackgrounds.compactMap { region -> String? in
            if case .listMarker(let glyph) = region.kind { return glyph }
            return nil
        }
        XCTAssertEqual(glyphs, ["•", "◦", "▪"])
    }
}
