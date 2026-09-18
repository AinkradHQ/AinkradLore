import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// What "hidden" actually means on screen, measured rather than argued.
///
/// Written while spiking whether Lore needed to replace its collapse mechanism
/// (a 0.01pt font) with a true zero-width decoration, on the theory that the
/// font trick left a visible sliver and made the caret walk through characters
/// nobody could see. Both halves of that theory turned out to be false, and
/// these are the measurements that settled it — kept as contracts so the
/// properties they establish cannot quietly stop holding.
@MainActor
final class MarkdownHiddenSyntaxTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    private func makeEditor(_ text: String) -> (MarkdownEditor.Coordinator, NSTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        windows.append(window)
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        return (coordinator, tv)
    }

    /// A hidden marker occupies no width a reader could see.
    ///
    /// MEASURED: 0.01 pt hidden against 13.26 pt shown, where one ordinary
    /// character is 8.97 pt. Asserted against a tenth of a point rather than
    /// the measured value, which is a font metric and not a promise.
    ///
    /// `firstRect(forCharacterRange:)` deliberately, NOT `layoutManager`:
    /// reading that property downgrades a TextKit 2 view to TextKit 1, so the
    /// measurement would describe a text system the app never runs.
    func test_aHiddenMarkerOccupiesNoVisibleWidth() throws {
        let body = "a **b** c\n\ntail\n"
        let (coordinator, tv) = makeEditor(body)
        try withExtendedLifetime(coordinator) {
            // Caret on the LAST line, so line one's markers stay hidden.
            tv.setSelectedRange(NSRange(location: (body as NSString).length - 2, length: 0))
            coordinator.revealForSelectionChange()
            let markers = NSRange(location: 2, length: 2)
            let hiddenWidth = tv.firstRect(forCharacterRange: markers, actualRange: nil).width
            XCTAssertLessThan(hiddenWidth, 0.1,
                              "hidden syntax must take no width a reader can see")

            tv.setSelectedRange(NSRange(location: 4, length: 0))
            coordinator.revealForSelectionChange()
            let shownWidth = tv.firstRect(forCharacterRange: markers, actualRange: nil).width
            XCTAssertGreaterThan(shownWidth, 1,
                                 "and must come back at a real size when revealed, "
                                 + "or the collapse is not reversible")
        }
    }

    /// The caret never sits inside syntax it cannot see.
    ///
    /// This is what makes the 0.01pt collapse good enough, and it is a
    /// consequence of reveal being LINE-scoped: whichever line the caret is on
    /// shows that line's syntax, so there is nothing collapsed for it to walk
    /// through. Under the previous block-scoped rule the same held for a
    /// different reason; under a hypothetical marker-scoped one it would not,
    /// which is why it is pinned here rather than assumed.
    func test_theCaretNeverTraversesAHiddenMarker() throws {
        let body = "a **b** c\n\n- x **y** z\n\n> q **r** s\n"
        let (coordinator, tv) = makeEditor(body)
        try withExtendedLifetime(coordinator) {
            let length = (body as NSString).length
            for offset in 0...length {
                tv.setSelectedRange(NSRange(location: offset, length: 0))
                coordinator.revealForSelectionChange()
                let revealed = coordinator.revealedRange
                let line = (body as NSString).lineRange(for: NSRange(location: offset, length: 0))
                for span in coordinator.cachedSpansForTesting {
                    guard case .marker = span.kind else { continue }
                    // Only markers on the caret's OWN line are its business.
                    guard span.range.lowerBound >= line.location,
                          span.range.upperBound <= NSMaxRange(line) else { continue }
                    XCTAssertTrue(MarkdownReveal.isRevealed(span.range, in: revealed),
                                  "a marker on the caret's line must be visible; "
                                  + "caret at \(offset), marker \(span.range)")
                }
            }
        }
    }
}
