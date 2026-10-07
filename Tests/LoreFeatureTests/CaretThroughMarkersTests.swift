import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Does the caret ever sit inside a marker the reader cannot see?
///
/// The M9 source review claimed it does — that arrow-keying across a rendered
/// `**bold**` costs four keypresses during which nothing visibly moves,
/// because the `**` are collapsed to 0.01 pt. It proposed a delegate hook to
/// skip them, as Obsidian's CodeMirror does.
///
/// That claim was reasoned from the collapse code without running the editor,
/// and this file exists to check it against the real thing before anything is
/// built on top of it. `MarkdownReveal` reveals the caret's LINE, so the
/// question is whether reveal always wins the race against the caret.
final class CaretThroughMarkersTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
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
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    /// The rendered width of one character, as the reader sees it.
    @MainActor
    private func width(ofCharacterAt offset: Int, in tv: LinkTextView) -> CGFloat {
        let rect = MarkdownBlockBackgrounds.boundingRect(
            of: NSRange(location: offset, length: 1), in: tv)
        return rect.isNull ? 0 : rect.width
    }

    /// Walk the caret across `**bold**` one position at a time, exactly as the
    /// right-arrow key does, and measure every character it passes through.
    ///
    /// If the review was right, the four marker characters are collapsed while
    /// the caret is inside them and each measures under
    /// `collapsedMarkerWidth`.
    @MainActor
    func test_theCaretNeverStandsInsideACollapsedMarker() {
        let body = "**bold** and more text on this line\n"
        let (coordinator, tv) = editor(body)

        for offset in 0...8 {
            tv.setSelectedRange(NSRange(location: offset, length: 0))
            coordinator.revealForSelectionChange()
            tv.layoutSubtreeIfNeeded()

            // Every character of the span, measured with the caret HERE.
            for probe in 0..<8 {
                XCTAssertGreaterThan(
                    width(ofCharacterAt: probe, in: tv),
                    MarkdownBlockBackgrounds.collapsedMarkerWidth,
                    "caret at \(offset): character \(probe) is collapsed while the "
                        + "caret is on its line, so arrow-keying past it would move "
                        + "through something the reader cannot see")
            }
        }
    }

    /// The other half of the same question: with the caret on a DIFFERENT
    /// line, the markers must be collapsed — otherwise the first test is
    /// passing because nothing collapses at all, which would prove nothing.
    @MainActor
    func test_markersOnAnotherLineAreStillCollapsed() {
        let body = "**bold** here\nsecond line\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(NSRange(location: 16, length: 0))  // second line
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            width(ofCharacterAt: 0, in: tv),
            MarkdownBlockBackgrounds.collapsedMarkerWidth,
            "a marker on an unvisited line must collapse")
    }
}

/// The hover underline: links are coloured at rest and underlined only under
/// the pointer, which is what Obsidian does and what makes an underline mean
/// "this one" rather than "these are all links".
final class LinkHoverUnderlineTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func editor(_ body: String) -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
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
        coordinator.applyStyles()
        tv.layoutSubtreeIfNeeded()
        return (coordinator, tv)
    }

    @MainActor
    private func temporaryUnderline(at offset: Int, in tv: LinkTextView) -> Bool {
        guard let layoutManager = tv.layoutManager else { return false }
        return layoutManager.temporaryAttribute(
            .underlineStyle, atCharacterIndex: offset,
            effectiveRange: nil) != nil
    }

    /// At rest, no link carries an underline — in the STORAGE, which is where
    /// the persistent one used to live.
    @MainActor
    func test_linksAreNotUnderlinedAtRest() {
        let body = "see [text](http://e.com) and [[Target]] here\n"
        let (_, tv) = editor(body)
        let markdownLink = (body as NSString).range(of: "text").location
        let wikilink = (body as NSString).range(of: "Target").location

        XCTAssertNil(
            tv.textStorage?.attribute(
                .underlineStyle, at: markdownLink,
                effectiveRange: nil),
            "the persistent underline is gone from markdown links")
        XCTAssertNil(
            tv.textStorage?.attribute(
                .underlineStyle, at: wikilink,
                effectiveRange: nil))
    }

    /// Under the pointer, it appears — and as a TEMPORARY attribute, so the
    /// next restyle cannot erase it and it can never reach the document.
    @MainActor
    func test_hoveringUnderlinesTheLinkTemporarily() {
        let body = "see [text](http://e.com) and more\n"
        let (coordinator, tv) = editor(body)
        let inside = (body as NSString).range(of: "text").location

        coordinator.underlineLink(at: inside)
        XCTAssertTrue(
            temporaryUnderline(at: inside, in: tv),
            "the hovered link underlines")
        XCTAssertNil(
            tv.textStorage?.attribute(
                .underlineStyle, at: inside,
                effectiveRange: nil),
            "and does so WITHOUT touching the storage")
    }

    /// Moving off the link takes it away again.
    @MainActor
    func test_leavingTheLinkRemovesTheUnderline() {
        let body = "see [text](http://e.com) and more\n"
        let (coordinator, tv) = editor(body)
        let inside = (body as NSString).range(of: "text").location
        let outside = (body as NSString).range(of: "more").location

        coordinator.underlineLink(at: inside)
        coordinator.underlineLink(at: outside)
        XCTAssertFalse(
            temporaryUnderline(at: inside, in: tv),
            "the underline follows the pointer rather than accumulating")
    }

    /// A wikilink underlines too. It did not carry the persistent underline,
    /// so this is the half of the change that ADDS an affordance rather than
    /// moving one.
    @MainActor
    func test_aWikilinkUnderlinesOnHoverAsWell() {
        let body = "see [[Target]] here\n"
        let (coordinator, tv) = editor(body)
        let inside = (body as NSString).range(of: "Target").location
        coordinator.underlineLink(at: inside)
        XCTAssertTrue(temporaryUnderline(at: inside, in: tv))
    }

    /// Pointing at ordinary prose underlines nothing.
    @MainActor
    func test_hoveringPlainTextUnderlinesNothing() {
        let body = "just some prose with no links at all\n"
        let (coordinator, tv) = editor(body)
        coordinator.underlineLink(at: 5)
        XCTAssertFalse(temporaryUnderline(at: 5, in: tv))
    }
}
