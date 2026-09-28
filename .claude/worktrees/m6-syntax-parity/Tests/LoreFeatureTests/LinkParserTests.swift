import XCTest
@testable import LoreFeature

final class LinkParserTests: XCTestCase {
    private func targets(_ body: String) -> [String] {
        LinkParser.links(in: body).map(\.rawTarget)
    }

    func test_parsesPlainWikilink() {
        XCTAssertEqual(targets("see [[Design]] here"), ["Design"])
    }

    func test_parsesDisplayTextAndKeepsTargetClean() {
        let links = LinkParser.links(in: "see [[Design|the design]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Design"])
        XCTAssertEqual(links.first?.displayText, "the design")
    }

    func test_keepsHeadingAndBlockFragmentsInTheTarget() {
        XCTAssertEqual(targets("[[Design#Overview]] and [[Design#^abc123]]"),
                       ["Design#Overview", "Design#^abc123"])
    }

    func test_flagsEmbeds() {
        let links = LinkParser.links(in: "![[Diagram]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Diagram"])
        XCTAssertEqual(links.first?.isEmbed, true)
    }

    func test_parsesMarkdownLinksToLocalFiles() {
        XCTAssertEqual(targets("[text](notes/Design.md)"), ["notes/Design.md"])
    }

    func test_ignoresExternalMarkdownLinks() {
        XCTAssertEqual(targets("[site](https://example.com) [m](mailto:a@b.c)"), [])
    }

    func test_ignoresLinksInsideFencedCodeBlocks() {
        let body = """
        real [[One]]

        ```
        not a link [[Two]]
        ```

        real [[Three]]
        """
        XCTAssertEqual(targets(body), ["One", "Three"])
    }

    func test_ignoresLinksInsideTildeFencesAndInlineCode() {
        let body = """
        ~~~
        [[Fenced]]
        ~~~
        `[[Inline]]` but [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_ignoresUnclosedLink() {
        XCTAssertEqual(targets("[[Unclosed and more text"), [])
    }

    func test_handlesUnicodeAndSpaces() {
        XCTAssertEqual(targets("[[Café Notes/Über Design]]"), ["Café Notes/Über Design"])
    }

    func test_emptyTargetIsIgnored() {
        XCTAssertEqual(targets("[[]] [[   ]]"), [])
    }

    // MARK: - Fence length / character matching (Finding 1)

    func test_longerFenceIsNotClosedByAShorterBareLineOfTheSameCharacter() {
        let body = """
        real [[Before]]

        ````
        ```
        not a link [[Inside]]
        ```
        ````

        real [[After]]
        """
        XCTAssertEqual(targets(body), ["Before", "After"])
    }

    func test_backtickFenceIsNotClosedByATildeFence() {
        let body = """
        ```
        [[Fenced]]
        ~~~
        still fenced [[AlsoFenced]]
        ```
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_tildeFenceIsNotClosedByABacktickFence() {
        let body = """
        ~~~
        [[Fenced]]
        ```
        still fenced [[AlsoFenced]]
        ~~~
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_fenceWithInfoStringOpensCorrectly() {
        let body = """
        ```swift
        let x = "[[NotALink]]"
        ```
        real [[Real]]
        """
        XCTAssertEqual(targets(body), ["Real"])
    }

    func test_unclosedFenceSwallowsRestOfDocument() {
        let body = """
        real [[Before]]

        ```
        [[Inside]]
        still no closer, [[AlsoInside]]
        """
        XCTAssertEqual(targets(body), ["Before"])
    }

    // MARK: - Dangling backtick (Finding 2)

    func test_danglingBacktickDoesNotSwallowRestOfLine() {
        XCTAssertEqual(targets("a ` stray backtick then [[Design]]"), ["Design"])
    }

    func test_balancedInlineCodeStillSkipsButLaterLinkIsFound() {
        XCTAssertEqual(targets("`code` then [[Design]]"), ["Design"])
    }

    func test_linkFullyInsideInlineCodeIsStillIgnored() {
        XCTAssertEqual(targets("`[[NotALink]]`"), [])
    }

    // MARK: - Spans

    /// The ranges the rewriter replaces by. They must cover the TARGET only —
    /// not the brackets, not the `|display` half — or a rewrite reflows text
    /// nobody asked it to touch.
    func test_spansCoverTheTargetTextExactly() {
        let body = "x [[Design|why]] y"
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design")
    }

    /// Offsets are absolute in the scanned string, across lines — the rewriter
    /// indexes the whole document with them.
    func test_spanOffsetsAreAbsoluteAcrossLines() {
        let body = "first line\nthen [[Design]] here"
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design")
        XCTAssertEqual(span.targetRange.lowerBound, 18)
    }

    /// Whitespace inside the brackets is trimmed off the target, so the span
    /// must not include it.
    func test_spanExcludesPaddingInsideTheBrackets() {
        let body = "[[  Design  ]]"
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design")
    }

    func test_spansAreNotProducedForCodeRegions() {
        XCTAssertTrue(LinkParser.spans(in: "`[[NotALink]]`").isEmpty)
        XCTAssertTrue(LinkParser.spans(in: "```\n[[NotALink]]\n```").isEmpty)
    }

    /// A CRLF document must scan as lines, not as one giant line — otherwise
    /// no fence is ever detected in a Windows-authored vault, and the offsets
    /// must still index the ORIGINAL string.
    func test_crlfDocumentsAreScannedLineByLine() {
        let body = "real [[Design]]\r\n\r\n```\r\n[[NotALink]]\r\n```\r\n"
        XCTAssertEqual(LinkParser.links(in: body).map(\.rawTarget), ["Design"])
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design")
    }

    func test_markdownLinkSpanCoversTheTargetNotTheText() {
        let body = "see [the doc](Design%20Doc.md)!"
        let span = LinkParser.spans(in: body).first!
        XCTAssertEqual(String(Array(body)[span.targetRange]), "Design%20Doc.md")
        XCTAssertEqual(span.link.syntax, .markdown)
    }

    func test_astAndScannerAgreeOnEveryFixture() {
        // The AST must classify code regions exactly as the hand-written scanner
        // did. Any disagreement is a behaviour change in the link graph, which is
        // what this task exists NOT to do.
        let fixtures = [
            "see [[One]]\n\n```\n[[Two]]\n```\n\n[[Three]]\n",
            "`[[Inline]]` but [[Real]]\n",
            "~~~\n[[Fenced]]\n~~~\n[[After]]\n",
            "````\n```\n[[StillCode]]\n```\n````\n[[Outside]]\n",
            "text [[A|display]] and [[B#Heading]] and ![[C]]\n",
            "[md](Design%20Doc.md) and [ext](https://example.com)\n",
            "---\nid: a\ntitle: T\n---\n[[InBody]]\n",
        ]
        for fixture in fixtures {
            let targets = LinkParser.links(in: fixture).map(\.rawTarget)
            XCTAssertFalse(targets.contains("Two"), fixture)
            XCTAssertFalse(targets.contains("Inline"), fixture)
            XCTAssertFalse(targets.contains("Fenced"), fixture)
            XCTAssertFalse(targets.contains("StillCode"), fixture)
        }
    }

    /// Inline HTML is NOT a code region in the AST, and the hand-written
    /// scanner never treated it as one either. Pinned so that the swap to the
    /// AST cannot quietly start suppressing these links.
    func test_inlineHTMLDoesNotSuppressLinks() {
        XCTAssertEqual(targets("a <span>[[B]]</span> b"), ["B"])
    }

    /// The REAL pin for "HTML never suppresses a link".
    ///
    /// The behavioural test above does not enforce it: review showed that
    /// adding `visitInlineHTML` to the collector leaves it green, because
    /// `InlineHTML` nodes cover only `<span>` / `</span>` and the `[[B]]` is a
    /// sibling `Text` node outside both ranges. What actually guarantees it is
    /// the KIND SET the parser suppresses on. Widening that set is the only way
    /// HTML — inline or block — could ever start eating links, and it fails
    /// here.
    func test_onlyFencedAndInlineCodeSuppressLinks() {
        XCTAssertEqual(MarkdownDocumentModel.linkSuppressingKinds,
                       [.fencedCodeBlock, .inlineCode])
    }

    /// A `[[` opened INSIDE inline code can find its `]]` in a real link later
    /// on the line. Suppressing the bogus candidate must therefore resume the
    /// scan one character on, not jump past the borrowed `]]` — doing the
    /// latter swallows `[[Real]]` entirely.
    func test_suppressedCandidateDoesNotSwallowALaterRealLink() {
        XCTAssertEqual(targets("`[[x` [[Real]]"), ["Real"])
    }

    // MARK: - Kinds that must NOT suppress
    //
    // The AST reports indented code, HTML blocks and HTML comments as raw-text
    // regions, and an earlier draft of this parser suppressed on all of them.
    // That deleted links the old hand-written scanner extracted — including
    // links in ordinary PROSE, because a CommonMark type-6 HTML block runs to
    // the next blank line. Suppression is restricted to fenced and inline code.

    /// An indented (4-space) code block must NOT suppress: the old scanner
    /// tracked only ``` / ~~~ fences, and this keeps the vault's graph stable.
    func test_indentedCodeBlocksDoNotSuppressLinks() {
        XCTAssertEqual(targets("para\n\n    [[Indented]]\n\nafter [[Real]]\n"),
                       ["Indented", "Real"])
    }

    /// Tab-indented code is the same case by another spelling.
    func test_tabIndentedCodeDoesNotSuppressLinks() {
        XCTAssertEqual(targets("para\n\n\t[[Tabbed]]\n\nafter [[Real]]\n"),
                       ["Tabbed", "Real"])
    }

    func test_htmlBlocksDoNotSuppressLinks() {
        XCTAssertEqual(targets("<div>\n[[InHTMLBlock]]\n</div>\n\nafter [[Real]]\n"),
                       ["InHTMLBlock", "Real"])
    }

    /// The worst case the kind restriction exists to prevent: a type-6 HTML
    /// block swallows every line up to the next BLANK one, so `[[R]]` sits in
    /// plain prose and must survive.
    func test_proseAfterAnHTMLBlockKeepsItsLinks() {
        XCTAssertEqual(targets("text\n<div>\n[[A]]\n</div>\ntext [[R]]"), ["A", "R"])
    }

    func test_htmlCommentsDoNotSuppressLinks() {
        XCTAssertEqual(targets("<!--\n[[Commented]]\n-->\n\nafter [[Real]]\n"),
                       ["Commented", "Real"])
    }

    /// Markdown links, not just wikilinks, must follow the same rule.
    func test_markdownLinksInIndentedAndHTMLBlocksAreKept() {
        XCTAssertEqual(targets("para\n\n    [t](Indented.md)\n"), ["Indented.md"])
        XCTAssertEqual(targets("<div>\n[t](InHTML.md)\n</div>\n"), ["InHTML.md"])
    }

    /// An indented code block whose CONTENT begins with a fence marker is still
    /// INDENTED code, and must not suppress.
    ///
    /// `CodeBlock.range` starts at the content, past the 4-space indent, so the
    /// block looks fence-shaped from its start offset. The block is recognised
    /// by the bare closing run in its own content — impossible inside a real
    /// fence, since it would have terminated it.
    func test_indentedBlockWhoseContentIsAFenceDoesNotSuppress() {
        XCTAssertEqual(targets("para\n\n    ```\n    [[X]]\n    ```\n\nafter [[R]]"),
                       ["X", "R"])
        XCTAssertEqual(targets("para\n\n    ~~~\n    [[X]]\n    ~~~\n\nafter [[R]]"),
                       ["X", "R"])
    }

    /// Same, but the indented block opens with an INFO-STRING fence line, which
    /// is not itself a closer — the bare closer only appears two lines down.
    func test_indentedBlockOpeningWithAnInfoStringFenceDoesNotSuppress() {
        XCTAssertEqual(targets("para\n\n    ```swift\n    [[X]]\n    ```\n\nafter [[R]]"),
                       ["X", "R"])
    }

    func test_markdownLinkInAnIndentedBlockOfBackticksIsKept() {
        XCTAssertEqual(targets("para\n\n    ```\n    [t](X.md)\n    ```\n\n[t2](R.md)"),
                       ["X.md", "R.md"])
    }

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
        XCTAssertEqual(targets("para\n\n    ```swift\n    [[X]]\n    ```\n\nafter [[R]]"),
                       ["X", "R"])
    }

    func test_fenceInsideABlockquoteSuppresses() {
        XCTAssertEqual(targets("> ```\n> [[X]]\n> ```\n\n[[R]]"), ["R"])
    }

    func test_fenceInsideABlockquoteInsideAListSuppresses() {
        XCTAssertEqual(targets("- a\n\n  > ```\n  > [[X]]\n  > ```\n\n[[R]]"), ["R"])
    }

    func test_markdownLinksInMissedFencesAreAlsoSuppressed() {
        XCTAssertEqual(targets("- a\n  - b\n\n    ```\n    [t](X.md)\n    ```\n\n[t2](R.md)"),
                       ["R.md"])
        XCTAssertEqual(targets("> ```\n> [t](X.md)\n> ```\n\n[t2](R.md)"), ["R.md"])
        XCTAssertEqual(targets("- a\n\n  > ```\n  > [t](X.md)\n  > ```\n\n[t2](R.md)"),
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
        XCTAssertEqual(targets("para\n\n   ```\n   [[Fenced]]\n   ```\n\n[[Real]]\n"),
                       ["Real"])
    }

    /// Fenced code inside a list item is still fenced code.
    func test_fenceInsideAListItemSuppresses() {
        XCTAssertEqual(targets("- item\n\n  ```\n  [[Fenced]]\n  ```\n\n[[Real]]\n"),
                       ["Real"])
    }

    /// Indented code inside a blockquote must NOT suppress — same rule as any
    /// other indented code.
    func test_indentedCodeInsideABlockquoteDoesNotSuppress() {
        XCTAssertEqual(targets("> para\n>\n>     [[Quoted]]\n\nafter [[Real]]\n"),
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
