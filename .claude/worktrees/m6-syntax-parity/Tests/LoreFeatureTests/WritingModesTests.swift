import XCTest
@testable import LoreFeature

/// Focus mode and typewriter scrolling.
final class WritingModesTests: XCTestCase {

    // MARK: - Focused paragraph

    /// A PARAGRAPH, not a line. A wrapped sentence is one paragraph, and
    /// dimming by visual line would fade half of what the writer is looking at.
    func test_theParagraphSpansBlankLineBoundaries() {
        let text = "first para line one\nfirst para line two\n\nsecond para"
        let range = WritingModes.paragraphRange(in: text, caret: 5)
        XCTAssertEqual((text as NSString).substring(with: range),
                       "first para line one\nfirst para line two\n")
    }

    func test_theCaretInALaterParagraphSelectsThatOne() {
        let text = "one\n\ntwo\n\nthree"
        let caret = (text as NSString).range(of: "two").location + 1
        let range = WritingModes.paragraphRange(in: text, caret: caret)
        XCTAssertTrue((text as NSString).substring(with: range).contains("two"))
        XCTAssertFalse((text as NSString).substring(with: range).contains("one"))
        XCTAssertFalse((text as NSString).substring(with: range).contains("three"))
    }

    /// Empty text must not produce a range that would crash `addAttribute`.
    func test_emptyTextYieldsAnEmptyRange() {
        let range = WritingModes.paragraphRange(in: "", caret: 0)
        XCTAssertEqual(range.length, 0)
        XCTAssertEqual(range.location, 0)
    }

    /// A stale caret past the end — an ordinary state right after an edit —
    /// must clamp rather than run off the end of the string.
    func test_acaretPastTheEndClamps() {
        let text = "only paragraph"
        let range = WritingModes.paragraphRange(in: text, caret: 9999)
        XCTAssertLessThanOrEqual(range.location + range.length, (text as NSString).length)
    }

    func test_asingleParagraphDocumentFocusesAllOfIt() {
        let text = "just the one paragraph here"
        let range = WritingModes.paragraphRange(in: text, caret: 3)
        XCTAssertEqual(range.length, (text as NSString).length)
    }

    // MARK: - Typewriter scrolling

    /// Above centre, not at it: centring wastes half the screen on text not
    /// yet written.
    func test_theAnchorSitsAboveCentre() {
        XCTAssertLessThan(WritingModes.typewriterAnchor, 0.5)
        XCTAssertGreaterThan(WritingModes.typewriterAnchor, 0.25)
    }

    func test_theCaretIsPlacedAtTheAnchorLine() {
        let origin = WritingModes.typewriterOrigin(caretY: 1000, viewportHeight: 600,
                                                   documentHeight: 5000)
        XCTAssertEqual(origin, 1000 - 600 * WritingModes.typewriterAnchor, accuracy: 0.001)
    }

    /// Without clamping, the top of a short document scrolls into negative
    /// space — a band of nothing above the first line.
    func test_scrollingNeverGoesAboveTheDocument() {
        XCTAssertEqual(WritingModes.typewriterOrigin(caretY: 10, viewportHeight: 600,
                                                     documentHeight: 5000), 0)
    }

    /// …and never past its end.
    func test_scrollingNeverGoesPastTheEnd() {
        let origin = WritingModes.typewriterOrigin(caretY: 4900, viewportHeight: 600,
                                                   documentHeight: 5000)
        XCTAssertEqual(origin, 4400, accuracy: 0.001)
    }

    /// A document shorter than the viewport cannot scroll at all.
    func test_ashortDocumentDoesNotScroll() {
        XCTAssertEqual(WritingModes.typewriterOrigin(caretY: 100, viewportHeight: 600,
                                                     documentHeight: 200), 0)
    }

    // MARK: - Settings

    /// Both modes are strong opinions about how a page behaves. An editor that
    /// dims most of the document the first time it opens reads as broken.
    func test_bothModesDefaultOff() {
        XCTAssertFalse(EditorSettings.default.focusMode)
        XCTAssertFalse(EditorSettings.default.typewriterMode)
    }

    /// Zoom must not silently switch a writing mode off.
    func test_zoomPreservesTheWritingModes() {
        let settings = EditorSettings(density: .standard, measure: .standard, zoomStep: 0,
                                      focusMode: true, typewriterMode: true)
        XCTAssertTrue(settings.zoomed(by: 2).focusMode)
        XCTAssertTrue(settings.zoomed(by: 2).typewriterMode)
        XCTAssertTrue(settings.zoomReset().focusMode)
        XCTAssertTrue(settings.zoomReset().typewriterMode)
    }
}
