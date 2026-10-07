import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Clicking into a table must not leave it half-drawn.
final class TableCaretRevealTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    /// The caret in ONE row used to put that row back to `| a | b |` while
    /// the rows above and below stayed painted as a grid — a strip of raw
    /// markdown wedged inside a table, which is what "glitching when I click
    /// on the table" looked like. A table is one object on screen and has to
    /// come apart as one.
    ///
    /// NOTE: this is not Obsidian's behaviour, which keeps the grid painted
    /// and edits cells in place. That needs one paragraph per cell, and a
    /// markdown row is one paragraph — see the M9.8 report. This test pins the
    /// coherent fallback, not parity.
    func test_theWholeTableRevealsWhenTheCaretEntersAnyRow() throws {
        let body = """
            before

            | Choice | Effect during the period |
            |---|---|
            | **Leave as is** | Pickups run normally. |
            | **Override** | The user edits the days. |
            | **Turn off** | No pickups from this schedule. |

            after
            """
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(
            contentRect: tv.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyContainerGeometry(forWidth: 900)
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()

        func rowsDrawnAsGrid() -> (drawn: Int, total: Int) {
            for region in tv.blockBackgrounds {
                guard case .table(let box, _) = region.kind else { continue }
                let drawn = box.rows.filter {
                    MarkdownMathStyling.drawsExpression(
                        at: NSRange(location: $0.sourceRange.location, length: 1), in: tv)
                }.count
                return (drawn, box.rows.count)
            }
            return (0, 0)
        }

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()
        let outside = rowsDrawnAsGrid()
        XCTAssertEqual(
            outside.drawn, outside.total,
            "with the caret elsewhere every row is painted as a grid")
        XCTAssertGreaterThan(outside.total, 1)

        // Click into the middle row.
        let inside = (body as NSString).range(of: "The user edits").location
        tv.setSelectedRange(NSRange(location: inside, length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        let entered = rowsDrawnAsGrid()
        XCTAssertEqual(
            entered.drawn, 0,
            "the WHOLE table goes to source together — a single row of raw "
                + "markdown inside a painted grid is the defect this fixes")

        // And the source really is on screen to be edited.
        let pipe = (body as NSString).range(of: "| **Override**").location
        XCTAssertGreaterThan(
            MarkdownBlockBackgrounds.boundingRect(
                of: NSRange(location: pipe, length: 1), in: tv
            ).width,
            MarkdownBlockBackgrounds.collapsedMarkerWidth,
            "the row the writer clicked into shows its own pipes")

        // Leaving puts the grid back.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()
        let left = rowsDrawnAsGrid()
        XCTAssertEqual(left.drawn, left.total, "and it is repainted on the way out")
    }
}
