import XCTest
@testable import LoreFeature

/// Task 9: the code-block span's info string, and the exact range it covers.
///
/// Split out of `MarkdownSpanTests.swift`, which is near this repo's
/// 500-line-per-file ceiling.
final class CodeBlockLanguageTests: XCTestCase {

    func test_codeBlockSpanReportsItsInfoString() {
        let spans = MarkdownDocumentModel(fullText: "```swift\nlet x = 1\n```\n").styleSpans
        let langs: [String?] = spans.compactMap {
            if case .codeBlock(let language) = $0.kind { return language }
            return nil
        }
        XCTAssertEqual(langs, ["swift"])
    }

    func test_codeBlockWithoutAnInfoStringHasNoLanguage() {
        let spans = MarkdownDocumentModel(fullText: "```\nplain\n```\n").styleSpans
        let langs: [String?] = spans.compactMap {
            if case .codeBlock(let language) = $0.kind { return language }
            return nil
        }
        XCTAssertEqual(langs, [String?.none])
    }

    /// Pins the fence question empirically, rather than trusting the AST's
    /// doc comment alone: does the span cover the opening fence line
    /// (`` ```swift ``), or only the content? This decides whether the
    /// renderer can attribute the language label to the fence line itself, or
    /// must locate it separately.
    func test_codeBlockSpanRangeIncludesTheOpeningFence() {
        let text = "```swift\nlet x = 1\n```\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { if case .codeBlock = $0.kind { return true }; return false }
        XCTAssertNotNil(span)
        let covered = ns.substring(with: NSRange(location: span!.range.lowerBound,
                                                  length: span!.range.count))
        XCTAssertEqual(covered, "```swift\nlet x = 1\n```")
    }
}
