import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// A table measured at one width and then shown at another.
///
/// This is the shape of the defect Ahmed photographed: the editor is created,
/// styles once at whatever width the view happens to have, and only THEN gets
/// its real width from SwiftUI's layout. `tableRegions` held the box measured
/// at the first width — squeezed to `minimumColumnWidth` on a narrow one — and
/// nothing rebuilt it, so the table stayed a 2 x 48 pt grid with its text
/// wrapped into a 32 pt column.
final class TableResizeTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private let body = """
        intro paragraph

        | | |
        |---|---|
        | **Web** | http://localhost:5180 |
        | **API** | http://localhost:8001 |

        after
        """

    @MainActor
    private func editor(startingWidth: CGFloat)
        -> (MarkdownEditor.Coordinator, LinkTextView)
    {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: startingWidth, height: 800))
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
        coordinator.applyContainerGeometry(forWidth: startingWidth)
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    @MainActor
    private func box(in tv: LinkTextView) -> TableBox? {
        for region in tv.blockBackgrounds {
            if case .table(let box, _) = region.kind { return box }
        }
        return nil
    }

    /// The whole defect in one assertion: a table styled at a narrow width and
    /// then shown wide must end up EXACTLY as it would have been had the view
    /// been that wide all along.
    ///
    /// Equality with the born-wide box, not merely "bigger than before": a
    /// table stops growing at its natural width, so "wider than the squeezed
    /// one" would also pass for a box that only partly caught up.
    @MainActor
    func test_aTableMeasuredNarrowIsRemeasuredWhenTheViewWidens() throws {
        let (_, wideFromBirth) = editor(startingWidth: 900)
        let expected = try XCTUnwrap(box(in: wideFromBirth))

        let (coordinator, tv) = editor(startingWidth: 220)
        let narrow = try XCTUnwrap(box(in: tv))
        // Sanity: 220 pt really does squeeze the columns, so the case below is
        // testing something.
        XCTAssertLessThan(narrow.totalWidth, expected.totalWidth)

        tv.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        coordinator.applyContainerGeometry(forWidth: 900)
        tv.layoutSubtreeIfNeeded()

        let widened = try XCTUnwrap(box(in: tv))
        XCTAssertEqual(
            widened.columnWidths, expected.columnWidths,
            "the table must be remeasured against the width it is "
                + "actually drawn at, not the one it was created at")

        // And the cells still carry real, readable text. `prepare` has to run
        // BETWEEN the two collapse passes — it captures each cell's attributed
        // text, which is microscopic once the rows collapse — so a re-render
        // that got that ordering wrong would surface here as 0.01 pt cells.
        let url = try XCTUnwrap(widened.rows.dropFirst().first?.cells.last)
        XCTAssertTrue(url.text.string.contains("localhost"))
        let font = url.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(
            try XCTUnwrap(font).pointSize, 5,
            "cell text captured after the rows collapsed would be 0.01 pt")
    }

    /// The BACKSTOP: a box measured at one width and then drawn at another
    /// corrects itself, whatever put it out of step.
    ///
    /// Correcting `applyContainerGeometry` fixed resizing and left first-open
    /// alone — the view is created at one width and laid out at another, and
    /// the styling pass can land on either side of that. So the box records
    /// the width it was measured against, and a disagreement schedules one
    /// re-render regardless of how it arose. This drives the disagreement
    /// directly rather than through a resize, which is exactly the case the
    /// geometry path cannot see.
    @MainActor
    func test_aBoxMeasuredAtAnotherWidthRemeasuresItself() throws {
        let (coordinator, tv) = editor(startingWidth: 900)
        let expected = try XCTUnwrap(box(in: tv)).columnWidths

        // Move the container WITHOUT telling the coordinator, which is what a
        // mis-ordered first layout amounts to.
        tv.textContainer?.size = NSSize(width: 150, height: CGFloat.greatestFiniteMagnitude)
        coordinator.renderedSnapshot = nil
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        let squeezed = try XCTUnwrap(box(in: tv))
        XCTAssertLessThan(squeezed.totalWidth, 200, "precondition: it really is squeezed")
        XCTAssertEqual(
            squeezed.measuredWidth, 150, accuracy: 0.5,
            "the box records the width it was measured against")

        // Put the real width back and let the render loop notice on its own —
        // no resize call, no forced snapshot.
        tv.textContainer?.size = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        coordinator.refreshBlockBackgrounds(in: try XCTUnwrap(tv.textStorage), window: nil)
        let recovered = expectation(description: "table remeasured")
        DispatchQueue.main.async { DispatchQueue.main.async { recovered.fulfill() } }
        wait(for: [recovered], timeout: 5)
        tv.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            try XCTUnwrap(box(in: tv)).columnWidths, expected,
            "a box drawn at a width it was not measured for must correct itself")
    }

    /// Narrowing again must also take effect, or a table would only ever grow.
    @MainActor
    func test_aTableIsRemeasuredWhenTheViewNarrowsToo() throws {
        let (coordinator, tv) = editor(startingWidth: 900)
        let wide = try XCTUnwrap(box(in: tv)).totalWidth

        tv.frame = NSRect(x: 0, y: 0, width: 220, height: 800)
        coordinator.applyContainerGeometry(forWidth: 220)
        tv.layoutSubtreeIfNeeded()

        XCTAssertLessThan(try XCTUnwrap(box(in: tv)).totalWidth, wide)
    }
}
