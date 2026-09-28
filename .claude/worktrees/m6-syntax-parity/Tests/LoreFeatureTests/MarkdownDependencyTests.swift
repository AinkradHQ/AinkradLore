import XCTest
import Markdown
@testable import LoreFeature

final class MarkdownDependencyTests: XCTestCase {
    func test_parsesAHeadingAndAParagraph() {
        let doc = Document(parsing: "# Title\n\nbody text\n")
        XCTAssertEqual(doc.childCount, 2)
        XCTAssertTrue(doc.child(at: 0) is Heading)
        XCTAssertEqual((doc.child(at: 0) as? Heading)?.level, 1)
    }

    func test_reportsSourceRanges() {
        let doc = Document(parsing: "# Title\n")
        let heading = doc.child(at: 0) as? Heading
        XCTAssertNotNil(heading?.range, "source ranges must be populated; later tasks depend on them")
    }
}
