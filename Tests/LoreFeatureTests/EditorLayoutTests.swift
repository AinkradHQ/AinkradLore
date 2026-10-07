import AppKit
import XCTest

@testable import LoreFeature

final class EditorLayoutTests: XCTestCase {

    private func inset(width: CGFloat) -> NSSize {
        MarkdownEditorLayout.containerInset(
            forViewWidth: width, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// A theme whose measure actually CAPS.
    ///
    /// The default measure is `.full` since the owner asked for the full width,
    /// so `MarkdownTheme(tokens:)` no longer has a cap at all — and the tests
    /// below are about the capping mechanism, not about the default. Using the
    /// default made them silently test nothing.
    private func cappedTheme() -> MarkdownTheme {
        MarkdownTheme(
            tokens: TestTokens.make(),
            settings: EditorSettings(
                density: .standard, measure: .standard,
                zoomStep: 0))
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
        XCTAssertNotNil(
            cappedTheme().maxMeasure,
            "a capped measure must still produce a cap")
        // And the DEFAULT is deliberately uncapped now — recorded here so the
        // change is visible where the cap is asserted, not only where it was
        // made.
        XCTAssertNil(
            MarkdownTheme(tokens: TestTokens.make()).maxMeasure,
            "the default measure is full width")
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

    private func width(
        forViewWidth viewWidth: CGFloat,
        theme: MarkdownTheme? = nil
    ) -> CGFloat {
        MarkdownEditorLayout.containerWidth(
            forViewWidth: viewWidth,
            theme: theme ?? MarkdownTheme(tokens: TestTokens.make()))
    }

    /// A wide pane still caps the container at the theme's measure — the
    /// fix for the clipping bug must not reopen the "lines run edge to edge"
    /// complaint Task 5 exists to close.
    func test_aWidePaneCapsTheContainerAtTheMeasure() throws {
        let theme = cappedTheme()
        let measure = try XCTUnwrap(theme.maxMeasure)
        XCTAssertEqual(width(forViewWidth: 2000, theme: theme), measure, accuracy: 0.5)
    }

    /// And with the default measure — full width — a wide pane fills it, minus
    /// both insets. This is the behaviour the owner asked for, asserted where
    /// the container width is decided.
    func test_aWidePaneWithNoCapFillsTheAvailableWidth() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        XCTAssertEqual(
            width(forViewWidth: 2000, theme: theme),
            2000 - theme.contentInset * 2, accuracy: 0.5)
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
        XCTAssertLessThanOrEqual(
            container, viewWidth - inset.width * 2,
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
