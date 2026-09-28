import XCTest
@testable import LoreFeature

/// Keyboard movement in a list, asserted as arithmetic.
///
/// The reconciliation tests matter most. Sidebar search re-ranks the list on
/// every keystroke, so a focus held as a bare INDEX across that change points
/// at a different document than the one highlighted a moment ago — and Return
/// would then open something the user never looked at. That is the failure
/// this type exists to make impossible.
final class LoreListNavigationTests: XCTestCase {

    // MARK: - Movement

    /// The ↓-from-the-search-field case: the first press lands on the TOP hit,
    /// not the second one.
    func test_downFromNothingSelectsTheFirstRow() {
        XCTAssertEqual(LoreListNavigation.move(.down, from: nil, count: 5), 0)
    }

    /// ↑ into a list from below mirrors ↓ into it from above.
    func test_upFromNothingSelectsTheLastRow() {
        XCTAssertEqual(LoreListNavigation.move(.up, from: nil, count: 5), 4)
    }

    /// No wrapping. In a list longer than the viewport, wrapping teleports the
    /// focus off-screen and reads as the list having lost the selection.
    func test_movementClampsRatherThanWrapping() {
        XCTAssertEqual(LoreListNavigation.move(.down, from: 4, count: 5), 4)
        XCTAssertEqual(LoreListNavigation.move(.up, from: 0, count: 5), 0)
    }

    func test_ordinaryMovementStepsByOne() {
        XCTAssertEqual(LoreListNavigation.move(.down, from: 1, count: 5), 2)
        XCTAssertEqual(LoreListNavigation.move(.up, from: 3, count: 5), 2)
    }

    /// Every caller is about to subscript an array, so an empty list must
    /// yield nil rather than 0.
    func test_anEmptyListHasNowhereToMove() {
        XCTAssertNil(LoreListNavigation.move(.down, from: nil, count: 0))
        XCTAssertNil(LoreListNavigation.move(.up, from: 2, count: 0))
    }

    /// A stale index from a longer list must not survive into a shorter one.
    func test_movementClampsAnOutOfRangeStartingPoint() {
        XCTAssertEqual(LoreListNavigation.move(.down, from: 99, count: 3), 2)
    }

    // MARK: - Reconciliation across a re-rank

    /// The core rule: focus follows the ITEM, not the position. Typing another
    /// letter re-ranks the list; the highlighted document must still be the
    /// highlighted document.
    func test_focusFollowsTheItemWhenTheListReRanks() {
        let before = ["a.md", "b.md", "c.md"]
        let after = ["c.md", "a.md", "b.md"]
        let focused = before[2]                      // "c.md"
        XCTAssertEqual(LoreListNavigation.reconciled(previous: focused, ids: after), 0,
                       "focus must follow c.md to its new position, not stay at index 2")
    }

    /// When the focused item is gone — deleted, or filtered out by the next
    /// keystroke — focus falls to the first row rather than to nil, so the
    /// next ↓ continues from somewhere visible.
    func test_focusFallsToTheFirstRowWhenTheItemIsGone() {
        XCTAssertEqual(LoreListNavigation.reconciled(previous: "gone.md",
                                                     ids: ["a.md", "b.md"]), 0)
    }

    func test_reconcilingAnEmptyListYieldsNothing() {
        XCTAssertNil(LoreListNavigation.reconciled(previous: "a.md", ids: [String]()))
    }

    /// Nothing focused, then a list arrives: start at the top.
    func test_reconcilingWithNoPreviousFocusStartsAtTheTop() {
        XCTAssertEqual(LoreListNavigation.reconciled(previous: String?.none,
                                                     ids: ["a.md", "b.md"]), 0)
    }
}
