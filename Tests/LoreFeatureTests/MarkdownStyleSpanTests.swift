import XCTest

@testable import LoreFeature

final class MarkdownStyleSpanTests: XCTestCase {
    private func kinds(_ text: String) -> [StyleSpan.Kind] {
        MarkdownDocumentModel(fullText: text).styleSpans.map(\.kind)
    }

    func test_headingCarriesItsLevel() {
        XCTAssertTrue(kinds("## Two\n").contains(.heading(2)))
    }

    func test_strongAndEmphasis() {
        let k = kinds("**bold** and *italic*\n")
        XCTAssertTrue(k.contains(.strong))
        XCTAssertTrue(k.contains(.emphasis))
    }

    func test_codeBlockCarriesItsLanguage() {
        let k = kinds("```swift\nlet x = 1\n```\n")
        XCTAssertTrue(k.contains(.codeBlock(language: "swift")))
    }

    // See CodeBlockLanguageTests.swift for the info-string / fence-range tests
    // added by Task 9 — kept out of this file, which is near the repo's
    // 500-line-per-file ceiling.

    func test_nothingInsideAFenceIsStyledAsProse() {
        // The bug this milestone exists to fix: the regex styler bolded this.
        let spans = MarkdownDocumentModel(fullText: "```\n**not bold** # not heading\n```\n").styleSpans
        XCTAssertFalse(spans.contains { $0.kind == .strong })
        XCTAssertFalse(
            spans.contains {
                if case .heading = $0.kind { return true }
                return false
            })
    }

    func test_taskCheckboxStateIsReported() {
        let k = kinds("- [ ] open\n- [x] done\n")
        XCTAssertTrue(k.contains(.checkbox(false)))
        XCTAssertTrue(k.contains(.checkbox(true)))
    }

    func test_spanRangesAreValidUTF16RangesIntoTheFullText() {
        let text = "---\nid: a\n---\n# 👍 Title\n"
        let ns = text as NSString
        for span in MarkdownDocumentModel(fullText: text).styleSpans {
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, 0)
            XCTAssertLessThanOrEqual(
                span.range.upperBound, ns.length,
                "a span past the end would crash the text view")
        }
    }

    // MARK: - Ranges, not just kinds

    /// A span whose range is off by one is invisible in a kind-only assertion
    /// and glaring in the editor.
    func test_strongSpanCoversItsMarkersExactly() {
        let text = "a **bold** b\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { $0.kind == .strong }
        XCTAssertNotNil(span)
        XCTAssertEqual(
            ns.substring(
                with: NSRange(
                    location: span!.range.lowerBound,
                    length: span!.range.count)),
            "**bold**")
    }

    /// Frontmatter shifts every body offset; an emoji makes byte columns lie.
    func test_headingRangeIsCorrectPastFrontmatterAndEmoji() {
        let text = "---\nid: a\n---\n# 👍 Title\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { $0.kind == .heading(1) }
        XCTAssertNotNil(span)
        XCTAssertEqual(
            ns.substring(
                with: NSRange(
                    location: span!.range.lowerBound,
                    length: span!.range.count)),
            "# 👍 Title")
    }

    /// Wikilinks are not AST nodes; they come from `LinkParser`, whose ranges
    /// are CHARACTER offsets and must be converted.
    func test_wikilinkSpanCoversTheTargetInUTF16Offsets() {
        let text = "👍 [[Design]]\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { $0.kind == .wikilink }
        XCTAssertNotNil(span)
        XCTAssertEqual(
            ns.substring(
                with: NSRange(
                    location: span!.range.lowerBound,
                    length: span!.range.count)),
            "Design")
    }

    /// The link parser already suppresses links inside code; the styler must
    /// inherit that rather than re-deciding it.
    func test_wikilinkInsideAFenceIsNotStyled() {
        let spans = MarkdownDocumentModel(fullText: "```\n[[B]]\n```\n").styleSpans
        XCTAssertFalse(spans.contains { $0.kind == .wikilink })
    }

    func test_markdownLinkListItemAndBlockQuoteAreReported() {
        XCTAssertTrue(kinds("[t](a.md)\n").contains(.link))
        XCTAssertTrue(kinds("- one\n").contains(.listItem))
        XCTAssertTrue(kinds("> quoted\n").contains(.blockQuote))
    }

    func test_inlineCodeIsReported() {
        XCTAssertTrue(kinds("run `ls` now\n").contains(.inlineCode))
    }

    func test_emptyDocumentHasNoSpans() {
        XCTAssertTrue(MarkdownDocumentModel(fullText: "").styleSpans.isEmpty)
    }

    /// The marker is the EARLIEST bracket pair, not the first spelling that
    /// matches: this item is checked and merely mentions `[ ]` in its prose.
    func test_checkboxSpanCoversTheMarkerNotLaterBracketsInTheProse() {
        let text = "- [x] see [ ] later\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { $0.kind == .checkbox(true) }
        XCTAssertNotNil(span)
        XCTAssertEqual(span!.range.lowerBound, ns.range(of: "[x]").location)
    }

    /// Wikilink spans are derived on demand, so no caller can observe a model
    /// that has AST spans but silently lacks wikilinks. Every model answers
    /// fully; `astStyleSpans` is the explicitly partial view, and its name
    /// says so.
    func test_everyModelReportsWikilinksNoMatterHowItWasBuilt() {
        let model = MarkdownDocumentModel(fullText: "[[Design]]\n")
        XCTAssertTrue(model.styleSpans.contains { $0.kind == .wikilink })
        XCTAssertFalse(model.astStyleSpans.contains { $0.kind == .wikilink })
    }

    /// CRLF is the case where the model must NOT hand its regions to the
    /// parser: `"\r\n"` is one Character but two UTF-16 units, so regions
    /// computed pre-normalisation point elsewhere in the string the parser
    /// scans. Injecting them anyway would misplace or lose this span.
    func test_wikilinkSpansAreCorrectInCRLFDocuments() {
        let text = "intro\r\n\r\n[[Design]]\r\n"
        let ns = text as NSString
        let span = MarkdownDocumentModel(fullText: text).styleSpans
            .first { $0.kind == .wikilink }
        XCTAssertNotNil(span)
        XCTAssertEqual(
            ns.substring(
                with: NSRange(
                    location: span!.range.lowerBound,
                    length: span!.range.count)),
            "Design")
    }

    /// Injection must not change what the parser answers. Same document, one
    /// scan with the model's regions handed over and one without.
    func test_injectedCodeRegionsGiveTheSameLinksAsParsingAfresh() {
        let text = "real [[A]]\n\n```\n[[B]]\n```\n\n`[[C]]` [[D]]\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(
            LinkParser.spans(in: text, codeRegions: model.codeRegions),
            LinkParser.spans(in: text, codeRegions: nil))
        XCTAssertEqual(LinkParser.links(in: text).map(\.rawTarget), ["A", "D"])
    }
}
