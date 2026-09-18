import XCTest
@testable import LoreFeature

/// One test per ADJACENT PAIR in `MarkdownExtensions.scan`'s stated order.
///
/// These exist because highlight, strikethrough and math all use repeated
/// ASCII punctuation and all can nest. Without a stated order the winner in
/// each of these cases is whichever scanner happened to run first — which is
/// not a decision, it is an accident that changes when someone reorders a
/// function for tidiness.
final class MarkdownExtensionsPrecedenceTests: XCTestCase {

    private func scan(_ body: String) -> [MarkdownExtensions.Span] {
        MarkdownDocumentModel(body: body).extensionSpans
    }

    func test_code_beatsEverything() {
        XCTAssertTrue(scan("`==h== [^1] #tag ^id`").isEmpty)
    }

    func test_math_beatsHighlight() {
        // The `$…$` claims its range first, so the `==` inside cannot pair.
        XCTAssertTrue(scan("$a ==b== c$").isEmpty)
    }

    func test_math_beatsBlockID() {
        // `$x ^2$` on its own cannot pin this: the block ID's `atLineEnd`
        // check already fails there (`^2` is followed by `$`, not a line
        // terminator), so it would pass even with the math mask removed
        // entirely. Block math CAN cross a line boundary, so `^id` here
        // genuinely satisfies both the "preceded by whitespace" and "at
        // line end" guards on its own — only the math mask (which claims
        // the WHOLE `$$…$$` range, including the `^`'s own offset) stops it.
        // The closing `$$` sits after "more", not right after the newline —
        // `MarkdownMath.closingDelimiter` refuses a closer preceded by
        // whitespace, and a bare `\n` counts as whitespace there.
        XCTAssertTrue(scan("$$\na ^id\nmore$$").isEmpty)
    }

    /// `==#tag==`: `scanHighlights` claims the whole `==…==` range before
    /// `scanTags` ever runs, so the `#` inside is never a candidate. Removing
    /// the highlight scan (or reordering it after tags) turns this red —
    /// genuinely pins the order, unlike the old blockID pair above.
    func test_highlight_beatsTag() {
        XCTAssertEqual(scan("==#tag==").map(\.kind), [.highlight])
    }

    /// `==text ^id==`: same shape, for `scanBlockIDs`. Included per the M6
    /// final review even though — as with the old `test_math_beatsBlockID`
    /// — the block ID's own `atLineEnd` guard already fails here (`^id` is
    /// followed by `==`, not a line terminator), so this one is honest about
    /// NOT being a mask-dependent pin; it documents that a highlighted block
    /// ID still resolves to exactly one span, the highlight.
    func test_highlight_beatsBlockID() {
        XCTAssertEqual(scan("==text ^id==").map(\.kind), [.highlight])
    }

    func test_highlight_beatsFootnote() {
        // `==[^1]==` is a highlight CONTAINING a footnote reference, not two
        // overlapping spans: highlight claims the outer range first, which
        // blocks the footnote scanner's start check (`isClaimed(i)`) from
        // ever firing at the `[` inside it.
        //
        // NOTE: `scanHighlights` only checks `isClaimed` at its opening `=`
        // and at the offset of its closing `==`, not at every offset in
        // between — so asserting merely `kinds.contains(.highlight)` would
        // pass even with the scanners reversed (footnote first would still
        // find the highlight, in ADDITION to the footnote, since the
        // footnote's claim of 2..<6 never covers offset 6 where the
        // highlight's closing check lands). The count/array assertion below
        // is what actually pins the order: reversed, this document yields
        // TWO spans, not one.
        XCTAssertEqual(scan("==[^1]==").map(\.kind), [.highlight])
    }

    func test_footnote_beatsTag() {
        // `[^tag#1]` — the `#` is inside a claimed footnote label range.
        XCTAssertEqual(scan("[^a#b]").count, 1)
    }

    func test_tag_beatsBlockID() {
        // Different characters entirely (`#` vs `^`) at disjoint offsets, so
        // both survive on one line regardless of which scanner runs first.
        // This does NOT actually pin an order — it would pass identically
        // if `scanTags` and `scanBlockIDs` were swapped, since neither's
        // match claims an offset the other needs. Kept as a sanity check
        // that the two coexist on one line, not as a precedence pin.
        let kinds = scan("note #idea ^abc")
        XCTAssertEqual(kinds.count, 2)
        XCTAssertEqual(kinds.map(\.kind), [.tag(name: "idea"), .blockID(id: "abc")])
    }

    func test_unclosedHighlightDoesNotSwallowLaterSyntax() {
        // The regression this whole ordering exists to prevent: a stray `==`
        // must not consume the rest of the document.
        let kinds = scan("== stray\n#idea").map(\.kind)
        XCTAssertEqual(kinds, [.tag(name: "idea")])
    }
}
