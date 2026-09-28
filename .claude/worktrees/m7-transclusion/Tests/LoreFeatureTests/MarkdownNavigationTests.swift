import AppKit
import Foundation
import XCTest
@testable import LoreFeature

/// The M6 final review, Finding 2: `handlePlainClick`, `jumpFootnote` and
/// `selectTag` had no coverage at all before this pass, which is exactly why
/// Finding 1 (both dead inside any enclosing span) survived 1370 green tests.
///
/// These test `MarkdownNavigation` — the pure functions the click routing
/// was extracted into — rather than driving a real `NSTextView`. Spans are
/// built by hand rather than parsed, so each test pins the exact geometry
/// Finding 1 describes: a CONTAINING span (`.listItem`/`.blockQuote`) that
/// sits earlier in the array than the extension span it wraps, matching how
/// `MarkdownDocumentModel.styleSpans` really orders
/// `astStyleSpans + wikilinkSpans + mathSpans + extensionSpans`.
final class MarkdownNavigationTests: XCTestCase {

    // MARK: - Footnote jump: plain

    func test_footnoteReference_jumpsToDefinition() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 5..<9, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 16..<21, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 6), 16)
    }

    func test_footnoteDefinition_jumpsToFirstMatchingReference() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 5..<9, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 16..<21, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 17), 5)
    }

    // MARK: - Footnote jump: nested inside a containing span (Finding 1)

    func test_footnoteReference_nestedInsideListItemStillJumps() {
        // The list item's span comes FIRST in the array and contains offset
        // 8 too — before the fix, `first(where: { $0.range.contains(index)
        // })` returned this span and `jumpFootnote` fell to its `default`
        // arm, doing nothing.
        let spans: [StyleSpan] = [
            StyleSpan(range: 0..<20, kind: .listItem),
            StyleSpan(range: 7..<11, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 30..<35, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 8), 30)
    }

    func test_footnoteReference_nestedInsideBlockquoteStillJumps() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 0..<20, kind: .blockQuote),
            StyleSpan(range: 7..<11, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 30..<35, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 8), 30)
    }

    func test_footnoteDefinition_nestedInsideListItemStillJumpsBack() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 25..<45, kind: .listItem),
            StyleSpan(range: 7..<11, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 30..<35, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 31), 7)
    }

    func test_footnoteDefinition_nestedInsideBlockquoteStillJumpsBack() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 25..<45, kind: .blockQuote),
            StyleSpan(range: 7..<11, kind: .footnoteReference(label: "1")),
            StyleSpan(range: 30..<35, kind: .footnoteDefinition(label: "1")),
        ]
        XCTAssertEqual(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 31), 7)
    }

    // MARK: - Footnote jump: refusals

    func test_unmatchedFootnoteLabel_doesNothing() {
        // An orphan reference with no definition anywhere: emit nothing
        // rather than jump somewhere wrong.
        let spans: [StyleSpan] = [
            StyleSpan(range: 5..<9, kind: .footnoteReference(label: "orphan")),
        ]
        XCTAssertNil(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 6))
    }

    func test_blockID_click_doesNothing() {
        // `.blockID` is an anchor, not a control — see
        // `MarkdownEditor.Coordinator.handlePlainClick`'s comment. Neither
        // navigation function may treat it as theirs.
        let spans: [StyleSpan] = [StyleSpan(range: 5..<10, kind: .blockID(id: "abc"))]
        XCTAssertNil(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 6))
        XCTAssertNil(MarkdownNavigation.tagSpan(in: spans, at: 6))
    }

    func test_clickOutsideAnySpan_doesNothing() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 5..<9, kind: .footnoteReference(label: "1")),
        ]
        XCTAssertNil(MarkdownNavigation.footnoteJumpTarget(in: spans, at: 100))
    }

    // MARK: - Tag click: plain

    func test_tag_yieldsName() {
        let spans: [StyleSpan] = [StyleSpan(range: 2..<7, kind: .tag(name: "idea"))]
        XCTAssertEqual(MarkdownNavigation.tagSpan(in: spans, at: 3)?.kind, .tag(name: "idea"))
    }

    // MARK: - Tag click: nested inside a containing span (Finding 1)

    func test_tag_nestedInsideListItemStillMatches() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 0..<20, kind: .listItem),
            StyleSpan(range: 7..<12, kind: .tag(name: "idea")),
        ]
        XCTAssertEqual(MarkdownNavigation.tagSpan(in: spans, at: 8)?.kind, .tag(name: "idea"))
    }

    func test_tag_nestedInsideBlockquoteStillMatches() {
        let spans: [StyleSpan] = [
            StyleSpan(range: 0..<20, kind: .blockQuote),
            StyleSpan(range: 7..<12, kind: .tag(name: "idea")),
        ]
        XCTAssertEqual(MarkdownNavigation.tagSpan(in: spans, at: 8)?.kind, .tag(name: "idea"))
    }

    // MARK: - Live tag name re-validation (Finding 12)

    func test_liveTagName_matchesCurrentText() {
        let text = "#idea" as NSString
        XCTAssertEqual(MarkdownNavigation.liveTagName(forSpan: 0..<5, in: text), "idea")
    }

    func test_liveTagName_staleSpanNoLongerAHashReturnsNil() {
        // The text changed under the cached span (e.g. the user typed over
        // the `#`) — the offset no longer describes a tag at all.
        let text = "Xidea" as NSString
        XCTAssertNil(MarkdownNavigation.liveTagName(forSpan: 0..<5, in: text))
    }

    func test_liveTagName_reflectsLiveEditNotTheCachedName() {
        // The cache may still say "idea" (from the last parse); the live
        // text has since grown an extra `z`. The live text must win — see
        // `toggleTask`'s "candidate, never an authority" rule.
        let text = "#ideaz" as NSString
        XCTAssertEqual(MarkdownNavigation.liveTagName(forSpan: 0..<6, in: text), "ideaz")
    }

    func test_liveTagName_allDigitsIsRejected() {
        let text = "#1234" as NSString
        XCTAssertNil(MarkdownNavigation.liveTagName(forSpan: 0..<5, in: text))
    }

    func test_liveTagName_trimsTrailingSlash() {
        let text = "#project/" as NSString
        XCTAssertEqual(MarkdownNavigation.liveTagName(forSpan: 0..<9, in: text), "project")
    }
}

// MARK: - Coordinator-level integration (real AST spans, real click routing)

@MainActor
extension MarkdownNavigationTests {

    /// A live editor over `body`, styled once — same shape as
    /// `MarkdownRevealTests`' private `editor(_:caret:width:)` helper.
    private func editor(_ body: String) -> (LinkTextView, MarkdownEditor.Coordinator) {
        let tokens = TestTokens.make()
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.string = body
        let coordinator = MarkdownEditor.Coordinator(text: .constant(body), tokens: tokens)
        coordinator.textView = tv
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyStyles()
        return (tv, coordinator)
    }

    /// FINDING 1, end to end: a `#tag` inside a bullet list — the exact case
    /// the review called out — must still fire `onTagClick` when clicked, and
    /// `handlePlainClick` must NOT report the click as handled (Finding 7:
    /// caret placement must proceed).
    func test_tagClick_insideRealListItem_firesCallback() throws {
        let body = "- an item with #idea in it"
        let (_, coordinator) = editor(body)
        var clicked: String?
        coordinator.onTagClick = { clicked = $0 }

        let ns = body as NSString
        let tagOffset = ns.range(of: "#idea").location + 1   // inside "idea"
        let handled = coordinator.handlePlainClick(atUTF16: tagOffset)

        XCTAssertEqual(clicked, "idea")
        XCTAssertFalse(handled, "a tag click must not swallow caret placement")
    }

    /// FINDING 1, end to end: `[^1]` inside a blockquote must still jump.
    func test_footnoteReferenceClick_insideRealBlockquote_jumps() throws {
        let body = "> a claim[^1] here\n\n[^1]: the definition"
        let (tv, coordinator) = editor(body)

        let ns = body as NSString
        // +2, not +1: `[^1]`'s STYLE span covers only the label content
        // ("1", between the `^` and the `]`) — the `[^` and `]` are separate
        // `.marker` spans, excluded from the footnote-kind filter. Clicking
        // the bracket itself is not covered by `jumpFootnote` today; that is
        // unchanged, frozen behaviour, not something this pass alters.
        let refOffset = ns.range(of: "[^1]").location + 2
        let handled = coordinator.handlePlainClick(atUTF16: refOffset)

        XCTAssertTrue(handled, "a footnote reference click is swallowed on purpose")
        let defLabelOffset = ns.range(of: "[^1]: the definition").location + 2
        XCTAssertEqual(tv.selectedRange().location, defLabelOffset)
    }

    /// The mirror of the two tests above, inside a bullet list: a footnote
    /// reference click jumps to its definition even when the reference sits
    /// in list-item content.
    func test_footnoteReferenceClick_insideRealListItem_jumps() throws {
        let body = "- a claim[^1] here\n\n[^1]: the definition"
        let (tv, coordinator) = editor(body)

        let ns = body as NSString
        // +2, not +1: `[^1]`'s STYLE span covers only the label content
        // ("1", between the `^` and the `]`) — the `[^` and `]` are separate
        // `.marker` spans, excluded from the footnote-kind filter. Clicking
        // the bracket itself is not covered by `jumpFootnote` today; that is
        // unchanged, frozen behaviour, not something this pass alters.
        let refOffset = ns.range(of: "[^1]").location + 2
        let handled = coordinator.handlePlainClick(atUTF16: refOffset)

        XCTAssertTrue(handled)
        let defLabelOffset = ns.range(of: "[^1]: the definition").location + 2
        XCTAssertEqual(tv.selectedRange().location, defLabelOffset)
    }

    /// A tag click nested inside a blockquote — the mirror of the list-item
    /// case above.
    func test_tagClick_insideRealBlockquote_firesCallback() throws {
        let body = "> quoted text with #idea inside"
        let (_, coordinator) = editor(body)
        var clicked: String?
        coordinator.onTagClick = { clicked = $0 }

        let ns = body as NSString
        let tagOffset = ns.range(of: "#idea").location + 1
        let handled = coordinator.handlePlainClick(atUTF16: tagOffset)

        XCTAssertEqual(clicked, "idea")
        XCTAssertFalse(handled)
    }

    // MARK: - Tag completion masking (Finding 11)

    /// `#idea` typed inside a fenced code block must never open the tag
    /// completion panel: `scanTags` never styles it as a tag there (the code
    /// mask claims it first), so offering completions for it would dangle a
    /// panel over a span the editor itself treats as plain code text.
    func test_tagCompletion_doesNotTriggerInsideFencedCode() throws {
        let body = "```\n#idea\n```"
        let (tv, coordinator) = editor(body)
        let ns = body as NSString
        let caret = ns.range(of: "#idea").location + ns.range(of: "#idea").length
        tv.setSelectedRange(NSRange(location: caret, length: 0))

        XCTAssertNil(coordinator.activeTrigger(in: tv),
                     "a `#tag` inside a fence must not trigger tag completion")
    }

    /// The mirror, inside `$…$` math.
    func test_tagCompletion_doesNotTriggerInsideMath() throws {
        let body = "$a #idea b$"
        let (tv, coordinator) = editor(body)
        let ns = body as NSString
        let caret = ns.range(of: "#idea").location + ns.range(of: "#idea").length
        tv.setSelectedRange(NSRange(location: caret, length: 0))

        XCTAssertNil(coordinator.activeTrigger(in: tv),
                     "a `#tag` inside math must not trigger tag completion")
    }

    /// The control: the SAME `#idea` in ordinary prose still triggers.
    func test_tagCompletion_stillTriggersInOrdinaryProse() throws {
        let body = "plain prose #idea more"
        let (tv, coordinator) = editor(body)
        let ns = body as NSString
        let caret = ns.range(of: "#idea").location + ns.range(of: "#idea").length
        tv.setSelectedRange(NSRange(location: caret, length: 0))

        XCTAssertEqual(coordinator.activeTrigger(in: tv)?.kind, .tag)
    }
}
