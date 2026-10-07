import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// M9.3: the four constructs Lore parsed and then showed as raw source.
///
/// Every test here drives the REAL editor rather than asserting on spans
/// alone. M9.2 dropped a task whose premise looked sound in the source and was
/// false in a running text view, and these are the same class of claim.
final class ElementParityTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func editor(
        _ body: String,
        settings: EditorSettings = .default
    )
        -> (MarkdownEditor.Coordinator, LinkTextView)
    {
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.settings = settings
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
    private func regionKinds(in tv: LinkTextView) -> [MarkdownBlockBackgrounds.Kind] {
        tv.blockBackgrounds.map(\.kind)
    }

    @MainActor
    private func width(ofCharacterAt offset: Int, in tv: LinkTextView) -> CGFloat {
        let rect = MarkdownBlockBackgrounds.boundingRect(
            of: NSRange(location: offset, length: 1), in: tv)
        return rect.isNull ? 0 : rect.width
    }

    // MARK: - T10 task checkboxes

    /// The `[x]` collapses and a checkbox region takes its place. The caret is
    /// parked on a far line, so nothing here is revealed.
    @MainActor
    func test_aTaskMarkerCollapsesAndDrawsACheckbox() {
        let body = "- [ ] open task\n- [x] done task\n\nfar away paragraph\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(
            NSRange(
                location: (body as NSString).range(of: "far").location,
                length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        let openMarker = (body as NSString).range(of: "[ ]").location
        XCTAssertLessThan(
            width(ofCharacterAt: openMarker, in: tv),
            MarkdownBlockBackgrounds.collapsedMarkerWidth,
            "the brackets must collapse, not stay spelled out")

        let checkboxes = regionKinds(in: tv).compactMap { kind -> Bool? in
            if case .checkbox(let done) = kind { return done }
            return nil
        }
        XCTAssertEqual(
            checkboxes, [false, true],
            "one region per task, in document order, carrying its state")
    }

    /// A task item draws a CHECKBOX and not also a bullet. Obsidian shows one
    /// control per task; drawing both would put "• ☐" on every line.
    @MainActor
    func test_aTaskItemDrawsNoBulletBesideItsCheckbox() {
        let body = "- [ ] a task\n- an ordinary item\n\nfar away\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(
            NSRange(
                location: (body as NSString).range(of: "far").location,
                length: 0))
        coordinator.revealForSelectionChange()

        let bullets = regionKinds(in: tv).filter {
            if case .listMarker = $0 { return true }
            return false
        }
        XCTAssertEqual(
            bullets.count, 1,
            "only the ORDINARY item gets a bullet; the task gets its box")
    }

    /// A finished task strikes and fades its own line — the part a drawn box
    /// cannot say, and most of what makes a task list scannable.
    @MainActor
    func test_aCompletedTaskStrikesItsText() throws {
        let body = "- [x] done task\n- [ ] open task\n"
        let (_, tv) = editor(body)
        let storage = try XCTUnwrap(tv.textStorage)
        let done = (body as NSString).range(of: "done task").location
        let open = (body as NSString).range(of: "open task").location

        XCTAssertNotNil(
            storage.attribute(
                .strikethroughStyle, at: done,
                effectiveRange: nil),
            "a finished task reads as finished")
        XCTAssertNil(
            storage.attribute(
                .strikethroughStyle, at: open,
                effectiveRange: nil),
            "an open one does not")
    }

    /// The caret on the task's own line puts the source back, so `[x]` can be
    /// edited — and the box must not be painted on top of it.
    @MainActor
    func test_theCaretOnATaskLineRevealsItsBrackets() {
        let body = "- [x] done task\n\nfar away\n"
        let (coordinator, tv) = editor(body)
        let marker = (body as NSString).range(of: "[x]").location
        tv.setSelectedRange(NSRange(location: marker + 1, length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            width(ofCharacterAt: marker, in: tv),
            MarkdownBlockBackgrounds.collapsedMarkerWidth,
            "the writer editing a task must be able to see [x]")
    }

    // MARK: - T11 thematic break

    @MainActor
    func test_aThematicBreakCollapsesAndDrawsARule() {
        let body = "above\n\n---\n\nbelow\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        let dashes = (body as NSString).range(of: "---").location
        XCTAssertLessThan(
            width(ofCharacterAt: dashes, in: tv),
            MarkdownBlockBackgrounds.collapsedMarkerWidth,
            "the dashes must not stay on screen")
        XCTAssertTrue(
            regionKinds(in: tv).contains {
                if case .rule = $0 { return true }
                return false
            },
            "a rule is drawn where they were")
    }

    /// A `---` under text is a SETEXT HEADING, not a rule. Drawing a line
    /// through someone's h2 would be worse than leaving the source visible.
    @MainActor
    func test_aSetextHeadingIsNotMistakenForARule() {
        let body = "Heading text\n---\n\nbody\n"
        let (_, tv) = editor(body)
        XCTAssertFalse(
            regionKinds(in: tv).contains {
                if case .rule = $0 { return true }
                return false
            },
            "the AST calls this a heading, and so must the renderer")
    }

    // MARK: - T12 standard markdown images

    /// `![alt](path)` reaches the SAME `.embed` span an `![[wikilink]]` does,
    /// which is what lets `EmbedRendering` render it with no changes.
    func test_aStandardImageBecomesAnEmbedSpan() {
        let body = "before ![alt text](pictures/shot.png) after\n"
        let model = MarkdownDocumentModel(body: body)
        let embeds = model.styleSpans.compactMap { span -> String? in
            if case .embed(let target, _) = span.kind { return target }
            return nil
        }
        XCTAssertEqual(
            embeds, ["pictures/shot.png"],
            "the SOURCE identifies the image, not the alt text")
    }

    /// The alt text and the parentheses are notation and collapse with the
    /// rest; only then does the picture stand alone on the line.
    @MainActor
    func test_aStandardImagesNotationCollapses() {
        let body = "![alt text](pictures/shot.png)\n\nfar away\n"
        let (coordinator, tv) = editor(body)
        tv.setSelectedRange(
            NSRange(
                location: (body as NSString).range(of: "far").location,
                length: 0))
        coordinator.revealForSelectionChange()
        tv.layoutSubtreeIfNeeded()

        for probe in [0, (body as NSString).range(of: "alt").location] {
            XCTAssertLessThan(
                width(ofCharacterAt: probe, in: tv),
                MarkdownBlockBackgrounds.collapsedMarkerWidth,
                "character \(probe) of the image's notation is still visible")
        }
    }

    /// An image inside a fence is code. CommonMark never inline-parses fenced
    /// content, so no `Image` node reaches the collector — this pins that.
    func test_anImageInsideAFenceIsNotAnEmbed() {
        let body = "```\n![alt](shot.png)\n```\n"
        let model = MarkdownDocumentModel(body: body)
        XCTAssertFalse(
            model.styleSpans.contains {
                if case .embed = $0.kind { return true }
                return false
            })
    }

    /// A malformed image emits nothing rather than a guessed marker range — a
    /// wrong marker HIDES the author's own text once collapsed.
    func test_aReferenceStyleImageEmitsNoEmbed() {
        let model = MarkdownDocumentModel(body: "![alt][ref]\n\n[ref]: shot.png\n")
        XCTAssertFalse(
            model.styleSpans.contains {
                if case .embed = $0.kind { return true }
                return false
            })
    }

    // MARK: - T13 tag pills

    @MainActor
    func test_aTagDrawsAPillRatherThanAGlyphBackground() throws {
        let body = "tagged #project/alpha here\n"
        let (_, tv) = editor(body)
        let inside = (body as NSString).range(of: "project").location

        XCTAssertNil(
            try XCTUnwrap(tv.textStorage).attribute(
                .backgroundColor, at: inside,
                effectiveRange: nil),
            "a per-glyph background cannot round or pad, so it is gone")
        XCTAssertTrue(
            regionKinds(in: tv).contains {
                if case .tagPill = $0 { return true }
                return false
            })
    }

    /// With the setting off, no pill is drawn at all — the tag is tinted text.
    @MainActor
    func test_theChipSettingSuppressesThePill() {
        let settings = EditorSettings(
            density: .standard, measure: .standard, zoomStep: 0,
            renderTagsAsChips: false)
        let (_, tv) = editor("tagged #alpha here\n", settings: settings)
        XCTAssertFalse(
            regionKinds(in: tv).contains {
                if case .tagPill = $0 { return true }
                return false
            })
    }
}
