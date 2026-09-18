import XCTest
@testable import LoreFeature

/// The spine rail's arithmetic: where each tick sits, and which one is active.
@MainActor
final class SpineRailTests: XCTestCase {

    private func entry(_ level: Int, _ offset: Int) -> OutlineEntry {
        OutlineEntry(level: level, text: "h\(level)@\(offset)", utf16Offset: offset)
    }

    // MARK: - Placement

    func test_fractionIsProportionalToOffset() {
        XCTAssertEqual(LoreSpineRail.fraction(of: 0, in: 100), 0)
        XCTAssertEqual(LoreSpineRail.fraction(of: 50, in: 100), 0.5)
        XCTAssertEqual(LoreSpineRail.fraction(of: 100, in: 100), 1)
    }

    /// An empty document would divide by zero and place every tick at NaN,
    /// which SwiftUI renders as a blank rail with no error at all — the kind
    /// of failure that looks like "the feature does not work" rather than
    /// like a bug.
    func test_anEmptyDocumentDoesNotDivideByZero() {
        let fraction = LoreSpineRail.fraction(of: 10, in: 0)
        XCTAssertEqual(fraction, 0)
        XCTAssertFalse(fraction.isNaN)
    }

    /// An offset past the end (a stale outline mid-edit) clamps rather than
    /// placing a tick below the rail where nothing can reach it.
    func test_offsetsBeyondTheDocumentClamp() {
        XCTAssertEqual(LoreSpineRail.fraction(of: 999, in: 100), 1)
        XCTAssertEqual(LoreSpineRail.fraction(of: -5, in: 100), 0)
    }

    // MARK: - Active heading

    /// The caret is "in" the last heading at or before it.
    func test_theActiveHeadingIsTheLastOneAtOrBeforeTheCaret() {
        let outline = [entry(1, 0), entry(2, 50), entry(2, 120)]
        XCTAssertEqual(LoreSpineRail.activeHeading(in: outline, caretOffset: 0), 0)
        XCTAssertEqual(LoreSpineRail.activeHeading(in: outline, caretOffset: 49), 0)
        XCTAssertEqual(LoreSpineRail.activeHeading(in: outline, caretOffset: 50), 1)
        XCTAssertEqual(LoreSpineRail.activeHeading(in: outline, caretOffset: 200), 2)
    }

    /// A caret above the first heading is a real position — a document with a
    /// preamble — not an error, so nothing is active rather than the first
    /// heading being wrongly highlighted.
    func test_aCaretAboveTheFirstHeadingActivatesNothing() {
        XCTAssertNil(LoreSpineRail.activeHeading(in: [entry(1, 40)], caretOffset: 10))
    }

    func test_anEmptyOutlineHasNoActiveHeading() {
        XCTAssertNil(LoreSpineRail.activeHeading(in: [], caretOffset: 99))
    }

    // MARK: - Tick width

    /// Deeper headings draw shorter ticks, so nesting is legible without a
    /// single character of text.
    func test_tickWidthShrinksWithDepth() {
        let widths = (1...6).map { LoreSpineRail.tickWidth(forLevel: $0) }
        XCTAssertEqual(widths, widths.sorted(by: >), "the ramp must decrease with depth")
        XCTAssertTrue(widths.allSatisfy { $0 > 0 })
    }

    /// A malformed level from a broken document must not produce a negative
    /// width, which is a layout crash rather than a wrong-looking tick.
    func test_tickWidthClampsMalformedLevels() {
        XCTAssertEqual(LoreSpineRail.tickWidth(forLevel: 0),
                       LoreSpineRail.tickWidth(forLevel: 1))
        XCTAssertEqual(LoreSpineRail.tickWidth(forLevel: 99),
                       LoreSpineRail.tickWidth(forLevel: 6))
        XCTAssertGreaterThan(LoreSpineRail.tickWidth(forLevel: -3), 0)
    }
}
