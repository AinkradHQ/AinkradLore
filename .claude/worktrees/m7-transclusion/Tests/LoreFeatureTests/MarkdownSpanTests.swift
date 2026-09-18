import XCTest
@testable import LoreFeature

final class MarkdownDocumentModelTests: XCTestCase {

    func test_reportsFencedCodeAsCode() {
        let text = "before\n\n```\nlet x = 1\n```\n\nafter\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        let inside = ns.range(of: "let x = 1").location
        XCTAssertTrue(model.isInsideCode(utf16Offset: inside))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "before").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "after").location))
    }

    func test_reportsInlineCodeAsCode() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "b").location))
    }

    func test_skipsFrontmatterWhenComputingOffsets() {
        let text = "---\nid: a\ntitle: T\n---\n\n```\ncode\n```\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "title").location))
    }

    func test_handlesCRLFDocuments() {
        let text = "before\r\n\r\n```\r\ncode\r\n```\r\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "code").location))
    }

    func test_emptyDocumentDoesNotCrash() {
        let model = MarkdownDocumentModel(fullText: "")
        XCTAssertTrue(model.codeRangesUTF16.isEmpty)
        XCTAssertFalse(model.isInsideCode(utf16Offset: 0))
    }

    // MARK: - End-position convention

    /// Pins the inclusive-vs-exclusive question empirically.
    ///
    /// swift-markdown converts cmark's INCLUSIVE end column into an EXCLUSIVE
    /// one before handing over a `SourceRange`, so the reported range covers
    /// exactly "`code`" — backticks included, nothing beyond. If a `+1` were
    /// added when mapping, this substring would gain a trailing space; if
    /// cmark's raw inclusive column leaked through, it would lose the closing
    /// backtick.
    func test_inlineCodeRangeCoversExactlyTheSpanIncludingBackticks() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(model.codeRangesUTF16.count, 1)
        let covered = (text as NSString).substring(with: model.codeRangesUTF16[0])
        XCTAssertEqual(covered, "`code`")
    }

    /// The character immediately after the closing backtick is NOT code.
    func test_codeRangeDoesNotOverrunByOne() {
        let text = "a `code` b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        let closingTick = ns.range(of: "`code`").location + 5
        XCTAssertTrue(model.isInsideCode(utf16Offset: closingTick))
        XCTAssertFalse(model.isInsideCode(utf16Offset: closingTick + 1))
    }

    func test_reportsIndentedCodeAsCode() {
        let text = "para\n\n    indented code\n\ntail\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "indented").location))
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "tail").location))
    }

    /// The reason this task exists: a wikilink inside a fence must be inside a
    /// reported code region so Task 4 can drop it.
    func test_wikilinkInsideFenceIsInsideCode() {
        let text = "real [[A]]\n\n```\n[[B]]\n```\n"
        let model = MarkdownDocumentModel(fullText: text)
        let ns = text as NSString
        XCTAssertFalse(model.isInsideCode(utf16Offset: ns.range(of: "[[A]]").location))
        XCTAssertTrue(model.isInsideCode(utf16Offset: ns.range(of: "[[B]]").location))
    }

    /// Non-ASCII before the span: cmark columns are UTF-8 BYTES, so a naive
    /// column-as-offset mapping would land short.
    func test_handlesMultiByteCharactersBeforeInlineCode() {
        let text = "é👍 `code` x\n"
        let model = MarkdownDocumentModel(fullText: text)
        let covered = (text as NSString).substring(with: model.codeRangesUTF16[0])
        XCTAssertEqual(covered, "`code`")
    }

    // MARK: - Region kinds
    //
    // swift-markdown models fenced and indented code as the same `CodeBlock`
    // node, and `fenceInfo` is nil for a bare ``` opener as well as for
    // indented code, so the kind is derived from the source text at the
    // region's start. The link graph depends on this discrimination.

    func test_tagsFencedAndIndentedCodeBlocksDifferently() {
        let model = MarkdownDocumentModel(
            fullText: "```\nfenced\n```\n\npara\n\n    indented\n")
        XCTAssertEqual(model.codeRegions.map(\.kind),
                       [.fencedCodeBlock, .indentedCodeBlock])
    }

    /// Up to three leading spaces still make a fence.
    func test_tagsAnIndentedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "para\n\n   ```\n   x\n   ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    /// `CodeBlock.range` starts at the block's CONTENT, past any indent, so an
    /// indented block whose content is itself a fence looks fence-shaped from
    /// its start offset. The bare closing run inside its own content is what
    /// gives it away.
    func test_tagsAnIndentedBlockOfBackticksAsIndented() {
        let model = MarkdownDocumentModel(fullText: "para\n\n    ```\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.indentedCodeBlock])
    }

    func test_tagsAnIndentedBlockOpeningWithAnInfoStringAsIndented() {
        let model = MarkdownDocumentModel(
            fullText: "para\n\n    ```swift\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.indentedCodeBlock])
    }

    /// A fence pushed past column 4 by list nesting is still fenced.
    func test_tagsAListNestedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "- a\n  - b\n\n    ```\n    x\n    ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsABlockquotedFenceAsFenced() {
        let model = MarkdownDocumentModel(fullText: "> ```\n> x\n> ```\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    /// A shorter or non-bare run inside the content is not a closer.
    func test_tagsAFenceWithNonClosingRunsInItsContentAsFenced() {
        let model = MarkdownDocumentModel(fullText: "````\n```text\nx\n````\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsTildeFencesAsFenced() {
        let model = MarkdownDocumentModel(fullText: "~~~\nx\n~~~\n")
        XCTAssertEqual(model.codeRegions.map(\.kind), [.fencedCodeBlock])
    }

    func test_tagsInlineCodeAndHTMLBlocks() {
        let model = MarkdownDocumentModel(fullText: "a `c` b\n\n<div>\nx\n</div>\n")
        XCTAssertEqual(Set(model.codeRegions.map(\.kind)), [.inlineCode, .htmlBlock])
    }

    /// The kind-filtered query must ignore regions of other kinds, while the
    /// unfiltered one keeps its original all-kinds meaning.
    func test_kindFilteredQueryIgnoresOtherKinds() {
        let text = "para\n\n    indented\n"
        let model = MarkdownDocumentModel(fullText: text)
        let offset = (text as NSString).range(of: "indented").location
        XCTAssertTrue(model.isInsideCode(utf16Offset: offset))
        XCTAssertFalse(model.isInsideCode(utf16Offset: offset,
                                          kinds: MarkdownDocumentModel.linkSuppressingKinds))
    }
}

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
        XCTAssertFalse(spans.contains { if case .heading = $0.kind { return true }; return false })
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
            XCTAssertLessThanOrEqual(span.range.upperBound, ns.length,
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
        XCTAssertEqual(ns.substring(with: NSRange(location: span!.range.lowerBound,
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
        XCTAssertEqual(ns.substring(with: NSRange(location: span!.range.lowerBound,
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
        XCTAssertEqual(ns.substring(with: NSRange(location: span!.range.lowerBound,
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
        XCTAssertEqual(ns.substring(with: NSRange(location: span!.range.lowerBound,
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

/// Task 6b: the suppression check went from a linear scan over every region to
/// a binary search over their coalesced union. The union is the whole argument
/// for why that is legal, so it is checked directly rather than trusted.
final class CodeRegionIndexTests: XCTestCase {

    private func linear(_ regions: [CodeRegion], _ kinds: Set<CodeRegionKind>?,
                        _ offset: Int) -> Bool {
        regions.contains {
            (kinds?.contains($0.kind) ?? true) && NSLocationInRange(offset, $0.range)
        }
    }

    /// Exhaustive equivalence with the predicate that was replaced, over
    /// shapes the coalescing has to survive: overlaps, touching ranges,
    /// containment, out-of-order input, zero length, and mixed kinds.
    func test_theIndexAnswersExactlyWhatTheLinearScanAnswered() {
        let regions = [
            CodeRegion(range: NSRange(location: 40, length: 5), kind: .inlineCode),
            CodeRegion(range: NSRange(location: 0, length: 3), kind: .fencedCodeBlock),
            CodeRegion(range: NSRange(location: 3, length: 2), kind: .fencedCodeBlock),
            CodeRegion(range: NSRange(location: 10, length: 8), kind: .indentedCodeBlock),
            CodeRegion(range: NSRange(location: 12, length: 2), kind: .inlineCode),
            CodeRegion(range: NSRange(location: 20, length: 0), kind: .inlineCode),
            CodeRegion(range: NSRange(location: 25, length: 6), kind: .htmlBlock),
            CodeRegion(range: NSRange(location: 28, length: 10), kind: .fencedCodeBlock),
        ]
        let kindSets: [Set<CodeRegionKind>?] = [
            nil,
            MarkdownDocumentModel.linkSuppressingKinds,
            [.htmlBlock],
            [.indentedCodeBlock, .htmlBlock],
            [],
        ]
        for kinds in kindSets {
            let index = CodeRegionIndex(regions: regions, kinds: kinds)
            for offset in -5...60 {
                XCTAssertEqual(index.contains(offset), linear(regions, kinds, offset),
                               "offset \(offset), kinds \(String(describing: kinds))")
            }
        }
    }

    func test_anEmptyIndexContainsNothing() {
        let index = CodeRegionIndex(regions: [], kinds: nil)
        XCTAssertTrue(index.isEmpty)
        for offset in -1...10 { XCTAssertFalse(index.contains(offset)) }
    }

    /// Kinds are filtered BEFORE coalescing. Merging first would let the
    /// indented block below extend the fenced one and widen link suppression
    /// over `[[X]]`, which the milestone's ruling forbids.
    func test_filteringHappensBeforeCoalescing() {
        let regions = [
            CodeRegion(range: NSRange(location: 0, length: 5), kind: .fencedCodeBlock),
            CodeRegion(range: NSRange(location: 5, length: 5), kind: .indentedCodeBlock),
        ]
        let index = CodeRegionIndex(regions: regions,
                                    kinds: MarkdownDocumentModel.linkSuppressingKinds)
        XCTAssertTrue(index.contains(4))
        XCTAssertFalse(index.contains(5), "an indented block must not suppress")
    }
}

/// The character→UTF-16 map gained an allocation-free identity case. It must
/// agree with the table it replaced, character for character.
final class CharacterOffsetMapTests: XCTestCase {

    private func table(_ text: String) -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for character in text { offsets.append(running); running += character.utf16.count }
        offsets.append(running)
        return offsets
    }

    private func assertAgrees(_ text: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        let expected = table(text)
        let map = CharacterOffsetMap.make(for: text)
        XCTAssertEqual(map.count, expected.count, text.debugDescription,
                       file: file, line: line)
        for i in 0..<expected.count {
            XCTAssertEqual(map[i], expected[i], "\(text.debugDescription) at \(i)",
                           file: file, line: line)
        }
    }

    func test_itAgreesWithTheExplicitTable() {
        assertAgrees("")
        assertAgrees("plain ascii [[Link]] `code`\n")
        assertAgrees("emoji 🙂 and [[Ünï]]\n")
        assertAgrees("combining e\u{0301} tail")
        assertAgrees("family 👨‍👩‍👧‍👦 tail")
        assertAgrees("crlf\r\nlines\r\n")
        assertAgrees("lone \r carriage return")
    }

    /// The fast path is only taken where it is exact. CRLF is ASCII by both
    /// counts but is one Character carrying two UTF-16 units.
    func test_crlfDoesNotTakeTheIdentityPath() {
        guard case .table = CharacterOffsetMap.make(for: "a\r\nb") else {
            return XCTFail("CRLF must not use the identity map")
        }
        guard case .identity = CharacterOffsetMap.make(for: "a\nb") else {
            return XCTFail("plain ASCII should use the identity map")
        }
    }
}

final class MarkdownStyleCacheDeriveTests: XCTestCase {
    /// The editor styles exactly the string it is given — `note.body` for
    /// markdown, the whole file for plain text — so `derive` must not run a
    /// frontmatter scan over it. When it did, a buffer opening with an `---`
    /// thematic break and carrying another bare `---` later had everything
    /// between them excluded from the parse, and that region came back
    /// UNSTYLED: no heading, no bold, no code-block attributes.
    ///
    /// The symptom is omission, not misplacement: `SourceOffsetMap` re-bases
    /// the spans that DO survive, so the styling above the second `---` simply
    /// disappeared rather than landing on the wrong characters. The second half
    /// of this test pins that — the surviving heading below the break stays
    /// where it always was.
    func test_derive_stylesADashOpeningBufferAboveTheSecondBreak() {
        // Blank lines around the second `---` on purpose: `text\n---` is a
        // SETEXT heading in CommonMark, which would change what is being
        // measured. `Frontmatter.closingFenceIndex` is line-based and finds it
        // either way.
        let text = "---\n# Above\n\n**bold**\n\n---\n\n# Below\n"
        let derived = MarkdownStyleCache.derive(text)
        XCTAssertTrue(derived.spans.contains { $0.kind == .heading(1) &&
            $0.range.lowerBound == (text as NSString).range(of: "# Above").location })
        XCTAssertTrue(derived.spans.contains { $0.kind == .strong })
        XCTAssertTrue(derived.spans.contains { $0.kind == .heading(1) &&
            $0.range.lowerBound == (text as NSString).range(of: "# Below").location })
    }
}

final class MarkdownOutlineTests: XCTestCase {
    func test_listsHeadingsWithLevels() {
        let outline = MarkdownDocumentModel(fullText: "# One\n\n## Two\n\n### Three\n").outline
        XCTAssertEqual(outline.map(\.level), [1, 2, 3])
        XCTAssertEqual(outline.map(\.text), ["One", "Two", "Three"])
    }

    func test_aHashInsideAFenceIsNotAHeading() {
        // Shipping bug: `MarkdownEngine.outline` counted this as a heading and
        // it reached the index.
        let outline = MarkdownDocumentModel(fullText: "# Real\n\n```\n# Not a heading\n```\n").outline
        XCTAssertEqual(outline.map(\.text), ["Real"])
    }

    func test_offsetsPointAtTheHeadingInTheFullText() {
        let text = "---\nid: a\n---\n# Title\n"
        let outline = MarkdownDocumentModel(fullText: text).outline
        let ns = text as NSString
        XCTAssertEqual(outline.first?.utf16Offset, ns.range(of: "# Title").location)
    }
}
