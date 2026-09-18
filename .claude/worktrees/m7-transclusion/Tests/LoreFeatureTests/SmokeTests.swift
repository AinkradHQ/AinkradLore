import XCTest
@testable import LoreFeature

@MainActor
final class SmokeTests: XCTestCase {
    func test_loreApp_identity() {
        XCTAssertEqual(LoreApp.id, "lore")
        XCTAssertEqual(LoreApp.displayName, "Lore")
    }
}
