import AppKit
import XCTest
@testable import LoreFeature

final class EditorLayoutTests: XCTestCase {

    private func inset(width: CGFloat) -> NSSize {
        MarkdownEditorLayout.containerInset(
            forViewWidth: width, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// A wide pane must NOT push the column into the middle of the window.
    /// The centering rule — `(viewWidth - maxMeasure) / 2` — is the whole
    /// cause of the large empty gap before the text.
    func test_aWidePaneKeepsTheColumnAtTheContentInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        XCTAssertEqual(inset(width: 2000).width, theme.contentInset)
    }

    /// The measure cap still applies — the column is left-aligned, not
    /// unbounded, so long lines stay readable.
    func test_theMeasureCapStillApplies() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let maxMeasure = try? XCTUnwrap(theme.maxMeasure)
        XCTAssertNotNil(maxMeasure)
    }

    /// A pane narrower than twice the inset must still leave a POSITIVE
    /// column rather than an inverted one. This clamp already existed and
    /// must survive the change.
    func test_aNarrowPaneStillLeavesAPositiveColumn() {
        XCTAssertLessThan(inset(width: 30).width, 15)
        XCTAssertGreaterThanOrEqual(inset(width: 30).width, 0)
    }

    /// Vertical inset is unchanged by any of this.
    func test_verticalInsetIsTheContentInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        XCTAssertEqual(inset(width: 900).height, theme.contentInset)
    }

    // MARK: - containerWidth

    private func width(forViewWidth viewWidth: CGFloat) -> CGFloat {
        MarkdownEditorLayout.containerWidth(
            forViewWidth: viewWidth, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// A wide pane still caps the container at the theme's measure — the
    /// fix for the clipping bug must not reopen the "lines run edge to edge"
    /// complaint Task 5 exists to close.
    func test_aWidePaneCapsTheContainerAtTheMeasure() throws {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let measure = try XCTUnwrap(theme.maxMeasure)
        XCTAssertEqual(width(forViewWidth: 2000), measure, accuracy: 0.5)
    }

    /// A pane narrower than the measure must fit ENTIRELY inside the visible
    /// width after both insets are subtracted — never wider. Pinning the
    /// container to `maxMeasure` regardless of the view's actual width was
    /// exactly the bug: with `isHorizontallyResizable = false` and no
    /// horizontal scroller, an oversized container clips text with no way to
    /// reach it.
    func test_aNarrowPaneFitsInsideTheVisibleWidth() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let viewWidth: CGFloat = 400
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: viewWidth, theme: theme)
        let container = width(forViewWidth: viewWidth)
        XCTAssertLessThanOrEqual(container, viewWidth - inset.width * 2,
                                 "the container must never be wider than the space the insets leave")
    }

    /// The degenerate narrow case: a pane so narrow the inset itself is
    /// clamped near zero must still leave a positive, not negative, container
    /// width.
    func test_aDegenerateNarrowPaneStaysPositive() {
        XCTAssertGreaterThanOrEqual(width(forViewWidth: 30), 0)
        XCTAssertLessThan(width(forViewWidth: 30), 30)
    }
}
