import XCTest

@testable import LoreFeature

// Fence and inline-code shapes, split from `LinkParserTests.swift` to keep it
// under the 500-line ceiling. `targets` lives there.
extension LinkParserTests {
    // MARK: - Fences the old scanner MISSED (indent > 3 on the raw line)

    /// A fence indented four or more columns by LIST NESTING is a real fence.
    /// The old scanner required `indent <= 3` on the raw line and so scanned
    /// straight through it, putting `[[X]]` into the graph as a phantom link.
    func test_fenceIndentedFourByListNestingSuppresses() {
        XCTAssertEqual(targets("- a\n  - b\n\n    ```\n    [[X]]\n    ```\n\n[[R]]"), ["R"])
        XCTAssertEqual(targets("- a\n  - b\n\n    ~~~\n    [[X]]\n    ~~~\n\n[[R]]"), ["R"])
    }

    /// Deeper list nesting pushes the fence further right again; classification
    /// must not depend on the depth.
    func test_fenceIndentedEightByListNestingSuppresses() {
        XCTAssertEqual(
            targets("- a\n  - b\n    - c\n\n        ```\n        [[X]]\n        ```\n\n[[R]]"),
            ["R"])
        XCTAssertEqual(
            targets("- a\n  - b\n    - c\n\n        ```\n        [t](X.md)\n        ```\n\n[t2](R.md)"),
            ["R.md"])
    }

    // MARK: - Accepted regression: indented blocks with an unclosable fence line
    //
    // These SUPPRESS, and the old scanner did not — a link leaves the graph, so
    // a rename stops rewriting it. Accepted by the owner; see the KNOWN LIMIT
    // comment on `CodeRangeCollector.isFenced(at:code:)`. Pinned so the class
    // stays visible and any future change to it is deliberate.

    func test_knownLimit_indentedBlockWithNoMatchingCloserSuppresses() {
        // 1. unterminated
        XCTAssertEqual(targets("para\n\n    ```swift\n    [[X]]\n"), [])
        // 2. closer indented one space further
        XCTAssertEqual(targets("para\n\n    ```swift\n    [[X]]\n     ```\n"), [])
        // 3. closer shorter than the opener
        XCTAssertEqual(targets("para\n\n    ````js\n    [[X]]\n    ```\n"), [])
        // 4. closer of the wrong character
        XCTAssertEqual(targets("para\n\n    ~~~x\n    [[X]]\n    ```\n"), [])
    }

    /// The boundary of that class: give the same block a MATCHING bare closer
    /// and it is classified correctly again, agreeing with the old scanner.
    func test_knownLimit_doesNotExtendToBlocksWithAMatchingCloser() {
        XCTAssertEqual(
            targets("para\n\n    ```swift\n    [[X]]\n    ```\n\nafter [[R]]"),
            ["X", "R"])
    }

    func test_fenceInsideABlockquoteSuppresses() {
        XCTAssertEqual(targets("> ```\n> [[X]]\n> ```\n\n[[R]]"), ["R"])
    }

    func test_fenceInsideABlockquoteInsideAListSuppresses() {
        XCTAssertEqual(targets("- a\n\n  > ```\n  > [[X]]\n  > ```\n\n[[R]]"), ["R"])
    }

    func test_markdownLinksInMissedFencesAreAlsoSuppressed() {
        XCTAssertEqual(
            targets("- a\n  - b\n\n    ```\n    [t](X.md)\n    ```\n\n[t2](R.md)"),
            ["R.md"])
        XCTAssertEqual(targets("> ```\n> [t](X.md)\n> ```\n\n[t2](R.md)"), ["R.md"])
        XCTAssertEqual(
            targets("- a\n\n  > ```\n  > [t](X.md)\n  > ```\n\n[t2](R.md)"),
            ["R.md"])
    }

    /// A CRLF vault must get the same answer for the list-nested fence.
    func test_crlfListNestedFenceSuppresses() {
        XCTAssertEqual(
            targets("- a\r\n  - b\r\n\r\n    ```\r\n    [[X]]\r\n    ```\r\n\r\n[[R]]"),
            ["R"])
    }

    /// A fence whose content opens with a SHORTER or non-bare run of the same
    /// character is still a fence — the closer test must not fire on those.
    func test_fenceContentWithNonClosingBacktickRunsStillSuppresses() {
        XCTAssertEqual(targets("````\n```text\n[[X]]\n````\n\n[[R]]"), ["R"])
        XCTAssertEqual(targets("```\n```text\n[[X]]\n```\n\n[[R]]"), ["R"])
    }

    /// An indented fence is still a fence (up to 3 spaces), and still suppresses.
    func test_indentedFenceStillSuppresses() {
        XCTAssertEqual(
            targets("para\n\n   ```\n   [[Fenced]]\n   ```\n\n[[Real]]\n"),
            ["Real"])
    }

    /// Fenced code inside a list item is still fenced code.
    func test_fenceInsideAListItemSuppresses() {
        XCTAssertEqual(
            targets("- item\n\n  ```\n  [[Fenced]]\n  ```\n\n[[Real]]\n"),
            ["Real"])
    }

    /// Indented code inside a blockquote must NOT suppress — same rule as any
    /// other indented code.
    func test_indentedCodeInsideABlockquoteDoesNotSuppress() {
        XCTAssertEqual(
            targets("> para\n>\n>     [[Quoted]]\n\nafter [[Real]]\n"),
            ["Quoted", "Real"])
    }

    // MARK: - Inline-code shapes the old scanner got wrong

    /// ESCAPED backticks are literal text, so `[[X]]` between them is a REAL
    /// link. The old scanner counted any backtick pair as inline code and
    /// dropped it. This is the one direction that ADDS links to the graph; it
    /// adds only links that genuinely render as links.
    func test_escapedBacktickIsNotInlineCode() {
        XCTAssertEqual(targets(#"\`[[X]]\`"#), ["X"])
    }

    /// CommonMark does not require word boundaries around a code span, so the
    /// backticks in `a`b` and `c`d` DO pair and `[[X]]` is inside code. Old and
    /// new agree here — measured, not assumed.
    func test_backticksInSeparateWordsDoFormACodeSpan() {
        XCTAssertEqual(targets("a`b [[X]] c`d"), [])
    }

    /// A run of one backtick cannot be closed by a run of two.
    func test_unmatchedBacktickRunsAreNotACodeSpan() {
        XCTAssertEqual(targets("`[[A]]``"), ["A"])
    }

    /// A double-backtick span IS code, and the old scanner also treated it so.
    func test_doubleBacktickSpanSuppresses() {
        XCTAssertEqual(targets("``[[NotALink]]`` and [[Real]]"), ["Real"])
    }

    /// An inline code span may wrap across a line break. The old scanner reset
    /// its backtick state per line and extracted the link.
    func test_multiLineInlineCodeSuppresses() {
        XCTAssertEqual(targets("a `code\n[[NotALink]]` b\n\n[[Real]]\n"), ["Real"])
    }

    /// THE PHANTOM LINK. `LinkParser` is fed a BODY — frontmatter has already
    /// been separated off by `Frontmatter.parse` (or by `LinkRewriter`'s own
    /// `bodyOffset` slice). When that body legitimately OPENS with an `---`
    /// thematic break and another bare `---` appears later, a second
    /// frontmatter scan misreads the whole span between them as frontmatter and
    /// excludes it from the parse — so the fenced block living there produces
    /// NO code region, and the `[[Phantom]]` documented inside it is emitted as
    /// a real link.
    ///
    /// That is the worst outcome in this codebase: the phantom enters the
    /// graph, shows up in another document's backlinks, and is REWRITTEN by a
    /// rename — silently editing a file the user never opened, with no undo.
    /// The assertion is the property itself, not the size of the index: the
    /// phantom must not be a link, and the real link beside it must survive.
    func test_fenceInsideDashOpeningBodyStillSuppresses_noPhantomLink() {
        let body = """
            ---
            ```text
            [[Phantom]]
            ```
            ---

            # Real

            See [[Actual]].
            """
        XCTAssertEqual(targets(body), ["Actual"])
    }

    /// The Character↔UTF-16 boundary: a span must still cover its target
    /// exactly when the document contains astral-plane characters.
    func test_spansSurviveAstralCharactersBeforeTheLink() {
        let body = "🎉🎉 [[Design]] x"
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design")
    }
}
