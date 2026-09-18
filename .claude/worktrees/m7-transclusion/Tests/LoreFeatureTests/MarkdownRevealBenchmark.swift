import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Counts first, timings second. A timing-only test passes for the wrong
/// reason on a fast machine — which is exactly how M2a's save-path regression
/// (four parses, 1.6s on the main actor) survived an earlier benchmark.
final class MarkdownRevealBenchmark: XCTestCase {

    /// Temp vaults made by `makeTransclusionEditor`, removed in `tearDown`.
    private var transclusionVaults: [URL] = []

    override func tearDownWithError() throws {
        for vault in transclusionVaults { try? FileManager.default.removeItem(at: vault) }
        transclusionVaults = []
    }

    static func largeBody() -> String {
        (0..<3_000).map { "## Heading \($0)\n\nSome **bold** and `code` and [[Link \($0)]].\n" }
            .joined()
    }

    private func largeBody() -> String { Self.largeBody() }

    /// THE new risk of this milestone: selection drives rendering, so a naive
    /// implementation reparses on every arrow key.
    func test_movingTheCaretCostsZeroParses() {
        let body = largeBody()
        let model = MarkdownDocumentModel(body: body)
        let spans = model.styleSpans
        let blocks = MarkdownReveal.blocks(in: body)
        resetParseCounter()

        for location in stride(from: 0, to: 20_000, by: 500) {
            _ = MarkdownReveal.hiddenMarkers(spans: spans,
                                             selection: NSRange(location: location, length: 0),
                                             text: body, isFocused: true)
        }
        XCTAssertEqual(MarkdownParseCounter.count, 0,
                       "caret movement must never trigger a parse")
    }

    /// Block segmentation runs on every TEXT change, so it must be cheap. It
    /// deliberately does NOT run on a selection change — see
    /// `test_arrowingThroughALargeDocumentReAttributesOnlyTwoBlocks`.
    func test_blockSegmentationOfALargeDocumentIsFast() {
        let body = largeBody()
        measure { _ = MarkdownReveal.blocks(in: body) }
    }

    /// M6's worst case for the extension scanner: every one of the five new
    /// syntaxes on every line, ~500 repeats of a paragraph dense in
    /// `==highlight==`, `#tag`, `[^1]`, `~~strike~~` and `^anchor`. This is the
    /// document shape that would expose an `isClaimed`-style quadratic — a
    /// scanner that restarts from the beginning of a claimed span instead of
    /// advancing `i` past it would show up here as a wall-clock outlier
    /// against `test_blockSegmentationOfALargeDocumentIsFast` above, which
    /// covers a same-order document with none of the new syntaxes.
    func test_benchmark_extensionHeavyDocument() {
        let paragraph = "Prose with ==highlight==, a #tag, a [^1] note and ~~struck~~ text. ^anchor\n\n"
        let body = String(repeating: paragraph, count: 500)
        measure {
            _ = MarkdownDocumentModel(body: body).extensionSpans
        }
    }

    /// A real coordinator over a real text view, with two `![[…]]` embeds
    /// resolving to real files on disk. The only way to reach the measurement
    /// path at all — `MarkdownDocumentModel.styleSpans` is pure logic and
    /// never measures anything.
    @MainActor
    private func makeTransclusionEditor(resolving: Bool = true) throws
        -> (MarkdownEditor.Coordinator, NSTextView, URL) {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        transclusionVaults.append(vault)

        let a = vault.appendingPathComponent("target-a.md")
        let b = vault.appendingPathComponent("target-b.md")
        try String(repeating: "Transcluded prose that has to be laid out.\n\n", count: 40)
            .write(to: a, atomically: true, encoding: .utf8)
        try "# B\n\nAn anchored paragraph. ^anchor\n".write(to: b, atomically: true,
                                                            encoding: .utf8)

        let host = """
        # Host

        ![[target-a]]

        Some prose the caret will live in.

        ![[target-b#^anchor]]
        """
        var stored = host
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.resolveEmbedTarget = { raw in
            guard resolving else { return nil }
            let name = LinkResolver.basename(of: raw)
            if name == "target-a" { return a }
            if name == "target-b" { return b }
            return nil
        }
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = host
        coordinator.textView = tv
        return (coordinator, tv, vault)
    }

    /// Moving the caret WITHIN the embed's own line must not leave the
    /// document in a half-rendered state.
    ///
    /// Fix round 2, NEW-1. Embed reveal is a SPAN-level property while
    /// `revealedRange` is line-scoped, so column 0 → column 1 on an embed's
    /// line flips the embed's reveal with `now == was` — the early-return
    /// branch of `revealForSelectionChange`. That branch reaches
    /// `restyleBlock`, which resets the block's paragraph styles, so before
    /// this fix the reserved gap closed and the (now stale) full-column panel
    /// kept painting over the following paragraph until the next keystroke.
    ///
    /// Asserts BOTH directions: entering drops the region, leaving restores
    /// the reservation.
    @MainActor
    func test_caretMovingWithinAnEmbedsLineKeepsTheReservationHonest() throws {
        let (coordinator, tv, _) = try makeTransclusionEditor()
        coordinator.applyStyles()
        coordinator.renderStyles()
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let embed = (tv.string as NSString).range(of: "![[target-a]]")

            // Column 0: the caret is at the embed's first character, which is
            // NOT strictly inside it, so the embed stays collapsed and drawn.
            tv.setSelectedRange(NSRange(location: embed.location, length: 0))
            let collapsedRegions = coordinator.transclusionRegions
            guard let region = collapsedRegions.first(where: { $0.range == embed }),
                  case .transclusion(let box) = region.kind else {
                return XCTFail("expected the embed to be drawn from column 0")
            }
            let reserved = (storage.attribute(.paragraphStyle, at: embed.location,
                                              effectiveRange: nil) as? NSParagraphStyle)?
                .minimumLineHeight ?? 0
            XCTAssertEqual(reserved, box.height, accuracy: 0.5)

            // Column 1: strictly inside — the embed reveals. The reveal RANGE
            // does not change (same line), so this is the early-return branch.
            let before = coordinator.revealedRange
            tv.setSelectedRange(NSRange(location: embed.location + 1, length: 0))
            XCTAssertEqual(coordinator.revealedRange, before,
                           "this test is only meaningful on the `now == was` branch")
            // The DOCUMENT holds a second embed, which is untouched — so the
            // claim is about THIS embed's region, not about the array.
            XCTAssertFalse(coordinator.transclusionRegions.contains { $0.range == embed },
                           "a revealed embed must not leave a stale panel painting "
                           + "over the paragraph beneath it")
            XCTAssertEqual(coordinator.transclusionRegions.count,
                           collapsedRegions.count - 1,
                           "only the revealed embed loses its region")

            // Back to column 0: collapsed again, and the gap must come back at
            // the measured height rather than staying shut.
            tv.setSelectedRange(NSRange(location: embed.location, length: 0))
            XCTAssertEqual(coordinator.transclusionRegions.count, collapsedRegions.count,
                           "the embed must be drawn again once the caret leaves it")
            let restored = (storage.attribute(.paragraphStyle, at: embed.location,
                                              effectiveRange: nil) as? NSParagraphStyle)?
                .minimumLineHeight ?? 0
            XCTAssertEqual(restored, box.height, accuracy: 0.5,
                           "the reserved gap collapsed and was never re-opened")
        }
    }

    /// A transclusion must not ADD decoration rebuilds to a keystroke.
    ///
    /// Fix round 1, Important 3: `restyleBlock` used to run the whole-document
    /// transclusion reservation AND a whole-document `refreshBlockBackgrounds`
    /// itself, while `renderStylesForEdit` calls it once per changed block and
    /// then refreshes again — N+1 rebuilds per keystroke in any document
    /// holding an embed. Stated as a COMPARISON against the same document with
    /// the embeds unresolved, because the absolute number of rebuilds per
    /// keystroke is the editor's existing behaviour and not this task's claim;
    /// what this task must not do is make it worse.
    ///
    /// Drives the real edit path (`insertText` → `textDidChange`), which the
    /// measurement gate below deliberately does not.
    @MainActor
    func test_transclusionAddsNoDecorationRebuildsToAKeystroke() throws {
        func rebuilds(resolving: Bool) throws -> Int {
            let (coordinator, tv, _) = try makeTransclusionEditor(resolving: resolving)
            return withExtendedLifetime(coordinator) { () -> Int in
                coordinator.applyStyles()
                coordinator.renderStyles()
                let caret = (tv.string as NSString).range(of: "Some prose")
                tv.setSelectedRange(NSRange(location: caret.location + 5, length: 0))
                TransclusionMeasureCounter.reset()
                coordinator.blockBackgroundRefreshes = 0
                for _ in 0..<10 {
                    tv.insertText("x", replacementRange: tv.selectedRange())
                }
                return coordinator.blockBackgroundRefreshes
            }
        }

        XCTAssertEqual(try rebuilds(resolving: true), try rebuilds(resolving: false),
                       "a resolved transclusion must not cost extra decoration rebuilds")
        XCTAssertEqual(TransclusionMeasureCounter.count, 0,
                       "the real edit path re-measured an embed")
    }

    /// The per-block half of the same claim, asserted where the regression
    /// lived: restyling a block that DOES hold a transclusion records the need
    /// for a pass and rebuilds nothing itself, and the pass drains once.
    @MainActor
    func test_restylingABlockDefersTheTransclusionPass() throws {
        let (coordinator, tv, _) = try makeTransclusionEditor()
        coordinator.applyStyles()
        coordinator.renderStyles()
        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let embedBlock = try XCTUnwrap(coordinator.embedIndex.first?.block)

            coordinator.blockBackgroundRefreshes = 0
            coordinator.needsTransclusionPass = false
            coordinator.restyleBlock(embedBlock, revealed: nil, in: storage)
            XCTAssertEqual(coordinator.blockBackgroundRefreshes, 0,
                           "restyling one block must not rebuild the whole decoration")
            XCTAssertTrue(coordinator.needsTransclusionPass,
                          "it must still RECORD that a transclusion pass is owed")

            XCTAssertTrue(coordinator.prepareTransclusionsIfNeeded(in: storage))
            XCTAssertFalse(coordinator.prepareTransclusionsIfNeeded(in: storage),
                           "a drained pass must not run twice")
            XCTAssertEqual(coordinator.blockBackgroundRefreshes, 0,
                           "the drain reserves; the caller decides when to rebuild")
        }
    }

    /// Typing in a host document must not re-measure ANY embed. Full-content
    /// parity means an embed measurement is a whole second document's layout;
    /// doing that per keystroke is how this feature would quietly make the
    /// editor slow.
    ///
    /// Drives the REAL reservation path — `TransclusionStyling.prepare`, via
    /// the coordinator's render — because that is the only thing in the
    /// codebase that measures. The version this replaces drove
    /// `MarkdownDocumentModel.styleSpans`, which is pure logic and never
    /// measures anything at all: it would have passed while asserting
    /// nothing.
    @MainActor
    func test_typingInHostDoesNotRemeasureEmbeds() throws {
        let (coordinator, tv, _) = try makeTransclusionEditor()
        let host = tv.string

        TransclusionMeasureCounter.reset()
        coordinator.applyStyles()
        coordinator.renderStyles()
        let afterFirstPass = TransclusionMeasureCounter.count
        XCTAssertGreaterThan(afterFirstPass, 0,
                             "the first render must actually measure the two embeds — "
                             + "a gate that never reaches the measurement path asserts nothing")

        withExtendedLifetime(coordinator) {
            // The caret lives in the PROSE paragraph, well away from either
            // embed, which is the ordinary case this bound is about.
            let caret = (host as NSString).range(of: "Some prose")
            tv.setSelectedRange(NSRange(location: caret.location + 5, length: 0))
            for _ in 0..<20 {
                tv.insertText("x", replacementRange: tv.selectedRange())
                coordinator.renderStyles()
            }
            XCTAssertEqual(TransclusionMeasureCounter.count, afterFirstPass,
                           "typing re-measured an embed")
        }
    }

    /// Fix round 1, Critical #1: a watcher event must repaint the embed with
    /// NO editor interaction — no keystroke, no focus change, nothing.
    /// Simulates the sink `EditorContext.registerExternalChangeHandler`
    /// exposes by calling `handleExternalChange(to:)` directly, exactly as
    /// `MarkdownEditorView.makeNSView`'s registration callback does, and
    /// asserts BOTH halves of "an edit … re-renders the embed": the content
    /// is re-resolved (a fresh measurement, not the old cached one) AND a
    /// repaint was actually requested (`blockBackgroundRefreshes` moved) —
    /// invalidation alone, with no `blockBackgroundRefreshes` increment,
    /// would be the exact failure this task exists to prevent.
    @MainActor
    func test_watcherEventRepaintsTheEmbedWithNoEditorInteraction() throws {
        let (coordinator, tv, vault) = try makeTransclusionEditor()
        try withExtendedLifetime(coordinator) {
            coordinator.applyStyles()
            coordinator.renderStyles()
            let before = try XCTUnwrap(coordinator.transclusionRegions.first)

            // The target changes ON DISK — no editor of it is open, exactly
            // the "edited in Obsidian" scenario.
            let a = vault.appendingPathComponent("target-a.md")
            try String(repeating: "Freshly edited transcluded prose.\n\n", count: 60)
                .write(to: a, atomically: true, encoding: .utf8)

            coordinator.blockBackgroundRefreshes = 0
            TransclusionMeasureCounter.reset()

            // NO keystroke, no focus change, no `applyStyles()` call — only
            // the sink firing, exactly as the watcher push does.
            coordinator.handleExternalChange(to: a)

            XCTAssertGreaterThan(TransclusionMeasureCounter.count, 0,
                                 "the changed target must be re-resolved and re-measured, "
                                 + "not served from the stale cache entry")
            XCTAssertGreaterThan(coordinator.blockBackgroundRefreshes, 0,
                                 "invalidation without a repaint is exactly the failure "
                                 + "this task exists to prevent")
            let after = try XCTUnwrap(coordinator.transclusionRegions.first)
            XCTAssertNotEqual(before.kind, after.kind,
                              "the drawn embed must reflect the new content, "
                              + "not the box measured before the edit")
        }
    }

    /// Fix round 2, Important #4: `handleExternalChange(to:)` must not force
    /// a full `renderStyles()` for a path this document does not embed.
    /// `TransclusionCache.invalidate(path:)` is a cheap no-op for an
    /// unrelated path, but `renderStyles()` is not — with every open editor
    /// registered against the SAME sink, and `VaultIndexCoordinator
    /// .indexDocument` firing on every save of ANY document, an unfiltered
    /// render here means every open pane pays for a full render on every
    /// save anywhere in the vault, whether or not it embeds the saved file.
    @MainActor
    func test_externalChangeToAnUnembeddedFileTriggersNoRender() throws {
        let (coordinator, _, vault) = try makeTransclusionEditor()
        withExtendedLifetime(coordinator) {
            coordinator.applyStyles()
            coordinator.renderStyles()

            let unrelated = vault.appendingPathComponent("not-embedded.md")
            coordinator.blockBackgroundRefreshes = 0
            TransclusionMeasureCounter.reset()

            coordinator.handleExternalChange(to: unrelated)

            XCTAssertEqual(coordinator.blockBackgroundRefreshes, 0,
                           "a change to a file this document does not embed "
                           + "must not force a decoration rebuild")
            XCTAssertEqual(TransclusionMeasureCounter.count, 0,
                           "a change to a file this document does not embed "
                           + "must not re-measure anything")
        }
    }

    /// Fix round 1, Important #2: `detectExternalTransclusionChanges()` — the
    /// mtime backstop — must cost ZERO filesystem calls on the per-keystroke
    /// path. It is wired to `makeNSView` (on-appear) and
    /// `onBecomeFirstResponder` (on-focus) only, never to `applyStyles()`,
    /// which runs once per keystroke. Same shape as
    /// `test_transclusionAddsNoDecorationRebuildsToAKeystroke`'s
    /// `blockBackgroundRefreshes` gate, for `stat()` calls instead of
    /// decoration rebuilds.
    @MainActor
    func test_typingDoesNotPollExternalTransclusionState() throws {
        let (coordinator, tv, _) = try makeTransclusionEditor()
        withExtendedLifetime(coordinator) {
            coordinator.applyStyles()
            coordinator.renderStyles()
            let caret = (tv.string as NSString).range(of: "Some prose")
            tv.setSelectedRange(NSRange(location: caret.location + 5, length: 0))

            coordinator.externalChangeStatCalls = 0
            for _ in 0..<10 {
                tv.insertText("x", replacementRange: tv.selectedRange())
            }
            XCTAssertEqual(coordinator.externalChangeStatCalls, 0,
                           "a keystroke must never stat an embedded target's file")

            // The counter itself is real, not dead code: the on-focus
            // backstop DOES use it, and stats each of the document's two
            // DISTINCT targets exactly once even though nothing in this
            // fixture repeats a target.
            coordinator.detectExternalTransclusionChanges()
            XCTAssertEqual(coordinator.externalChangeStatCalls, 2,
                           "the on-focus backstop must stat each distinct embedded "
                           + "target exactly once")
        }
    }
}

/// The editor-level half: the bounds this task exists to pin, asserted on the
/// real coordinator rather than on the value types it calls.
@MainActor
final class EditorPerformanceBenchmark: XCTestCase {

    private func makeEditor(_ text: String)
        -> (MarkdownEditor.Coordinator, NSTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        settle()
        return (coordinator, tv)
    }

    /// Lets an off-actor open parse land before a count is taken. Without it
    /// the detached parse increments the counter DURING the assertion window
    /// and the test measures the open path instead of the caret path.
    private func settle(_ seconds: TimeInterval = 0.5) {
        let landed = expectation(description: "off-actor parse landed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { landed.fulfill() }
        wait(for: [landed], timeout: seconds + 2)
    }

    // MARK: - Bound 1: typing costs zero parses

    func test_typingCostsZeroParses() {
        let (coordinator, tv) = makeEditor("# Title\n\nSome **bold** here.\n")
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            for character in "the quick brown fox" {
                tv.insertText(String(character), replacementRange: tv.selectedRange())
            }
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "19 keystrokes must cost zero markdown parses")
        }
    }

    // MARK: - Bound 2: caret movement is O(1) blocks, zero parses

    /// The whole performance contract of the reveal path, on a document big
    /// enough that an O(document) implementation would be obvious.
    ///
    /// Three separate claims, because each has failed independently before:
    /// zero parses, zero block-index rebuilds, and O(1) blocks re-attributed
    /// per boundary crossing — never O(document).
    func test_arrowingThroughALargeDocumentReAttributesOnlyTwoBlocks() {
        let body = (0..<400).map { "## Heading \($0)\n\nSome **bold** and `code`.\n\n" }
            .joined()
        let (coordinator, tv) = makeEditor(body)
        withExtendedLifetime(coordinator) {
            let blockCount = coordinator.revealIndexBuilds
            resetParseCounter()
            coordinator.restyledBlockCount = 0

            var crossings = 0
            var previous = coordinator.revealedRange
            // Stride of ONE, so a move can cross at most one boundary and the
            // "two blocks per crossing" bound is exact rather than amortised.
            for location in stride(from: 0, to: 6_000, by: 1) {
                tv.setSelectedRange(NSRange(location: location, length: 0))
                coordinator.revealForSelectionChange()
                if coordinator.revealedRange != previous { crossings += 1 }
                previous = coordinator.revealedRange
            }

            XCTAssertGreaterThan(crossings, 10, "the sweep must actually cross boundaries")
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "caret movement must never trigger a parse")
            XCTAssertEqual(coordinator.revealIndexBuilds, blockCount,
                           "caret movement must never rescan the document for blocks")
            // Two blocks per crossing: the one leaving reveal and the one
            // entering it. The bound is a CONSTANT multiple of the number of
            // crossings, and independent of the document's length.
            //
            // `crossings` counts REVEAL changes, which since the move to a
            // line-scoped reveal means every line the caret enters rather than
            // every block. There are far more of them, and the per-crossing
            // bound is unchanged and is the thing that matters: the union of
            // the blocks the reveal left and entered is one block when the
            // caret moved within a block, two when it crossed a boundary.
            // Never a function of the document's length.
            XCTAssertLessThanOrEqual(coordinator.restyledBlockCount, crossings * 2,
                                     "a crossing may re-attribute at most the two blocks "
                                     + "whose reveal state flipped")
        }
    }

    // MARK: - Embed reveal: the previously unmeasured path

    /// Whole-branch review measurement gap: nothing in this suite ever built
    /// a document with an `![[…]]` embed in it, so
    /// `EmbedRendering.currentlyRevealedEmbedSpans` — walked on EVERY caret
    /// move, O(embeds in document) by construction — had never actually been
    /// timed. 500 embeds is enough that an O(document) or O(embeds²) mistake
    /// would show up as a wall-clock outlier against
    /// `test_arrowingThroughALargeDocumentReAttributesOnlyTwoBlocks` above,
    /// which covers the same stride over a same-sized embed-free document.
    ///
    /// MEASURED, Debug (unoptimised), 2026-08-08, 500 embeds / 6,000-unit
    /// caret sweep: see the report for the wall-clock number and whether it
    /// reveals a real problem (out of scope to fix in this wave if so).
    func test_arrowingThroughALargeDocumentWithManyEmbeds() {
        let body = (0..<500).map {
            "## Heading \($0)\n\nSome **bold** and ![[Attachment \($0).pdf]] embed.\n\n"
        }.joined()
        let (coordinator, tv) = makeEditor(body)
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            let length = (tv.string as NSString).length

            measure {
                for location in stride(from: 0, to: min(6_000, length), by: 1) {
                    tv.setSelectedRange(NSRange(location: location, length: 0))
                    coordinator.revealForSelectionChange()
                }
            }
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "caret movement through embeds must never trigger a parse")
        }
    }

    // MARK: - Bound 3: a keystroke affordance edits a NARROW range

    /// Carried finding from Task 10. `MarkdownEditorTyping.apply` used to
    /// replace the WHOLE document per Enter/Tab/Cmd-B, which is semantically
    /// right but defeats `MarkdownStyleCache.shift`: a whole-document
    /// replacement shifts every span to nothing and forces a full re-render of
    /// a document that changed by two characters.
    ///
    /// Pinned on the edit the delegate is TOLD about, because that is what the
    /// cache shifts by — see `shouldChangeTextIn`.
    func test_pressingEnterEditsOnlyTheChangedRegion() throws {
        let body = String(repeating: "- item\n", count: 500)
        let (coordinator, tv) = makeEditor(body)
        try withExtendedLifetime(coordinator) {
            let recorder = EditRangeRecorder()
            tv.delegate = recorder
            tv.setSelectedRange(NSRange(location: 6, length: 0))   // end of line 1
            XCTAssertTrue(MarkdownEditorTyping.handle(#selector(NSResponder.insertNewline(_:)),
                                                      in: tv))
            let announced = try XCTUnwrap(recorder.lastRange)
            XCTAssertLessThan(announced.length, 32,
                              "the affordance must replace the changed region, "
                              + "not the whole \((body as NSString).length)-unit document")
            XCTAssertEqual(tv.string,
                           "- item\n- \n" + String(repeating: "- item\n", count: 499),
                           "and the resulting text must be exactly what the transform asked for")
        }
    }

    /// The narrowing must not change what the user sees or what undo restores,
    /// on a document with text AFTER the edit — the case a whole-document
    /// replacement made trivially safe and a narrowed one has to earn.
    func test_narrowingTheEditPreservesTextAndUndo() {
        let host = UndoHost()
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.delegate = host
        tv.string = "- alpha\n- beta\n"
        tv.allowsUndo = true
        withExtendedLifetime(host) {
            tv.setSelectedRange(NSRange(location: 7, length: 0))
            _ = MarkdownEditorTyping.handle(#selector(NSResponder.insertNewline(_:)), in: tv)
            XCTAssertEqual(tv.string, "- alpha\n- \n- beta\n")
            tv.undoManager?.undo()
            XCTAssertEqual(tv.string, "- alpha\n- beta\n",
                           "one undo must restore the document exactly")
        }
    }

    /// A narrowed edit keeps the cache's shift path alive, which is the point:
    /// pressing Enter must not force a parse or invalidate the spans.
    func test_pressingEnterCostsZeroParsesAndKeepsTheCacheCurrent() {
        let (coordinator, tv) = makeEditor(String(repeating: "- item\n", count: 200))
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            tv.setSelectedRange(NSRange(location: 6, length: 0))
            _ = MarkdownEditorTyping.handle(#selector(NSResponder.insertNewline(_:)), in: tv)
            XCTAssertEqual(MarkdownParseCounter.count, 0, "Enter must not parse")
            XCTAssertTrue(coordinator.styleCache.describes(tv.string),
                          "the shifted cache must still describe the text on screen")
        }
    }

    // MARK: - Bound 4: the open path does not parse on the main actor

    /// Carried from M2a: opening a large note parsed synchronously on the main
    /// actor — ~0.4 s Debug on a 230 KB note, felt as the editor freezing on
    /// every document switch.
    func test_openingADocumentDoesNotParseOnTheMainActor() throws {
        let body = MarkdownRevealBenchmark.largeBody()
        let (coordinator, _) = makeEditorWithoutStyling(body)
        withExtendedLifetime(coordinator) {
            resetParseCounter()
            let started = Date()
            coordinator.applyStyles()
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(MarkdownParseCounter.count, 0,
                           "the open path must not parse on the main actor")
            XCTAssertLessThan(elapsed, 0.2,
                              "and it must therefore return promptly — took \(elapsed)s")
        }
    }

    /// …and the styling must still ARRIVE, off-actor, shortly afterwards.
    func test_theOpenPathStillStylesTheDocument() {
        let (coordinator, tv) = makeEditorWithoutStyling("# Heading\n\n**bold**\n")
        withExtendedLifetime(coordinator) {
            coordinator.applyStyles()
            let settled = expectation(description: "off-actor open parse landed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            XCTAssertTrue(coordinator.styleCache.describes(tv.string))
            XCTAssertTrue(coordinator.cachedSpansForTesting.contains { $0.kind == .strong },
                          "the document must end up styled")
        }
    }

    private func makeEditorWithoutStyling(_ text: String)
        -> (MarkdownEditor.Coordinator, NSTextView) {
        let coordinator = MarkdownEditor.Coordinator(text: .constant(text),
                                                     tokens: TestTokens.make())
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        return (coordinator, tv)
    }
}

/// A detached `NSTextView` has no window and so no undo manager of its own.
/// This supplies one the way AppKit would, so the undo assertion above tests
/// the real mechanism rather than a no-op.
@MainActor
private final class UndoHost: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

/// Records the range `shouldChangeTextIn` announced, which is exactly what
/// `MarkdownStyleCache.shift` is driven by.
@MainActor
private final class EditRangeRecorder: NSObject, NSTextViewDelegate {
    var lastRange: NSRange?
    func textView(_ tv: NSTextView, shouldChangeTextIn affected: NSRange,
                  replacementString: String?) -> Bool {
        lastRange = affected
        return true
    }
}

/// Bound 5: a rename parses each document at most once.
@MainActor
final class RenameParseCountBenchmark: XCTestCase {

    /// `LinkRewriter.replacingLinkTargets` scans a document ONCE and replaces
    /// every span from that one scan. Rebuilding the model per link — which is
    /// what a `replacingOccurrences`-per-edit shape would do — would make a
    /// rename O(links) parses of every inbound file.
    func test_rewritingManyLinksInOneDocumentParsesItOnce() {
        let body = "---\nid: a\ntitle: A\n---\n"
            + (0..<200).map { "see [[Design]] and [[Other \($0)]]\n" }.joined()
        let edits = [LinkEdit(file: URL(fileURLWithPath: "/tmp/a.md"),
                              oldTarget: "Design", newTarget: "Architecture")]
        resetParseCounter()
        let out = LinkRewriter.replacingLinkTargets(in: body, edits: edits)
        XCTAssertEqual(MarkdownParseCounter.count, 1,
                       "200 rewritten links must cost one parse, not 200")
        XCTAssertEqual(out.components(separatedBy: "[[Architecture]]").count - 1, 200)
        XCTAssertFalse(out.contains("[[Design]]"))
    }

    /// And across documents: N inbound files cost N parses in the rewrite, not
    /// N × links.
    func test_rewritingManyDocumentsParsesEachOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename-perf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [URL] = []
        for index in 0..<8 {
            let url = root.appendingPathComponent("n\(index).md")
            try ("---\nid: n\(index)\ntitle: N\(index)\n---\n"
                 + String(repeating: "see [[Design]]\n", count: 25))
                .write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        let baseline = Date().addingTimeInterval(60)

        resetParseCounter()
        for file in files {
            let edit = LinkEdit(file: file, oldTarget: "Design",
                                newTarget: "Architecture")
            XCTAssertEqual(try LinkRewriter.applyEdits([edit], to: file, baseline: baseline),
                           .written)
        }
        XCTAssertEqual(MarkdownParseCounter.count, files.count,
                       "each document may be parsed at most once by the rewrite")
    }
}
