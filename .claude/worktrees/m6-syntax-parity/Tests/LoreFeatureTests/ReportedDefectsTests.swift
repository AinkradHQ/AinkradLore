import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Defects Ahmed found by USING the editor, 2026-08-17. Written to FAIL first.
@MainActor
final class ReportedDefectsTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let c = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.isRichText = false
        tv.delegate = c
        let w = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = tv
        w.makeFirstResponder(tv)
        windows.append(w)
        tv.string = body
        c.textView = tv
        c.applyStyles()
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        return (c, tv)
    }

    /// IMAGE 3, 2026-08-17: `Note` and its icon drawn ON TOP of a visible
    /// `> [!note]`.
    ///
    /// With the caret on the header line the source is revealed — which is
    /// correct — but the icon and heading were painted anyway, so the two
    /// overlapped. Asserted through the same measurement the drawing does, so
    /// the test fails for the reason the picture did.
    func test_aRevealedCalloutHeaderDoesNotAlsoDrawItsHeading() throws {
        let body = "intro\n\n> [!note]\n> body text\n"
        let (c, tv) = editor(body)
        try withExtendedLifetime(c) { () -> Void in
            let marker = (body as NSString).range(of: "[!note]")
            tv.layoutSubtreeIfNeeded()

            // Caret AWAY: the marker is collapsed, so the heading stands in.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.revealForSelectionChange()
            XCTAssertTrue(MarkdownBlockBackgrounds.drawsCalloutHeader(marker: marker, in: tv),
                          "with the source hidden, the heading must be drawn")

            // Caret ON the header line: the source is back, so it must not be.
            tv.setSelectedRange(NSRange(location: marker.location + 2, length: 0))
            c.revealForSelectionChange()
            XCTAssertFalse(MarkdownBlockBackgrounds.drawsCalloutHeader(marker: marker, in: tv),
                           "with `> [!note]` visible, drawing an icon and heading over "
                           + "the top of it is the overlap in the 2026-08-17 report")
        }
    }

    /// The reveal state is read at DRAW time, not stored on the region.
    ///
    /// `blockBackgrounds` is rebuilt only on a full render, while reveal changes
    /// on every caret move — so a stored flag is stale exactly when it matters.
    /// This pins that the regions do NOT carry the answer.
    func test_theCalloutRegionDoesNotCacheAStaleRevealState() throws {
        let body = "intro\n\n> [!note]\n> body\n"
        let (c, tv) = editor(body)
        try withExtendedLifetime(c) { () -> Void in
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.revealForSelectionChange()
            let before = tv.blockBackgrounds.first { if case .callout = $0.kind { return true }
                                                     return false }
            tv.setSelectedRange(NSRange(location: 12, length: 0))
            c.revealForSelectionChange()
            let after = tv.blockBackgrounds.first { if case .callout = $0.kind { return true }
                                                    return false }
            XCTAssertEqual(before, after,
                           "a caret move must not need the regions rebuilt; the drawing "
                           + "asks the geometry instead")
        }
    }

    /// THE GLITCH, 2026-08-17: "styling lands late, after I stop typing" —
    /// in a document with a FOOTNOTE in it.
    ///
    /// `hasReferenceDefinitions` refuses the block parse for the WHOLE document
    /// when any line looks like `[label]: target`. A footnote definition
    /// (`[^1]: …`) matches that shape, and one footnote anywhere in a note is
    /// enough to send every keystroke back to shifted spans — which is exactly
    /// the defect the block parse was added to fix.
    func test_aFootnoteDoesNotDisableKeystrokeStyling() throws {
        let body = """
        Some prose here[^1] with more after it.

        plain paragraph here

        [^1]: the footnote text
        """
        let (c, tv) = editor(body)
        try withExtendedLifetime(c) { () -> Void in
            let storage = try XCTUnwrap(tv.textStorage)
            let end = (tv.string as NSString).range(of: "plain paragraph here")
            tv.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
            for ch in " **bold**" {
                tv.insertText(String(ch), replacementRange: tv.selectedRange())
            }
            XCTAssertTrue(c.lastEditTookFastPath,
                          "a footnote elsewhere in the note must not disable the "
                          + "block parse for every paragraph in it")
            let word = (tv.string as NSString).range(of: "bold")
            let font = try XCTUnwrap(storage.attribute(.font, at: word.location,
                                                       effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold),
                          "and the word must bold on the keystroke, not after the debounce")
        }
    }

    /// The same for a REAL reference definition, which is the construct the
    /// guard actually exists for. A paragraph containing no `[` cannot consume
    /// a definition, so it is still safe to parse alone.
    func test_aReferenceDefinitionOnlyBlocksParagraphsThatCouldUseIt() throws {
        let body = """
        [label]: https://example.com

        plain paragraph here

        """
        let (c, tv) = editor(body)
        try withExtendedLifetime(c) { () -> Void in
            let end = (tv.string as NSString).range(of: "plain paragraph here")
            tv.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
            tv.insertText("x", replacementRange: tv.selectedRange())
            XCTAssertTrue(c.lastEditTookFastPath,
                          "a paragraph with no brackets cannot reference a definition")
        }
    }

    /// "The glitching in rendering the markdown is back" — in a document that
    /// contains the new constructs.
    func test_typingStillStylesOnTheKeystrokeInARichDocument() throws {
        let body = """
        # Notes

        > [!warning] Careful
        > body

        | a | b |
        |---|---|
        | 1 | 2 |

        Some math $x^2$ here.

        plain paragraph here

        """
        let (c, tv) = editor(body)
        try withExtendedLifetime(c) {
            let storage = try XCTUnwrap(tv.textStorage)
            let end = (tv.string as NSString).range(of: "plain paragraph here")
            tv.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
            for ch in " **bold**" {
                tv.insertText(String(ch), replacementRange: tv.selectedRange())
            }
            XCTAssertTrue(c.lastEditTookFastPath,
                          "typing in a plain paragraph must still take the block path "
                          + "even when the document contains callouts, tables and math")
            let word = (tv.string as NSString).range(of: "bold")
            let font = try XCTUnwrap(storage.attribute(.font, at: word.location,
                                                       effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold),
                          "and it must be bold on the keystroke, not after the debounce")
        }
    }
}
