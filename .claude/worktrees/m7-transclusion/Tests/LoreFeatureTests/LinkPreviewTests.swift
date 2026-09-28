import XCTest
@testable import LoreFeature

/// What a hover preview shows.
final class LinkPreviewTests: XCTestCase {

    func test_frontmatterIsNotThePreview() {
        let contents = """
        ---
        id: a
        title: Alpha
        tags: [work]
        ---
        The actual first sentence.
        """
        XCTAssertEqual(LinkPreview.excerpt(from: contents), "The actual first sentence.")
    }

    /// The link already says the title, so repeating it as the preview's first
    /// line answers nothing — the reader wants the first thing they have NOT
    /// already seen.
    func test_theLeadingHeadingIsSkipped() {
        let contents = "# Alpha\n\nBody starts here."
        XCTAssertEqual(LinkPreview.excerpt(from: contents), "Body starts here.")
    }

    func test_blankLinesCollapse() {
        XCTAssertEqual(LinkPreview.excerpt(from: "one\n\n\ntwo"), "one two")
    }

    /// Truncation cuts at a WORD boundary: a preview ending "the imple…" reads
    /// as corruption rather than as truncation.
    func test_longTextIsTruncatedAtAWordBoundary() {
        let long = String(repeating: "alpha beta ", count: 60)
        let excerpt = LinkPreview.excerpt(from: long)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertLessThanOrEqual(excerpt.count, LinkPreview.characterBudget + 1)
        let body = excerpt.dropLast()
        XCTAssertFalse(body.hasSuffix("alph"), "cut mid-word")
        XCTAssertTrue(body.hasSuffix("alpha") || body.hasSuffix("beta"))
    }

    func test_shortTextIsNotTruncated() {
        XCTAssertEqual(LinkPreview.excerpt(from: "short"), "short")
    }

    /// An empty note is a real answer to "what is in there" — the panel says
    /// so rather than showing a blank box.
    func test_anEmptyDocumentYieldsAnEmptyExcerpt() {
        XCTAssertEqual(LinkPreview.excerpt(from: "---\nid: a\n---\n"), "")
        XCTAssertEqual(LinkPreview.excerpt(from: "# Only a heading"), "")
    }
}
