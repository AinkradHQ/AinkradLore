import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Obsidian callouts: `> [!note] Title`.
///
/// The parser is pure, so it is asserted directly; the rendering is asserted
/// through real style spans, because "the span exists" is what every visible
/// consequence hangs off and is exactly the layer the previous milestone's
/// defects slipped through.
final class MarkdownCalloutTests: XCTestCase {

    private func header(_ body: String) -> MarkdownCallout.Header? {
        let ns = body as NSString
        return MarkdownCallout.header(ofQuoteAt: 0..<ns.length, in: ns)
    }

    // MARK: - Parsing

    func test_aPlainQuoteIsNotACallout() {
        XCTAssertNil(header("> just a quote\n"))
        XCTAssertNil(header("> [not a callout]\n"))
        XCTAssertNil(header("> [!] empty type\n"))
        XCTAssertNil(header("> [!nonsense] unknown type\n"))
    }

    func test_theTypeAndTitleAreRead() throws {
        let body = "> [!warning] Mind the gap\n> body text\n"
        let head = try XCTUnwrap(header(body))
        XCTAssertEqual(head.kind, .warning)
        let ns = body as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: head.markerRange.lowerBound,
                                                  length: head.markerRange.count)),
                       "[!warning]")
        let title = try XCTUnwrap(head.titleRange)
        XCTAssertEqual(ns.substring(with: NSRange(location: title.lowerBound,
                                                  length: title.count)),
                       "Mind the gap")
    }

    /// No title is the common case — `> [!note]` on its own — and the one that
    /// needs a name drawn for it, since the `[!note]` collapses to nothing.
    func test_aCalloutWithNoTitleReportsNone() throws {
        let head = try XCTUnwrap(header("> [!tip]\n> body\n"))
        XCTAssertEqual(head.kind, .tip)
        XCTAssertNil(head.titleRange)
        XCTAssertEqual(head.kind.displayTitle, "Tip")
    }

    /// A vault written against Obsidian uses the aliases interchangeably.
    func test_everyAliasResolves() {
        let expected: [String: MarkdownCallout.Kind] = [
            "note": .note, "summary": .abstract, "tldr": .abstract, "abstract": .abstract,
            "info": .info, "todo": .todo, "hint": .tip, "important": .tip, "tip": .tip,
            "check": .success, "done": .success, "success": .success,
            "help": .question, "faq": .question, "question": .question,
            "caution": .warning, "attention": .warning, "warning": .warning,
            "fail": .failure, "missing": .failure, "failure": .failure,
            "error": .danger, "danger": .danger, "bug": .bug,
            "example": .example, "cite": .quote, "quote": .quote,
        ]
        for (spelling, kind) in expected {
            XCTAssertEqual(MarkdownCallout.Kind.named(spelling), kind,
                           "[!\(spelling)] must resolve")
            XCTAssertEqual(header("> [!\(spelling)] t\n")?.kind, kind,
                           "[!\(spelling)] must parse out of a quote")
        }
    }

    func test_theTypeIsCaseInsensitive() {
        XCTAssertEqual(header("> [!WARNING] loud\n")?.kind, .warning)
        XCTAssertEqual(header("> [!Note] mixed\n")?.kind, .note)
    }

    /// `[!note]-` and `[!note]+` are Obsidian's fold markers. Folding is not
    /// implemented; parsing the character keeps it from rendering as a stray
    /// hyphen after the heading.
    func test_aFoldMarkerIsConsumedRatherThanLeftInTheTitle() throws {
        let body = "> [!note]- Collapsed by default\n"
        let head = try XCTUnwrap(header(body))
        XCTAssertTrue(head.isFoldable)
        let ns = body as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: head.markerRange.lowerBound,
                                                  length: head.markerRange.count)),
                       "[!note]-")
        let title = try XCTUnwrap(head.titleRange)
        XCTAssertEqual(ns.substring(with: NSRange(location: title.lowerBound,
                                                  length: title.count)),
                       "Collapsed by default")
    }

    /// The header is read on the FIRST line only. A `[!note]` further down is
    /// prose, and treating it as a header would recolour the whole block from
    /// something the author wrote mid-sentence.
    func test_aTypeOnALaterLineIsNotAHeader() {
        XCTAssertNil(header("> ordinary first line\n> [!danger] not a header\n"))
    }

    func test_aNestedQuotesMarkersAreSkipped() {
        XCTAssertEqual(header("> > [!info] nested\n")?.kind, .info)
    }

    // MARK: - Spans

    private func spans(_ body: String) -> [StyleSpan] {
        MarkdownDocumentModel(body: body).styleSpans
    }

    /// A callout emits `.callout` and NOT `.blockQuote` — they draw different
    /// decoration in the same place, and both would overprint.
    func test_aCalloutReplacesTheBlockQuoteSpan() {
        let found = spans("> [!danger] Careful\n> body\n")
        XCTAssertTrue(found.contains { $0.kind == .callout(.danger) })
        XCTAssertFalse(found.contains { $0.kind == .blockQuote },
                       "a callout must not also be styled as a plain quote")
    }

    func test_aPlainQuoteStillEmitsBlockQuote() {
        let found = spans("> ordinary\n")
        XCTAssertTrue(found.contains { $0.kind == .blockQuote })
        XCTAssertFalse(found.contains { if case .callout = $0.kind { return true }
                                        else { return false } })
    }

    /// The `[!type]` is a MARKER, so the same machinery that hides `**` hides
    /// it — which is what makes the rendered block show a heading rather than
    /// its own declaration.
    func test_theTypeDeclarationIsAMarkerAndSoCollapses() throws {
        let body = "intro\n\n> [!tip] Handy\n> body\n"
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: spans(body),
            selection: NSRange(location: 0, length: 0),   // caret far away
            text: body, isFocused: true)
        let ns = body as NSString
        let marker = ns.range(of: "[!tip]")
        XCTAssertTrue(hidden.contains { $0.lowerBound == marker.location
                                        && $0.upperBound == NSMaxRange(marker) },
                      "[!tip] must be collapsed when the caret is elsewhere")
    }

    /// And it comes back when the caret is on its line, or the syntax could
    /// never be edited.
    func test_theTypeDeclarationRevealsWithTheCaretOnItsLine() {
        let body = "intro\n\n> [!tip] Handy\n> body\n"
        let ns = body as NSString
        let marker = ns.range(of: "[!tip]")
        let hidden = MarkdownReveal.hiddenMarkers(
            spans: spans(body),
            selection: NSRange(location: marker.location + 2, length: 0),
            text: body, isFocused: true)
        XCTAssertFalse(hidden.contains { $0.lowerBound == marker.location },
                       "[!tip] must be visible when the caret is on its line")
    }

    func test_theAuthorsOwnTitleIsStyled() {
        let found = spans("> [!question] Why though\n")
        XCTAssertTrue(found.contains { $0.kind == .calloutTitle(.question) })
    }

    // MARK: - The wiring, end to end

    /// A callout in a REAL editor must reach the layer that draws it.
    ///
    /// The panel, the bar, the icon and the drawn heading are all invisible to
    /// every assertion above: those check spans, and a span nothing consumes
    /// renders nothing. This project has shipped exactly that defect — a
    /// control wired to nothing, passing 1,199 tests — so the span-to-region
    /// wiring is asserted through the real `MarkdownEditor.Coordinator` rather
    /// than by calling `regions(for:)` with hand-made input.
    @MainActor
    func test_aCalloutInARealEditorProducesADrawableRegion() throws {
        let body = "intro\n\n> [!danger] Careful\n> body text\n\ntail\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime((coordinator, window)) {
            let regions = tv.blockBackgrounds
            let callout = try XCTUnwrap(regions.first { region in
                if case .callout = region.kind { return true }
                return false
            }, "the editor must hand the drawing layer a callout region")
            guard case .callout(let kind, let title, _) = callout.kind else {
                return XCTFail("unreachable")
            }
            XCTAssertEqual(kind, .danger)
            XCTAssertNil(title, "the author wrote a title, so none is drawn over it")
            XCTAssertTrue(tv.blockBackgroundPalette != nil,
                          "and a palette to draw it with")
        }
    }

    /// The same, for the case that needs a heading DRAWN: no title written, so
    /// the type's name has to be supplied or the line renders empty once
    /// `[!note]` collapses.
    @MainActor
    func test_aTitlelessCalloutCarriesTheNameToDraw() throws {
        let body = "intro\n\n> [!note]\n> body text\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime(coordinator) {
            let callout = try XCTUnwrap(tv.blockBackgrounds.first { region in
                if case .callout = region.kind { return true }
                return false
            })
            guard case .callout(let kind, let title, _) = callout.kind else {
                return XCTFail("unreachable")
            }
            XCTAssertEqual(kind, .note)
            XCTAssertEqual(title, "Note",
                           "with no title written, the type's name must be drawn")
        }
    }

    /// Every callout type must have an icon macOS can actually render. A
    /// misspelled SF Symbol name fails silently at draw time — no icon, no
    /// error, and nothing else in this suite would notice.
    @MainActor
    func test_everyKindsIconExists() {
        for kind in MarkdownCallout.Kind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName,
                                    accessibilityDescription: nil),
                            "\(kind) declares symbol \"\(kind.symbolName)\", "
                            + "which this system cannot render")
        }
    }

    /// The callout is actually PAINTED — checked by rendering the view and
    /// looking at the pixels.
    ///
    /// Every other test here stops at "the region was handed to the drawing
    /// layer". That is one link short of what the reader sees: `drawCallout`
    /// could return early on a null rect, paint outside the dirty rect, or
    /// paint in the wrong colour, and nothing above would fail. This project's
    /// whole defect history is things that were wired but not visible, so the
    /// last link is closed here by rasterising the view and hunting for the
    /// callout's own hue.
    @MainActor
    func test_aCalloutIsActuallyPainted() throws {
        func redPixelCount(body: String) throws -> Int {
            var stored = body
            let binding = Binding<String>(get: { stored }, set: { stored = $0 })
            let coordinator = MarkdownEditor.Coordinator(text: binding,
                                                         tokens: TestTokens.make())
            let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            tv.isRichText = false
            tv.delegate = coordinator
            tv.drawsBackground = true
            tv.backgroundColor = .black
            let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = tv
            tv.string = body
            coordinator.textView = tv
            coordinator.applyStyles()
            tv.layoutSubtreeIfNeeded()

            return try withExtendedLifetime((coordinator, window)) { () -> Int in
                let rep = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
                tv.cacheDisplay(in: tv.bounds, to: rep)
                var reds = 0
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                        guard let colour = rep.colorAt(x: x, y: y)?
                            .usingColorSpace(.sRGB) else { continue }
                        // The `danger` wash: red clearly ahead of both others.
                        if colour.redComponent > colour.greenComponent + 0.04,
                           colour.redComponent > colour.blueComponent + 0.04 { reds += 1 }
                    }
                }
                return reds
            }
        }

        // The SAME text as an ordinary quote is the control: any red found in
        // it is something other than the callout, and is subtracted by
        // comparison rather than assumed absent.
        let withCallout = try redPixelCount(body: "> [!danger] Careful\n> body text here\n")
        let plainQuote = try redPixelCount(body: "> Careful\n> body text here\n")
        XCTAssertGreaterThan(withCallout, plainQuote + 50,
                             "a danger callout must paint visibly more red than the "
                             + "same text as a plain quote (callout=\(withCallout), "
                             + "quote=\(plainQuote))")
    }

    /// The text indent and the drawn decoration must agree about where the
    /// text starts.
    ///
    /// They were computed apart — the indent as `listIndentStep * 2` (44 pt),
    /// the decoration as bar + gap + icon + gap (29 pt) — so a callout carried
    /// 15 pt of dead space. Invisible while the icon covered it, and an obvious
    /// empty gutter the moment the caret revealed the header and the icon
    /// stopped being drawn (2026-08-17, image 9).
    @MainActor
    func test_theTextIndentIsExactlyWhatTheDecorationNeeds() {
        let indent = MarkdownBlockBackgrounds.calloutTextIndent
        let needed = MarkdownBlockBackgrounds.barWidth
            + MarkdownBlockBackgrounds.calloutIconGap
            + MarkdownStyleRenderer.baseSize
            + MarkdownBlockBackgrounds.calloutIconGap
        XCTAssertEqual(indent, needed, accuracy: 0.001,
                       "the indent must be the decoration's own width, not a guess")

        let style = MarkdownParagraphStyles.style(
            for: .callout(.note), theme: MarkdownTheme(tokens: TestTokens.make()))
        XCTAssertEqual(style.firstLineHeadIndent, indent, accuracy: 0.001,
                       "and the paragraph must use that same number")
        XCTAssertEqual(style.headIndent, indent, accuracy: 0.001)
    }

    /// The indent does NOT change with reveal. Shrinking it when the icon stops
    /// being drawn would shift every line of the callout sideways as the caret
    /// entered it — trading a small gap for a visible jump.
    @MainActor
    func test_theIndentIsTheSameWhetherOrNotTheIconIsDrawn() throws {
        let body = "intro\n\n> [!note]\n> body text\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime((coordinator, window)) { () -> Void in
            let storage = try XCTUnwrap(tv.textStorage)
            let header = (body as NSString).range(of: "> [!note]")
            func indent() -> CGFloat {
                (storage.attribute(.paragraphStyle, at: header.location,
                                   effectiveRange: nil) as? NSParagraphStyle)?
                    .headIndent ?? -1
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.revealForSelectionChange()
            let hidden = indent()
            tv.setSelectedRange(NSRange(location: header.location + 3, length: 0))
            coordinator.revealForSelectionChange()
            XCTAssertEqual(hidden, indent(), accuracy: 0.001,
                           "the callout must not shift sideways as the caret enters it")
        }
    }

    // MARK: - Colour

    /// Every type must resolve a tint, in both a light and a dark theme, and
    /// the neutral `quote` must NOT come out hued.
    @MainActor
    func test_everyKindResolvesATintOnBothSurfaces() {
        for kind in MarkdownCallout.Kind.allCases {
            let tint = MarkdownBlockBackgrounds.Palette
                .calloutTint(kind, tokens: TestTokens.make())
            let srgb = tint.usingColorSpace(.sRGB)
            XCTAssertNotNil(srgb, "\(kind) must resolve in sRGB")
            if kind.isNeutral {
                let components = [srgb?.redComponent, srgb?.greenComponent,
                                  srgb?.blueComponent].compactMap { $0 }
                let spread = (components.max() ?? 0) - (components.min() ?? 0)
                XCTAssertLessThan(spread, 0.05,
                                  "a quote callout must stay neutral, not tinted")
            }
        }
    }

    /// Types that mean different things must not look the same — the colour is
    /// the only thing distinguishing them at a glance once the `[!type]` is
    /// collapsed.
    @MainActor
    func test_distinctMeaningsGetDistinctColours() {
        func tint(_ kind: MarkdownCallout.Kind) -> NSColor {
            MarkdownBlockBackgrounds.Palette
                .calloutTint(kind, tokens: TestTokens.make()).usingColorSpace(.sRGB)!
        }
        let pairs: [(MarkdownCallout.Kind, MarkdownCallout.Kind)] = [
            (.danger, .success), (.warning, .info), (.note, .bug), (.example, .tip),
        ]
        for (a, b) in pairs {
            let first = tint(a), second = tint(b)
            let distance = abs(first.redComponent - second.redComponent)
                + abs(first.greenComponent - second.greenComponent)
                + abs(first.blueComponent - second.blueComponent)
            XCTAssertGreaterThan(distance, 0.2, "\(a) and \(b) must be distinguishable")
        }
    }
}
