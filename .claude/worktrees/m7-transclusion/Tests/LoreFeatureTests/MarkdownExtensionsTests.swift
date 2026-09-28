import XCTest
@testable import LoreFeature

final class MarkdownExtensionsTests: XCTestCase {

    /// Scans through the model so the code mask is the real one, not a
    /// hand-built approximation that could drift from what ships.
    private func scan(_ body: String) -> [MarkdownExtensions.Span] {
        MarkdownDocumentModel(body: body).extensionSpans
    }

    func test_scan_emptyDocument_returnsNoSpans() {
        XCTAssertTrue(scan("").isEmpty)
    }

    func test_scan_plainProse_returnsNoSpans() {
        XCTAssertTrue(scan("just some ordinary prose, nothing to see").isEmpty)
    }

    func test_highlight_wellFormed() {
        let spans = scan("a ==lit== b")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .highlight)
        XCTAssertEqual(spans.first?.range, 2..<9)     // ==lit==
        XCTAssertEqual(spans.first?.content, 4..<7)   // lit
    }

    func test_highlight_emptyContentEmitsNothing() {
        XCTAssertTrue(scan("a ==== b").isEmpty)
    }

    func test_highlight_unclosedEmitsNothing() {
        XCTAssertTrue(scan("a ==lit b").isEmpty)
    }

    func test_highlight_doesNotCrossLines() {
        // Obsidian's own behaviour: a highlight is single-line.
        XCTAssertTrue(scan("a ==lit\nmore== b").isEmpty)
    }

    func test_highlight_insideCodeFenceEmitsNothing() {
        XCTAssertTrue(scan("```\n==not a highlight==\n```").isEmpty)
    }

    func test_highlight_insideInlineCodeEmitsNothing() {
        XCTAssertTrue(scan("a `==no==` b").isEmpty)
    }

    func test_highlight_twoOnOneLine() {
        XCTAssertEqual(scan("==a== and ==b==").count, 2)
    }

    func test_highlight_emojiBeforeDoesNotShiftRange() {
        // UTF-16: the emoji is two units, so `==` starts at 3, not 2.
        let spans = scan("🎈 ==lit==")
        XCTAssertEqual(spans.first?.range, 3..<10)
    }

    func test_footnoteReference_wellFormed() {
        let spans = scan("claim[^1] more")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .footnoteReference(label: "1"))
        XCTAssertEqual(spans.first?.range, 5..<9)
    }

    func test_footnoteReference_namedLabel() {
        XCTAssertEqual(scan("x[^why-it-matters]").first?.kind,
                       .footnoteReference(label: "why-it-matters"))
    }

    func test_footnoteReference_emptyLabelEmitsNothing() {
        XCTAssertTrue(scan("x[^]").isEmpty)
    }

    func test_footnoteReference_whitespaceInLabelEmitsNothing() {
        XCTAssertTrue(scan("x[^not a label]").isEmpty)
    }

    func test_footnoteReference_embedIsNotAFootnote() {
        // `![[...]]` is an embed. The `!` must disqualify it.
        XCTAssertTrue(scan("![^1]").isEmpty)
    }

    func test_footnoteReference_ordinaryLinkIsNotAFootnote() {
        XCTAssertTrue(scan("[text](url)").isEmpty)
    }

    func test_footnoteDefinition_atLineStart() {
        let spans = scan("[^1]: the note")
        XCTAssertEqual(spans.first?.kind, .footnoteDefinition(label: "1"))
        XCTAssertEqual(spans.first?.range, 0..<5)     // `[^1]:`
    }

    func test_footnoteDefinition_midLineIsAReferenceNotADefinition() {
        XCTAssertEqual(scan("see [^1]: here").first?.kind,
                       .footnoteReference(label: "1"))
    }

    func test_footnoteReference_astralCharacterSurvivesInLabel() {
        // Mirrors `test_tag_astralCharacterSurvivesInName`: a surrogate pair
        // must not be mangled into "?" — the label is the key `jumpFootnote`
        // matches on, so two different astral labels collapsing to the same
        // string would jump to the wrong footnote.
        XCTAssertEqual(scan("x[^🎈label]").first?.kind,
                       .footnoteReference(label: "🎈label"))
    }

    func test_footnote_insideCodeEmitsNothing() {
        XCTAssertTrue(scan("```\n[^1]: no\n```").isEmpty)
    }

    // MARK: - #tags

    func test_tag_simple() {
        let spans = scan("a #idea b")
        XCTAssertEqual(spans.first?.kind, .tag(name: "idea"))
        XCTAssertEqual(spans.first?.range, 2..<7)
    }

    func test_tag_nested() {
        XCTAssertEqual(scan("#project/ainkrad").first?.kind,
                       .tag(name: "project/ainkrad"))
    }

    func test_tag_withHyphenAndUnderscore() {
        XCTAssertEqual(scan("#well-known_thing").first?.kind,
                       .tag(name: "well-known_thing"))
    }

    func test_tag_headingIsNotATag() {
        // `#` at line start followed by a space is a heading. It belongs to the AST.
        XCTAssertTrue(scan("# Heading").isEmpty)
    }

    func test_tag_atLineStartWithoutSpaceIsATag() {
        XCTAssertEqual(scan("#idea").first?.kind, .tag(name: "idea"))
    }

    func test_tag_allDigitsIsNotATag() {
        // Keeps issue references (`#1234`) out. Obsidian's own rule: a tag needs
        // at least one non-digit.
        XCTAssertTrue(scan("see #1234").isEmpty)
    }

    func test_tag_mixedDigitsAndLettersIsATag() {
        XCTAssertEqual(scan("#v2release").first?.kind, .tag(name: "v2release"))
    }

    func test_tag_bareHashEmitsNothing() {
        XCTAssertTrue(scan("a # b").isEmpty)
    }

    func test_tag_insideCodeFenceEmitsNothing() {
        XCTAssertTrue(scan("```\n#!/bin/sh\n#idea\n```").isEmpty)
    }

    func test_tag_insideWikilinkEmitsNothing() {
        // `[[Note#Heading]]` — the `#` is a fragment separator, not a tag.
        XCTAssertTrue(scan("[[Note#Heading]]").isEmpty)
    }

    func test_tag_insideMarkdownLinkTargetEmitsNothing() {
        XCTAssertTrue(scan("[text](https://x.test/page#anchor)").isEmpty)
    }

    func test_tag_trailingSlashIsTrimmedFromName() {
        let span = scan("#project/")
        XCTAssertEqual(span.first?.kind, .tag(name: "project"))
    }

    func test_tag_trailingPunctuationIsNotPartOfIt() {
        let spans = scan("about #idea.")
        XCTAssertEqual(spans.first?.kind, .tag(name: "idea"))
        XCTAssertEqual(spans.first?.range, 6..<11)   // excludes the full stop
    }

    func test_tag_astralCharacterSurvivesInName() {
        // A surrogate pair must not be mangled into "?" — a tag name reaches the
        // index, the sidebar chip row and the MCP tools, so two different emoji
        // tags collapsing to the same string is a real collision, not a cosmetic
        // one.
        XCTAssertEqual(scan("#🎈idea").first?.kind, .tag(name: "🎈idea"))
    }

    func test_blockID_atEndOfLine() {
        let spans = scan("A paragraph. ^abc123")
        XCTAssertEqual(spans.first?.kind, .blockID(id: "abc123"))
        XCTAssertEqual(spans.first?.range, 13..<20)
    }

    func test_blockID_midLineEmitsNothing() {
        XCTAssertTrue(scan("A ^abc123 paragraph.").isEmpty)
    }

    func test_blockID_withoutPrecedingWhitespaceEmitsNothing() {
        XCTAssertTrue(scan("caret^abc123").isEmpty)
    }

    func test_blockID_allowsHyphen() {
        XCTAssertEqual(scan("text ^my-block").first?.kind, .blockID(id: "my-block"))
    }

    func test_blockID_underscoreIsNotObsidianCharset() {
        // Obsidian allows letters, digits and hyphen only.
        XCTAssertTrue(scan("text ^my_block").isEmpty)
    }

    func test_blockID_insideMathEmitsNothing() {
        // `^` is superscript in math and is masked before this scanner runs.
        // `$x^2$` cannot pin this on its own — `^2` there is preceded by
        // `x`, not whitespace, so the whitespace guard already rejects it
        // with no mask involved. Block math crosses a line boundary, so
        // `^id` here genuinely satisfies "preceded by whitespace" and "at
        // line end" without the mask; only the mask (which claims the
        // caret's own offset via the whole `$$…$$` range) suppresses it.
        // The closing `$$` sits after "more" rather than right after the
        // newline, because `MarkdownMath.closingDelimiter` refuses a closer
        // preceded by whitespace and a bare `\n` counts as whitespace there.
        XCTAssertTrue(scan("$$\na ^id\nmore$$").isEmpty)
    }

    func test_blockID_insideCodeEmitsNothing() {
        XCTAssertTrue(scan("```\ntext ^abc\n```").isEmpty)
    }

    func test_blockID_bareCaretEmitsNothing() {
        XCTAssertTrue(scan("text ^").isEmpty)
    }

    // MARK: - CRLF consistency (Finding 6)

    func test_highlight_doesNotCrossLines_CRLF() {
        // Mirrors `test_highlight_doesNotCrossLines`, but with a CRLF break.
        // Before the fix `scanHighlights` only checked for `0x0A`, so a
        // stray `\r` right before it let the scan run one unit further than
        // it should — harmless here because `0x0A` still stops it one unit
        // later, but the guard itself must recognise `0x0D` too.
        XCTAssertTrue(scan("a ==lit\r\nmore== b").isEmpty)
    }

    func test_tag_headingIsNotATag_afterCRLF() {
        // `isAtLineStart` walking back over a CRLF-terminated previous line
        // must still recognise the `#` as heading-positioned.
        XCTAssertTrue(scan("intro\r\n# Heading").isEmpty)
    }

    func test_tag_atLineStartWithoutSpaceIsATag_afterCRLF() {
        XCTAssertEqual(scan("intro\r\n#idea").last?.kind, .tag(name: "idea"))
    }

    func test_tag_headingIsNotATag_afterLoneCarriageReturn() {
        // A LONE `\r` (old Mac line ending, no `\n`) walked directly by
        // `isAtLineStart` — this is what actually exercises the `0x0D`
        // branch: the CRLF tests above already pass via the existing
        // `0x0A` check, since the character immediately before the `#` is
        // always the `\n` half of the pair.
        XCTAssertTrue(scan("intro\r# Heading").isEmpty)
    }

    func test_tag_atLineStartWithoutSpaceIsATag_afterLoneCarriageReturn() {
        XCTAssertEqual(scan("intro\r#idea").last?.kind, .tag(name: "idea"))
    }

    func test_footnoteReference_carriageReturnInLabelEmitsNothing() {
        // The label guard rejected `0x0A` but not `0x0D` — a lone `\r`
        // (or the first half of a CRLF pair) inside `[^…]` must still
        // invalidate the label.
        XCTAssertTrue(scan("x[^a\rb]").isEmpty)
    }

    func test_footnoteDefinition_atLineStart_afterCRLF() {
        XCTAssertEqual(scan("intro\r\n[^1]: the note").last?.kind,
                       .footnoteDefinition(label: "1"))
    }

    func test_blockID_atEndOfLine_CRLF() {
        // Already consistent before this pass — `scanBlockIDs` checked both
        // `0x0A` and `0x0D` — pinned here alongside the others rather than
        // left as the only scanner without a CRLF test.
        let spans = scan("A paragraph. ^abc123\r\nnext line")
        XCTAssertEqual(spans.first?.kind, .blockID(id: "abc123"))
    }
}
