import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// GFM pipe tables.
///
/// The parse is pure and asserted directly. The ALIGNMENT is asserted where it
/// actually matters — on screen, by asking the text view where each column
/// starts — because "the kern attribute was written" is a fact about an
/// attribute, and what was asked for is columns that line up.
final class MarkdownTableTests: XCTestCase {

    private func parse(_ body: String) -> MarkdownTable? {
        let ns = body as NSString
        return MarkdownTable.parse(range: 0..<ns.length, in: ns)
    }

    // MARK: - Parsing

    func test_rowsCellsAndWidthsAreRead() throws {
        let body = "| name | qty |\n|---|---|\n| apple | 3 |\n"
        let table = try XCTUnwrap(parse(body))
        XCTAssertEqual(table.rows.count, 2, "header and one body row; the delimiter is not a row")
        XCTAssertNotNil(table.delimiterRow)
        XCTAssertEqual(table.rows.map { $0.cells.count }, [2, 2])
        // Widths are the WIDEST cell per column: "apple" (5) beats "name" (4).
        XCTAssertEqual(table.columnWidths, [5, 3])
    }

    func test_cellContentIsTrimmedOfItsPadding() throws {
        let body = "|  a  |   b |\n|---|---|\n| c | d |\n"
        let table = try XCTUnwrap(parse(body))
        let ns = body as NSString
        let first = try XCTUnwrap(table.rows.first?.cells.first)
        XCTAssertEqual(ns.substring(with: NSRange(location: first.range.lowerBound,
                                                  length: first.range.count)), "a")
        XCTAssertEqual(first.width, 1)
    }

    /// Both spellings are legal GFM and a vault contains both.
    func test_aTableWithoutOuterPipesParses() throws {
        let table = try XCTUnwrap(parse("a | b\n--|--\nc | d\n"))
        XCTAssertEqual(table.rows.map { $0.cells.count }, [2, 2])
        XCTAssertEqual(table.columnWidths, [1, 1])
    }

    /// `\|` is how GFM writes a literal pipe. Splitting on it would shear the
    /// row into the wrong number of columns and misalign every one after it.
    func test_anEscapedPipeIsContentNotASeparator() throws {
        let table = try XCTUnwrap(parse("| a \\| b | c |\n|---|---|\n| d | e |\n"))
        XCTAssertEqual(table.rows.first?.cells.count, 2,
                       "`a \\| b` is ONE cell")
    }

    /// The delimiter is the second line by definition. A body cell holding
    /// `---` is content, and hiding that row would delete a row of the table.
    func test_onlyTheSecondLineCanBeTheDelimiter() throws {
        let table = try XCTUnwrap(parse("| a | b |\n|---|---|\n| --- | x |\n"))
        XCTAssertEqual(table.rows.count, 2,
                       "the `| --- |` body row is a ROW, not a second delimiter")
    }

    func test_alignmentColonsAreStillADelimiter() throws {
        XCTAssertNotNil(try XCTUnwrap(parse("| a | b |\n|:--|--:|\n| c | d |\n")).delimiterRow)
    }

    func test_somethingThatIsNotATableIsRejected() {
        XCTAssertNil(parse("just prose\n"))
        XCTAssertNil(parse("| only one line |\n"))
    }

    // MARK: - Spans

    private func spans(_ body: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: body).styleSpans
    }

    func test_aTableEmitsItsSpans() {
        let found = spans("| a | b |\n|---|---|\n| c | d |\n")
        XCTAssertTrue(found.contains { $0.kind == .table }, "the table itself")
        XCTAssertTrue(found.contains { $0.kind == .tableHeader }, "its header row")
        XCTAssertTrue(found.contains { $0.kind == .marker(of: .tableDelimiter) },
                      "the |---| row, as a marker so it collapses whole")
        XCTAssertEqual(found.filter { $0.kind == .marker(of: .tablePipe) }.count, 2,
                       "one marker per ROW — a row collapses whole, because the "
                       + "drawing replaces all of it, not just its notation")
    }

    /// The delimiter row must be HIDDEN when the caret is elsewhere — it is
    /// pure notation, and a rendered table does not show it.
    func test_theDelimiterRowCollapsesWhenTheCaretIsElsewhere() {
        let body = "intro\n\n| a | b |\n|---|---|\n| c | d |\n"
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: spans(body), selection: NSRange(location: 0, length: 0),
            text: body, isFocused: true)
        let delimiter = (body as NSString).range(of: "|---|---|")
        XCTAssertTrue(hidden.contains { $0.lowerBound <= delimiter.location
                                        && $0.upperBound >= NSMaxRange(delimiter) },
                      "the delimiter row must be collapsed")
    }

    // MARK: - Column alignment markers

    func test_delimiterColonsSetTheColumnAlignment() throws {
        let table = try XCTUnwrap(parse("| a | b | c | d |\n|:--|--:|:-:|---|\n| e | f | g | h |\n"))
        XCTAssertEqual(table.columnAlignments, [.left, .right, .center, .left])
    }

    func test_aTableWithNoColonsIsAllLeft() throws {
        let table = try XCTUnwrap(parse("| a | b |\n|---|---|\n| c | d |\n"))
        XCTAssertEqual(table.columnAlignments, [.left, .left])
    }

    /// Alignment decides where a cell's text sits in its column's slack.
    ///
    /// Asserted on the arithmetic rather than on screen: the kern-era version
    /// moved real glyphs, so a character rect could report it, but a DRAWN grid
    /// puts the text where no rect can see. The parsing half above and this
    /// half together cover what the on-screen test used to.
    @MainActor
    func test_alignmentPlacesTextInItsColumnsSlack() {
        XCTAssertEqual(MarkdownTableStyling.cellOffset(for: .left, slack: 40), 0)
        XCTAssertEqual(MarkdownTableStyling.cellOffset(for: .right, slack: 40), 40)
        XCTAssertEqual(MarkdownTableStyling.cellOffset(for: .center, slack: 40), 20)
    }

    /// A cell that exactly fills its column has no slack, so every alignment
    /// puts it in the same place.
    @MainActor
    func test_aFullCellIsPlacedTheSameWhateverItsAlignment() {
        for alignment: MarkdownTable.Alignment in [.left, .right, .center] {
            XCTAssertEqual(MarkdownTableStyling.cellOffset(for: alignment, slack: 0), 0)
        }
    }

    // MARK: - Harness

    /// Windows are retained and the view laid out before anything is measured:
    /// a windowless `NSTextView` returns a zero rect for every range, which is
    /// how an alignment test in the previous milestone passed with its feature
    /// switched off.
    private var windows: [NSWindow] = []

    @MainActor
    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    // MARK: - The drawn grid

    /// The box the EDITOR built, not one re-measured here.
    ///
    /// Re-running `layout` from a test would read the storage after the
    /// collapse and measure every cell at 0.01 pt — proving nothing about what
    /// production does, which is to capture the styled text first.
    @MainActor
    private func box(_ body: String) throws -> TableBox {
        let (coordinator, tv) = editor(body)
        return try withExtendedLifetime(coordinator) { () -> TableBox in
            // Deliberately NO `revealForSelectionChange` here. That runs the
            // per-block path, which builds regions of its own and would repair
            // anything the FULL RENDER got wrong — hiding exactly the defects
            // this file exists to catch. A mutation to the full-render ordering
            // survived because an earlier version of this helper called it.
            for region in tv.blockBackgrounds {
                if case .table(let box, _) = region.kind { return box }
            }
            throw XCTSkip("no table region was produced")
        }
    }

    /// THE test for this milestone. The real table from Ahmed's vault could not
    /// fit — 987 pt of content against a 760 pt measure — and the kern-padded
    /// version came apart, because a row is one paragraph and wraps at the
    /// container's edge with no memory of its columns.
    ///
    /// Drawn, it fits by WRAPPING INSIDE the column instead.
    @MainActor
    func test_aTableTooWideToFitWrapsInsteadOfOverflowing() throws {
        let body = """
        intro

        | Wave | Tasks | Why first |
        |---|---|---|
        | 1 — unblock | B1 (timezone), E1 (office code) | B1 corrupts every \
        date-dependent feature incl. D5; E1 blocks E2/E3/E4 |
        | 5 — copy | F3, A2, A3, E5 | Low risk; E5 blocked on the analysis file |

        """
        let laid = try box(body)
        XCTAssertLessThanOrEqual(laid.totalWidth, 800,
                                 "the grid must fit the measure it was given")
        XCTAssertEqual(laid.columnWidths.count, 3)

        // The long third column must have wrapped, making its row taller than
        // a single line — which is the whole point.
        let single = MarkdownStyleRenderer.baseFont.ascender
            - MarkdownStyleRenderer.baseFont.descender
        let tallest = try XCTUnwrap(laid.rows.map(\.height).max())
        XCTAssertGreaterThan(tallest, single * 1.8,
                             "a cell too long for its column takes more lines INSIDE "
                             + "the column, rather than pushing the row off the edge")
    }

    /// IMAGE 12, 2026-08-17: the grid painted ON TOP of still-visible source.
    ///
    /// Only the pipes were collapsed, so every cell's text remained real text
    /// and the drawing doubled it. A row must collapse WHOLE, because the
    /// drawing replaces all of it.
    @MainActor
    func test_aDrawnRowsSourceIsFullyCollapsed() throws {
        let body = "intro\n\n| Wave | Tasks |\n|---|---|\n| one | two |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) { () -> Void in
            let storage = try XCTUnwrap(tv.textStorage)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.revealForSelectionChange()

            // Every character of a drawn row — cell text included, not just the
            // pipes — must be collapsed, or it shows through the grid.
            let row = (body as NSString).range(of: "| Wave | Tasks |")
            for offset in stride(from: row.location, to: NSMaxRange(row), by: 1) {
                let font = storage.attribute(.font, at: offset,
                                             effectiveRange: nil) as? NSFont
                XCTAssertLessThan(font?.pointSize ?? 99, 1.0,
                                  "offset \(offset) is still visible under the grid")
            }
        }
    }

    /// And the converse: the caret's own row comes back at full size, so it can
    /// be edited. The rest of the table stays drawn.
    @MainActor
    func test_theCaretsRowReturnsToFullSizeSource() throws {
        let body = "intro\n\n| Wave | Tasks |\n|---|---|\n| one | two |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) { () -> Void in
            let storage = try XCTUnwrap(tv.textStorage)
            let header = (body as NSString).range(of: "| Wave | Tasks |")
            tv.setSelectedRange(NSRange(location: header.location + 3, length: 0))
            coordinator.revealForSelectionChange()

            let font = storage.attribute(.font, at: header.location + 3,
                                         effectiveRange: nil) as? NSFont
            XCTAssertGreaterThan(font?.pointSize ?? 0, 1.0,
                                 "the caret's row must show its source at full size")

            let body_ = (body as NSString).range(of: "| one | two |")
            let other = storage.attribute(.font, at: body_.location + 3,
                                          effectiveRange: nil) as? NSFont
            XCTAssertLessThan(other?.pointSize ?? 99, 1.0,
                              "while every other row stays drawn")
        }
    }

    /// The cells' styled text is captured BEFORE the collapse. Capturing after
    /// would store 0.01 pt runs and draw a microscopic grid.
    @MainActor
    func test_capturedCellTextIsFullSize() throws {
        let laid = try box("intro\n\n| Wave | Tasks |\n|---|---|\n| one | two |\n")
        let cell = try XCTUnwrap(laid.rows.first?.cells.first)
        XCTAssertGreaterThan(cell.text.length, 0)
        let font = cell.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 1.0,
                             "captured cell text must be full size, not collapsed")
    }

    /// IMAGE 13, 2026-08-17: `**1 — unblock**` drawn WITH its asterisks.
    ///
    /// The cells are captured before the collapse so they are not captured at
    /// 0.01 pt — but the same collapse is what hides inline `**`, so capturing
    /// before ALL of it kept the markers. The collapse now runs in two passes
    /// around the capture: inline syntax first, cells, then the rows.
    @MainActor
    func test_aBoldCellIsDrawnWithoutItsMarkers() throws {
        let laid = try box("intro\n\n| **bold** | b |\n|---|---|\n| c | d |\n")
        let cell = try XCTUnwrap(laid.rows.first?.cells.first)

        // The `**` are still IN the captured text — the storage keeps every
        // character — but collapsed to nothing, exactly as on screen.
        let markers = (cell.text.string as NSString).range(of: "**")
        XCTAssertNotEqual(markers.location, NSNotFound, "the text is captured whole")
        let markerFont = cell.text.attribute(.font, at: markers.location,
                                             effectiveRange: nil) as? NSFont
        XCTAssertLessThan(markerFont?.pointSize ?? 99, 1.0,
                          "a captured `**` must already be collapsed, or it is drawn "
                          + "into the grid as literal asterisks")

        // And the word itself is full size and bold.
        let word = (cell.text.string as NSString).range(of: "bold")
        let wordFont = try XCTUnwrap(cell.text.attribute(.font, at: word.location,
                                                          effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(wordFont.pointSize, 1.0)
        XCTAssertTrue(wordFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// No column may be squeezed below the floor, or every word wraps onto its
    /// own line and the result is less readable than the source it replaced.
    @MainActor
    func test_columnsAreNeverSqueezedBelowTheFloor() {
        let natural: [CGFloat] = [600, 40, 900]
        let fitted = MarkdownTableLayout.fit(natural, into: 400)
        XCTAssertEqual(fitted.reduce(0, +), 400, accuracy: 1.0)
        for width in fitted {
            XCTAssertGreaterThanOrEqual(width, MarkdownTableLayout.minimumColumnWidth - 0.01)
        }
    }

    /// Proportional, not equal: a column of one-word cells and a column of
    /// sentences must not end up the same width just because both were too
    /// wide together.
    @MainActor
    func test_squeezingIsProportional() {
        let fitted = MarkdownTableLayout.fit([200, 800], into: 500)
        XCTAssertLessThan(fitted[0], fitted[1],
                          "the narrower column stays the narrower one")
    }

    @MainActor
    func test_aTableThatFitsKeepsItsNaturalWidths() {
        let natural: [CGFloat] = [100, 120]
        XCTAssertEqual(MarkdownTableLayout.fit(natural, into: 760), natural)
    }

    /// Each row reserves its own drawn height on its own source line, so the
    /// grid lands exactly where the room was made.
    @MainActor
    func test_eachRowReservesItsOwnHeight() throws {
        let body = "intro\n\n| a | b |\n|---|---|\n| c | d |\n"
        let (coordinator, tv) = editor(body)
        try withExtendedLifetime(coordinator) { () -> Void in
            let storage = try XCTUnwrap(tv.textStorage)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.revealForSelectionChange()
            let header = (body as NSString).range(of: "| a | b |")
            let style = try XCTUnwrap(
                storage.attribute(.paragraphStyle, at: header.location,
                                  effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(style.minimumLineHeight, 0,
                                 "a drawn row must reserve its height, or the grid is "
                                 + "painted over the text beneath it")
        }
    }

    /// The editor must actually hand the drawing layer a grid.
    @MainActor
    func test_aTableReachesTheDrawingLayer() throws {
        let body = "intro\n\n| a | b |\n|---|---|\n| c | d |\n"
        let (coordinator, tv) = editor(body)
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.revealForSelectionChange()
            XCTAssertTrue(tv.blockBackgrounds.contains { region in
                if case .table = region.kind { return true }
                return false
            }, "a table must reach the layer that paints it")
        }
    }

    /// Cell content is taken from the STORAGE, so inline styling inside a cell
    /// survives into the drawn grid rather than being re-derived and drifting.
    /// The captured cell keeps the inline styling the editor had applied, so
    /// the drawn grid and the source agree about what a cell looks like.
    @MainActor
    func test_aCellsInlineStylingSurvivesIntoTheBox() throws {
        let laid = try box("intro\n\n| **wwww** | b |\n|---|---|\n| c | d |\n")
        let cell = try XCTUnwrap(laid.rows.first?.cells.first)
        var sawBold = false
        cell.text.enumerateAttribute(.font, in: NSRange(location: 0, length: cell.text.length)) {
            value, _, _ in
            if let font = value as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) { sawBold = true }
        }
        XCTAssertTrue(sawBold, "a bold cell must reach the grid still bold")
    }
}
