import XCTest
@testable import LoreFeature

final class LoreSidebarMetricsTests: XCTestCase {

    /// The root level sits flush. Anything else and the top-level folders
    /// would be inset from the search field above them for no reason.
    func test_rootDepthHasNoIndent() {
        XCTAssertEqual(LoreSidebarMetrics.indent(depth: 0), 0)
    }

    /// One unit per level, so a document and a subfolder at the same depth
    /// land in the same column. The old code indented documents by
    /// `(depth + 1)` and folders by `depth`, which is exactly why a file's
    /// icon sat right of its sibling folder's chevron.
    func test_indentIsOneUnitPerLevel() {
        XCTAssertEqual(LoreSidebarMetrics.indent(depth: 1),
                       LoreSidebarMetrics.indentUnit)
        XCTAssertEqual(LoreSidebarMetrics.indent(depth: 3),
                       LoreSidebarMetrics.indentUnit * 3)
    }

    /// A malformed depth must not produce a negative leading pad, which
    /// SwiftUI renders by pulling the row out of its container.
    func test_negativeDepthClampsToZero() {
        XCTAssertEqual(LoreSidebarMetrics.indent(depth: -2), 0)
    }
}
