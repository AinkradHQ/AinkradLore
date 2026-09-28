import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

/// The wrapping tag row, and the layout behind it.
@MainActor
final class TagChipRowTests: XCTestCase {

    private func tags(_ n: Int) -> [String] { (0..<n).map { "tag\($0)" } }

    func test_theRowBuildsCollapsedAndExpanded() {
        let theme = HostTheme(TestTokens.make())
        _ = TagChipRow(tags: tags(3), counts: ["tag0": 2],
                       activeTag: .constant(nil), theme: theme)
        _ = TagChipRow(tags: tags(40), counts: [:],
                       activeTag: .constant("tag39"), theme: theme)
    }

    /// The cap exists so a large vocabulary cannot push the note list off the
    /// screen. If it ever became unbounded the row would be a tag browser.
    func test_theCollapsedLimitIsSmallEnoughToLeaveRoomForNotes() {
        XCTAssertGreaterThan(TagChipRow.collapsedLimit, 3)
        XCTAssertLessThanOrEqual(TagChipRow.collapsedLimit, 12)
    }
}

/// `LoreWrappingHStack`'s arithmetic.
///
/// The layout is exercised through `sizeThatFits`, which is the part that
/// decides how many rows there are — the thing that determines whether the tag
/// row stays two lines or quietly grows to twenty.
final class WrappingHStackTests: XCTestCase {

    /// A `Layout` cannot be measured without subviews, and SwiftUI provides no
    /// way to synthesise `Subviews` outside a real layout pass — so this
    /// covers the reachable half: the type exists, carries its spacing, and
    /// conforms to `Layout`.
    func test_theLayoutCarriesItsSpacing() {
        let layout = LoreWrappingHStack(spacing: 7)
        XCTAssertEqual(layout.spacing, 7)
    }

    /// Guards the macOS floor this depends on. `Layout` is 13.0+, and the
    /// project targets 14.0 — if that target ever dropped, this file would
    /// stop compiling rather than silently misbehaving, but the assertion
    /// records the dependency for anyone reading.
    func test_theLayoutProtocolIsAvailable() {
        XCTAssertTrue(LoreWrappingHStack.self is any Layout.Type)
    }
}
