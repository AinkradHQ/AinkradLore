import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Measurements, not correctness assertions — the M2a claim that AST styling is
/// affordable is a number here rather than a sentence in a report.
final class MarkdownStylingBenchmark: XCTestCase {

    /// The property that matters: parse count is bounded by the DEBOUNCE, not
    /// by the number of characters typed. Before M2a the styler ran a full
    /// regex sweep per keystroke; an AST parse per keystroke would be worse.
    ///
    /// MEASURED, Debug (unoptimised), 2026-07-30, ~230 KB.
    ///
    ///                       Task 6      Task 6b
    ///   whole parse         3.75 s      0.406 s     9.2× faster
    ///   AST walk            0.35 s      0.366 s     unchanged, as expected
    ///   `wikilinkSpans`     3.20 s      0.057 s     56× faster
    ///
    /// The link scan was 85% of the cost and is now 14%: it asked
    /// `isInsideCode` per candidate link and each answer walked EVERY code
    /// region, so the scan was O(links × regions). `CodeRegionIndex` makes each
    /// answer O(log regions). swift-markdown is now the floor, and it is a floor
    /// the editor no longer waits on — `parseNow` runs off the main actor.
    ///
    /// The split is measured by `test_theASTWalkAlone` and
    /// `test_theWikilinkScanAlone` rather than by hand, so it stays comparable.
    func test_parsingALargeDocumentIsFastEnoughToDebounce() {
        let paragraph = "Some **bold** text with a [[Link]] and `code`.\n\n"
        let body = String(repeating: paragraph, count: 5_000)   // ~230 KB
        XCTAssertGreaterThan((body as NSString).length, 200_000)

        measure {
            _ = MarkdownDocumentModel(fullText: body).styleSpans
        }
    }

    /// The AST-walk half of the split, measured on its own so the two halves
    /// stay comparable across tasks.
    func test_theASTWalkAlone() {
        let body = Self.largeFixture
        measure { _ = MarkdownDocumentModel(fullText: body).astStyleSpans }
    }

    /// The half that was 85% of the cost: the on-demand link scan.
    func test_theWikilinkScanAlone() {
        let body = Self.largeFixture
        let model = MarkdownDocumentModel(fullText: body)
        measure { _ = model.wikilinkSpans }
    }

    static var largeFixture: String {
        String(repeating: "Some **bold** text with a [[Link]] and `code`.\n\n", count: 5_000)
    }

    /// Whole-branch review measurement gap: no benchmark fixture anywhere
    /// contained a single `![[…]]`, so the embed path — including
    /// `EmbedRendering.currentlyRevealedEmbedSpans`'s per-caret-move walk,
    /// which is O(embeds in document) by construction — had never been
    /// measured. 2,000 embeds interleaved with ordinary prose, one per
    /// paragraph, is enough to be meaningful without being pathological.
    static var largeEmbedFixture: String {
        (0..<2_000).map {
            "Some **bold** text with a ![[Attachment \($0).pdf]] embed and `code`.\n\n"
        }.joined()
    }

    /// The parse half of the embed path: `MarkdownDocumentModel.styleSpans`
    /// must stay debounce-affordable on a document whose links are all
    /// embeds rather than plain wikilinks.
    ///
    /// MEASURED, Debug (unoptimised), 2026-08-08, ~150 KB / 2,000 embeds.
    func test_parsingADocumentWithManyEmbedsIsFastEnoughToDebounce() {
        let body = Self.largeEmbedFixture
        measure { _ = MarkdownDocumentModel(fullText: body).styleSpans }
    }

    func test_aDocumentOverTheHardCapProducesNoSpans() {
        let body = String(repeating: "x", count: MarkdownDocumentModel.stylingHardCap + 1)
        XCTAssertTrue(MarkdownDocumentModel(fullText: body).styleSpans.isEmpty)
    }

    func test_aDocumentUnderTheHardCapStillProducesSpans() {
        XCTAssertFalse(MarkdownDocumentModel(fullText: "# Heading\n").styleSpans.isEmpty)
    }

    func test_capsAreOrdered() {
        XCTAssertLessThan(MarkdownDocumentModel.stylingViewportCap,
                          MarkdownDocumentModel.stylingHardCap)
    }
}

/// The mandatory half of Task 6: keystrokes must not parse.
@MainActor
final class MarkdownStylingCacheTests: XCTestCase {

    private func makeEditor(_ text: String)
        -> (MarkdownEditor.Coordinator, NSTextView, Binding<String>) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        return (coordinator, tv, binding)
    }

    /// A keystroke re-renders from the cache and arms the debounce; it does not
    /// parse. This is the regression the whole task exists to prevent.
    func test_keystrokesDoNotParse() {
        let (coordinator, tv, _) = makeEditor("# Title\n\nSome **bold** here.\n")
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            for character in "hello world" {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "11 keystrokes must cost zero markdown parses")
        }
    }

    /// An ancestor redraw — theme change, banner, window resize — re-renders
    /// from the cache too. This path used to cost two parses per redraw.
    func test_reRenderingUnchangedTextDoesNotParse() {
        let (coordinator, _, _) = makeEditor("# Title\n\n- [ ] task\n")
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            for _ in 0..<10 { coordinator.applyStyles() }
            XCTAssertEqual(MarkdownParseCounter.count, 0)
        }
    }

    /// Text arriving from outside the editor (document switch, external write)
    /// is not a keystroke and has no cached spans to shift, so it parses. Once,
    /// and — for a SMALL document — synchronously: the parse is a millisecond
    /// and deferring it would flash the note unstyled on every switch. See
    /// `MarkdownStyleCache.synchronousParseCap`.
    func test_externallyReplacedSmallTextParsesOnceSynchronously() {
        let (coordinator, tv, _) = makeEditor("start")
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            tv.string = "# Replaced\n"
            coordinator.applyStyles()
            coordinator.applyStyles()
            XCTAssertEqual(MarkdownParseCounter.count, 1)
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .heading(1) },
                          "and it must be styled by the time applyStyles returns")
        }
    }

    /// Task 11. Above the cap the same path must NOT parse on the main actor —
    /// that synchronous parse was ~0.4 s Debug on a 230 KB note, felt as the
    /// editor freezing on every document switch. The answer arrives off-actor.
    func test_externallyReplacedLargeTextDoesNotParseOnTheMainActor() {
        let (coordinator, tv, _) = makeEditor("start")
        withExtendedLifetime(coordinator) {
            let large = "# Replaced\n\n**bold**\n\n"
                + String(repeating: "Some prose with a [[Link]] in it.\n\n", count: 2_000)
            XCTAssertGreaterThan(large.utf16.count, MarkdownStyleCache.synchronousParseCap)
            resetParseCounter()
            tv.string = large
            coordinator.applyStyles()
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "a large document must not be parsed on the main actor")
            XCTAssertTrue(coordinator.styleCache.describes(large),
                          "but the cache must claim currency at once, "
                          + "or every redraw re-enters this path")

            let landed = expectation(description: "off-actor parse landed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { landed.fulfill() }
            wait(for: [landed], timeout: 3)
            XCTAssertEqual(MarkdownParseCounter.count, 1, "and exactly one parse, off-actor")
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .strong },
                          "the document must end up styled")
        }
    }

    /// The debounce eventually fires and refreshes the cache with real spans.
    ///
    /// The counts here are BLOCK parses during the burst plus ONE document
    /// parse from the debounce. Typing costs a block parse per character —
    /// that is what styles the markdown on the keystroke rather than on the
    /// pause — and the debounce is still the only thing that re-reads the whole
    /// document, which is the property this test exists to pin.
    func test_theDebouncedParseEventuallyRuns() {
        let (coordinator, tv, _) = makeEditor("plain text\n")
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            for character in "# " { tv.insertText(String(character), replacementRange: tv.selectedRange()) }
            let duringBurst = MarkdownParseCounter.count
            XCTAssertLessThanOrEqual(duringBurst, 2,
                                     "at most one block parse per typed character")

            let parsed = expectation(description: "debounced parse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { parsed.fulfill() }
            wait(for: [parsed], timeout: 2)

            XCTAssertEqual(MarkdownParseCounter.count, duringBurst + 1,
                           "exactly ONE document parse for the whole burst, "
                           + "not one per keystroke")
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .heading(1) })
        }
    }

    /// Above the hard cap the editor must not parse AT ALL. Serving `[]` from a
    /// full parse would make "styling off" the most expensive path there is —
    /// the exact opposite of what the cap exists for.
    func test_aDocumentOverTheHardCapIsNeverParsed() {
        let huge = String(repeating: "x", count: MarkdownDocumentModel.stylingHardCap + 1)
        var cache = MarkdownStyleCache()
        resetParseCounter()
        cache.reparse(huge)
        XCTAssertEqual(MarkdownParseCounter.count, 0,
                       "an over-cap document must cost zero parses")
        XCTAssertTrue(cache.spans.isEmpty)
        XCTAssertTrue(cache.isOverHardCap, "the editor must still say styling is off")
        XCTAssertTrue(cache.describes(huge),
                      "the cache must claim currency, or every redraw re-enters this path")
    }

    /// The guard must not swallow ordinary documents.
    func test_aDocumentUnderTheHardCapIsStillParsed() {
        var cache = MarkdownStyleCache()
        resetParseCounter()
        cache.reparse("# Heading\n\n**bold**\n")
        XCTAssertEqual(MarkdownParseCounter.count, 1)
        XCTAssertFalse(cache.isOverHardCap)
        XCTAssertTrue(cache.spans.contains { $0.kind == .strong })
    }

    /// Task 6b: the debounced parse runs OFF the main actor, so its result can
    /// arrive after the text has moved on. It must then be dropped, not applied
    /// — spans index exactly one string, and applying them to another styles
    /// the wrong characters, which is the defect class M2a exists to remove.
    ///
    /// The text is replaced wholesale immediately after arming the debounce, so
    /// whichever order the two land in, the cache must end up describing what is
    /// actually on screen.
    func test_aParseWhoseTextChangedBeforeItLandedIsNotApplied() {
        let (coordinator, tv, _) = makeEditor("plain text\n")
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("# ", replacementRange: tv.selectedRange())
            // The document was switched out from under the pending parse.
            tv.string = "# Something Else Entirely\n\n**b**\n"
            coordinator.applyStyles()

            let settled = expectation(description: "debounce settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
            wait(for: [settled], timeout: 2)

            XCTAssertTrue(coordinator.styleCache.describes(tv.string),
                          "the cache must describe the text on screen, not the snapshot")
            let limit = (tv.string as NSString).length
            for span in coordinator.cachedSpansForTesting {
                XCTAssertLessThanOrEqual(span.range.upperBound, limit)
            }
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .strong },
                          "and it must be the spans of THAT text")
        }
    }

    /// The debounced parse no longer blocks the main actor. Proven by the one
    /// observable consequence: `parseNow` returns before the spans exist.
    func test_theDebouncedParseDoesNotBlockTheMainActor() {
        let (coordinator, tv, _) = makeEditor("plain text\n")
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("# ", replacementRange: tv.selectedRange())

            let armed = expectation(description: "timer fired")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { armed.fulfill() }
            wait(for: [armed], timeout: 2)
            // The timer has fired and `parseNow` has returned; the answer
            // arrives on a later main-actor turn.
            let settled = expectation(description: "result applied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .heading(1) })
        }
    }

    /// `adopt` binds spans to the string they were derived from as one unit —
    /// the invariant the off-actor hop leans on.
    func test_adoptBindsSpansToTheStringTheyDescribe() {
        var cache = MarkdownStyleCache()
        let text = "# Heading\n\n**bold**\n"
        cache.adopt(MarkdownStyleCache.derive(text), for: text)
        XCTAssertTrue(cache.describes(text))
        XCTAssertFalse(cache.isStale)
        XCTAssertTrue(cache.spans.contains { $0.kind == .strong })
    }

    /// `derive` is the pure half, so it must answer identically to `reparse`.
    func test_deriveAndReparseAgree() {
        let text = "# H\n\n`code` [[Link]] **b**\n\n```\n[[NotALink]]\n```\n"
        var cache = MarkdownStyleCache()
        cache.reparse(text)
        XCTAssertEqual(cache.spans, MarkdownStyleCache.derive(text).spans)
    }

    // MARK: - Span shifting

    func test_spansAfterTheEditShiftByTheDelta() {
        var cache = MarkdownStyleCache()
        cache.reparse("# A\n\n**b**\n")
        let before = cache.spans.first { $0.kind == .strong }!.range
        // An insertion in the blank line, entirely before the strong span.
        cache.shift(editedRange: NSRange(location: 4, length: 0), delta: 3,
                    newText: "# A\nxxx\n**b**\n")
        let after = cache.spans.first { $0.kind == .strong }!.range
        XCTAssertEqual(after.lowerBound, before.lowerBound + 3)
        XCTAssertEqual(after.upperBound, before.upperBound + 3)
    }

    func test_spansBeforeTheEditAreUntouched() {
        var cache = MarkdownStyleCache()
        cache.reparse("**b** tail\n")
        let strongBefore = cache.spans.first { $0.kind == .strong }?.range
        cache.shift(editedRange: NSRange(location: 10, length: 0), delta: 1,
                    newText: "**b** tail!\n")
        XCTAssertEqual(cache.spans.first { $0.kind == .strong }?.range, strongBefore)
    }

    /// Typing INSIDE a span grows it, so bold text does not visibly stop being
    /// bold for the length of the debounce.
    func test_anEditInsideASpanGrowsIt() {
        var cache = MarkdownStyleCache()
        cache.reparse("**bd**\n")
        let before = cache.spans.first { $0.kind == .strong }!.range
        cache.shift(editedRange: NSRange(location: 3, length: 0), delta: 1,
                    newText: "**bod**\n")
        let after = cache.spans.first { $0.kind == .strong }!.range
        XCTAssertEqual(after.lowerBound, before.lowerBound)
        XCTAssertEqual(after.upperBound, before.upperBound + 1)
    }

    /// A deletion must never invert a range — an inverted `Range<Int>` traps.
    func test_aDeletionSpanningASpanDoesNotInvertIt() {
        var cache = MarkdownStyleCache()
        cache.reparse("**bold**\n")
        cache.shift(editedRange: NSRange(location: 0, length: 8), delta: -8, newText: "\n")
        for span in cache.spans {
            XCTAssertLessThanOrEqual(span.range.lowerBound, span.range.upperBound)
            XCTAssertLessThanOrEqual(span.range.upperBound, 1)
        }
    }
}
