import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

final class MarkdownThemeTests: XCTestCase {
    private var theme: MarkdownTheme { MarkdownTheme(tokens: TestTokens.make()) }

    /// Hierarchy must come from SIZE, monotonically. M2a used colour for this,
    /// which is what made a note read as bands of accent rather than as text.
    func test_headingSizesDescendStrictlyAndStayAboveBody() {
        let sizes = (1...6).map { theme.headingSize($0) }
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThan(a, b, "each heading level must be smaller than the one above")
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes.last), theme.bodySize,
                             "even h6 must outrank body text")
    }

    /// Rhythm: space before a heading exceeds space after it, so a heading
    /// binds to the text it introduces rather than floating between blocks.
    func test_headingBindsToTheTextBelowIt() {
        for level in 1...6 {
            XCTAssertGreaterThan(theme.headingSpacingBefore(level),
                                 theme.headingSpacingAfter(level),
                                 "h\(level) must sit closer to what follows it")
        }
    }

    func test_bodyHasRealLineHeightAndParagraphSpacing() {
        XCTAssertGreaterThan(theme.lineHeightMultiple, 1.0)
        XCTAssertGreaterThan(theme.paragraphSpacing, 0)
        XCTAssertGreaterThan(theme.contentInset, 0, "text must not run edge to edge")
    }
}

extension MarkdownThemeTests {
    private func style(_ block: MarkdownBlock) -> NSParagraphStyle {
        MarkdownParagraphStyles.style(for: block, theme: MarkdownTheme(tokens: TestTokens.make()))
    }

    /// `headIndent` is what makes a WRAPPED list line align under the text
    /// instead of under the bullet. Without it a two-line bullet looks broken,
    /// which is most of "lists are unstyled".
    func test_listItemHangsWrappedLinesUnderTheText() {
        let s = style(.listItem(depth: 0))
        XCTAssertGreaterThan(s.headIndent, s.firstLineHeadIndent,
                             "wrapped lines must be indented past the bullet")
    }

    func test_nestedListsStepByDepth() {
        let d0 = style(.listItem(depth: 0)).firstLineHeadIndent
        let d1 = style(.listItem(depth: 1)).firstLineHeadIndent
        let d2 = style(.listItem(depth: 2)).firstLineHeadIndent
        XCTAssertEqual(d1 - d0, d2 - d1, accuracy: 0.01, "depth must step uniformly")
        XCTAssertGreaterThan(d1, d0)
    }

    func test_blockQuoteIsIndentedToLeaveRoomForItsBar() {
        XCTAssertGreaterThan(style(.blockQuote).firstLineHeadIndent, 0)
    }

    /// Indentation is a paragraph attribute, never inserted characters —
    /// inserting whitespace would change the document, and every index and
    /// link offset with it.
    func test_headingsCarryTheirOwnSpacing() {
        let h1 = style(.heading(1))
        XCTAssertGreaterThan(h1.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(h1.paragraphSpacing, 0)
    }
}

/// Task 6: accent stops meaning "important" and starts meaning "clickable".
@MainActor
extension MarkdownThemeTests {

    /// Headings use FOREGROUND. Accent is reserved for things you can click,
    /// so accent means "interactive" rather than "important".
    func test_headingsUseForegroundNotAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "# Title")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<7, kind: .heading(1))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, NSColor(tokens.foreground))
    }

    /// Code loses the accent tint entirely — mono plus a background is enough,
    /// and the tint is what made whole fences read as coloured bands.
    func test_codeIsNotTintedWithAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "let x = 1")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<9, kind: .codeBlock(language: "swift"))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(colour, NSColor(tokens.accentSecondary))
    }

    /// Links keep accent — that is now what accent MEANS.
    func test_linksKeepAccent() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "[[Target]]")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<10, kind: .wikilink)],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let colour = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, NSColor(tokens.accentPrimary))
    }

    func test_headingSizesComeFromTheTheme() {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let storage = NSTextStorage(string: "# T")
        MarkdownStyleRenderer.apply([StyleSpan(range: 0..<3, kind: .heading(1))],
                                    to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(try XCTUnwrap(font).pointSize, theme.headingSize(1), accuracy: 0.01)
    }

    /// A whole fence must NOT carry a per-glyph background: that attribute
    /// stops at the end of each line, which is the ragged staircase this task
    /// replaced with a drawn panel.
    func test_codeBlocksCarryNoPerGlyphBackground() {
        let tokens = TestTokens.make()
        let storage = NSTextStorage(string: "let x = 1\nlet yy = 22")
        MarkdownStyleRenderer.apply(
            [StyleSpan(range: 0..<21, kind: .codeBlock(language: nil))],
            to: storage, tokens: tokens,
            theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                     "code panels are drawn, not attributed")
    }

    /// The drawn regions are derived from the block spans, and only those.
    func test_regionsCoverCodeAndQuotesOnly() {
        let spans = [StyleSpan(range: 0..<5, kind: .codeBlock(language: nil)),
                     StyleSpan(range: 5..<9, kind: .blockQuote),
                     StyleSpan(range: 9..<12, kind: .heading(2)),
                     StyleSpan(range: 12..<40, kind: .blockQuote)]   // past the end
        let regions = MarkdownBlockBackgrounds.regions(for: spans, length: 12)
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 0, length: 5)),
            .init(kind: .quoteBar, range: NSRange(location: 5, length: 4))
        ])
    }

    /// Requirement 2. The owner's complaint was that text runs edge to edge.
    /// `contentInset` existed and was ignored in favour of a hard-coded 16.
    func test_theTextContainerUsesTheThemeInsetRatherThanAHardcodedSixteen() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        // Narrow enough that the measure cap cannot be the thing setting the
        // inset — this is the plain "comfortable margin" case.
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: 500, theme: theme)
        XCTAssertEqual(inset.width, theme.contentInset, accuracy: 0.01)
        XCTAssertNotEqual(inset.width, 16, accuracy: 0.01)
    }

    /// Task 5: the column is LEFT-ALIGNED, not centred. `containerInset` keeps
    /// the theme's flat inset even on a wide window — the measure cap now
    /// lives on the text container's width, not on this inset.
    func test_aWideViewKeepsTheFlatInsetRatherThanCentring() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let width: CGFloat = 2000
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: width, theme: theme)
        XCTAssertEqual(inset.width, theme.contentInset, accuracy: 0.01,
                       "a wide view must not grow its inset to centre the column")
    }

    /// The cap must never make the margin smaller than the theme's floor on a
    /// narrow window — a phone-width pane still gets its breathing room.
    func test_aNarrowViewNeverShrinksBelowTheThemeInset() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let inset = MarkdownEditorLayout.containerInset(forViewWidth: 120, theme: theme)
        XCTAssertEqual(inset.width, theme.contentInset, accuracy: 0.01)
    }

    /// Task 5: the drawn decoration still has to track the column now that it
    /// is left-aligned. `columnX` reads `textContainerOrigin` (unchanged);
    /// `columnWidth` now reads the container's own capped size, set the same
    /// way `MarkdownEditor` sets it, rather than deriving a symmetric margin
    /// from the view's bounds.
    func test_backgroundGeometryTracksTheTextColumnWhenLeftAligned() throws {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let measure = try XCTUnwrap(theme.maxMeasure)
        let width: CGFloat = 2000
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        tv.isHorizontallyResizable = false
        tv.textContainerInset = MarkdownEditorLayout.containerInset(forViewWidth: width,
                                                                    theme: theme)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: measure, height: .greatestFiniteMagnitude)
        let x = MarkdownBlockBackgrounds.columnX(in: tv)
        let columnWidth = MarkdownBlockBackgrounds.columnWidth(in: tv)
        XCTAssertEqual(x, tv.textContainerOrigin.x, accuracy: 0.5,
                       "decoration must use the same origin the text rects use")
        XCTAssertEqual(x, theme.contentInset, accuracy: 0.5,
                       "a left-aligned column starts at the bare inset, not centred")
        XCTAssertEqual(columnWidth, measure, accuracy: 0.5,
                       "the panel's width must come from the capped container, not the view")
    }

    /// Requirement 6. `MarkdownParagraphStyles` has taken a depth since Task 5;
    /// nothing ever supplied one, so every nesting level rendered flat.
    func test_nestedListItemsIndentByDerivedDepth() throws {
        let tokens = TestTokens.make()
        let body = "- outer\n    - inner\n"
        let model = MarkdownDocumentModel(body: body)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.apply(model.styleSpans, to: storage, tokens: tokens,
                                    theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let outer = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "outer").location,
            effectiveRange: nil) as? NSParagraphStyle)
        let inner = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "inner").location,
            effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(outer.firstLineHeadIndent, 0,
                             "even a top-level item must indent")
        XCTAssertGreaterThan(inner.firstLineHeadIndent, outer.firstLineHeadIndent,
                             "a nested item must indent past its parent")
    }

    /// Depth is DERIVED from containment, so a second top-level item after a
    /// nested one must fall back to depth 0 rather than inheriting the nesting.
    func test_listDepthReturnsToZeroAfterANestedItem() {
        let spans = [StyleSpan(range: 0..<20, kind: .listItem),
                     StyleSpan(range: 5..<15, kind: .listItem),
                     StyleSpan(range: 20..<30, kind: .listItem)]
        XCTAssertEqual(MarkdownListDepth.depths(of: spans), [0, 1, 0])
    }

    /// FINDING 3. A nested item's source indentation is real, visible text that
    /// no marker collapses, so its first line begins at `firstLineHeadIndent`
    /// PLUS that whitespace — and a fixed hang put every wrapped nested line to
    /// the LEFT of the text it was supposed to hang under.
    func test_nestedListWrappedLinesHangUnderTheFirstLinesText() throws {
        let tokens = TestTokens.make()
        let body = "- outer\n    - inner text long enough to wrap\n"
        let model = MarkdownDocumentModel(body: body)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.apply(model.styleSpans, to: storage, tokens: tokens,
                                    theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let inner = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "inner").location,
            effectiveRange: nil) as? NSParagraphStyle)
        // Four spaces of source indent, in the monospaced base font.
        let space = (" " as NSString).size(
            withAttributes: [.font: MarkdownStyleRenderer.baseFont]).width
        XCTAssertEqual(inner.headIndent, inner.firstLineHeadIndent + space * 4,
                       accuracy: 0.5,
                       "the hang must clear the source indentation, not ignore it")
        XCTAssertGreaterThan(inner.headIndent, inner.firstLineHeadIndent)
    }

    /// The derivation is additive: `style(for:theme:)` keeps its committed
    /// answer, and only the new entry point derives the hang.
    func test_theDerivedHangIsRelativeToTheItemsOwnIndent() {
        let theme = MarkdownTheme(tokens: TestTokens.make())
        let flat = MarkdownParagraphStyles.listItemStyle(depth: 0, leadingIndent: 0,
                                                         theme: theme)
        XCTAssertEqual(flat.headIndent, flat.firstLineHeadIndent, accuracy: 0.01,
                       "wrapped lines align under the first line's text")
        // The collapsed bullet is no longer NOTHING: `MarkdownBlockBackgrounds`
        // draws a substitute in the space to the LEFT of where the text starts,
        // so that space has to exist.
        XCTAssertGreaterThan(flat.firstLineHeadIndent,
                             MarkdownBlockBackgrounds.listMarkerGap,
                             "a list item needs a gutter for its drawn marker")
        let nested = MarkdownParagraphStyles.listItemStyle(depth: 1, leadingIndent: 40,
                                                           theme: theme)
        XCTAssertEqual(nested.headIndent - nested.firstLineHeadIndent, 40, accuracy: 0.01)
    }

    // MARK: - FINDING 2: a collapsed list marker gets a drawn substitute

    /// The regression in words: an unfocused ordered list lost its numbering
    /// entirely, because the marker was collapsed and nothing was put back.
    /// The drawn substitute carries the item's OWN ordinal.
    func test_orderedListMarkersKeepTheirOwnNumbers() {
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "1. "), "1.")
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "7. "), "7.")
        XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: "10) "), "10.")
    }

    /// `-`, `*` and `+` all draw as one real bullet glyph, so which character
    /// the author typed stops showing through in the reading state.
    func test_unorderedListMarkersDrawAsABullet() {
        for source in ["- ", "* ", "+ "] {
            XCTAssertEqual(MarkdownBlockBackgrounds.listMarkerGlyph(for: source), "•", source)
        }
    }

    /// The `MarkdownMarkers` rule, kept: a shape that is not a list marker gets
    /// nothing rather than a guessed glyph in the gutter.
    func test_aMarkerThatIsNotAListMarkerDrawsNothing() {
        XCTAssertNil(MarkdownBlockBackgrounds.listMarkerGlyph(for: "## "))
        XCTAssertNil(MarkdownBlockBackgrounds.listMarkerGlyph(for: "1x "))
        XCTAssertNil(MarkdownBlockBackgrounds.listMarkerGlyph(for: ". "))
        XCTAssertNil(MarkdownBlockBackgrounds.listMarkerGlyph(for: "   "))
    }

    /// End to end from a real document: parsing a mixed list yields exactly one
    /// drawn region per item, reading the ordinals out of the source.
    func test_aParsedListYieldsOneDrawnMarkerPerItem() {
        let body = "- alpha\n- beta\n\n1. one\n2. two\n"
        let model = MarkdownDocumentModel(body: body)
        let regions = MarkdownBlockBackgrounds.regions(
            for: model.styleSpans, length: (body as NSString).length,
            in: body as NSString)
        let glyphs = regions.compactMap { region -> String? in
            if case .listMarker(let glyph) = region.kind { return glyph }
            return nil
        }
        XCTAssertEqual(glyphs, ["•", "•", "1.", "2."])
    }

    /// A caller that passes no text asks only for the block decorations, and
    /// must not get a marker whose content could only have been guessed.
    func test_withoutTheDocumentNoListMarkersAreEmitted() {
        let body = "- alpha\n"
        let model = MarkdownDocumentModel(body: body)
        let regions = MarkdownBlockBackgrounds.regions(for: model.styleSpans,
                                                       length: (body as NSString).length)
        XCTAssertTrue(regions.allSatisfy {
            if case .listMarker = $0.kind { return false }
            return true
        })
    }

    /// A marker is two or three characters, so a HALF marker is meaningless:
    /// one straddling the viewport window is dropped rather than clipped, which
    /// is the opposite of what a code panel wants.
    func test_aListMarkerStraddlingTheWindowIsDroppedNotClipped() {
        let body = "- alpha\n"
        let model = MarkdownDocumentModel(body: body)
        let regions = MarkdownBlockBackgrounds.regions(
            for: model.styleSpans, length: (body as NSString).length,
            limitedTo: NSRange(location: 0, length: 1), in: body as NSString)
        XCTAssertTrue(regions.allSatisfy {
            if case .listMarker = $0.kind { return false }
            return true
        })
    }

    /// FINDING 5. A fence INSIDE a list item is indented, so its paragraph's
    /// first character is the item's leading whitespace — which now carries a
    /// listItem paragraph style. `endEditing` extends that first character's
    /// style over the paragraph, so a code style applied over the raw span
    /// range loses. Nothing made this reachable until list items started
    /// writing a paragraph style at all.
    func test_aFenceNestedInAListItemKeepsTheCodeParagraphStyle() throws {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let body = "- item\n\n    ```\n    let x = 1\n    ```\n"
        let model = MarkdownDocumentModel(body: body)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.apply(model.styleSpans, to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let code = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "let x").location,
            effectiveRange: nil) as? NSParagraphStyle)
        let expected = MarkdownParagraphStyles.style(for: .codeBlock, theme: theme)
        XCTAssertEqual(code.lineHeightMultiple, expected.lineHeightMultiple, accuracy: 0.01,
                       "the code block's own rhythm must survive the enclosing item")
        XCTAssertEqual(code.paragraphSpacing, expected.paragraphSpacing, accuracy: 0.01)
    }

    /// The same trap, for a quote indented inside a list item.
    func test_aQuoteNestedInAListItemKeepsTheQuoteParagraphStyle() throws {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let body = "- item\n\n    > quoted line\n"
        let model = MarkdownDocumentModel(body: body)
        let storage = NSTextStorage(string: body)
        MarkdownStyleRenderer.apply(model.styleSpans, to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let quote = try XCTUnwrap(storage.attribute(
            .paragraphStyle, at: (body as NSString).range(of: "quoted").location,
            effectiveRange: nil) as? NSParagraphStyle)
        let expected = MarkdownParagraphStyles.style(for: .blockQuote, theme: theme)
        XCTAssertEqual(quote.firstLineHeadIndent, expected.firstLineHeadIndent,
                       accuracy: 0.01,
                       "the quote's own indent must survive the enclosing item")
    }

    /// Requirement 4. Regions are derived from ALL spans while attributes are
    /// windowed, so an unclipped panel could be painted behind text that was
    /// never styled.
    func test_regionsAreClippedToTheViewportWindow() {
        let spans = [StyleSpan(range: 0..<10, kind: .codeBlock(language: nil)),
                     StyleSpan(range: 100..<120, kind: .blockQuote)]
        let window = NSRange(location: 0, length: 50)
        let regions = MarkdownBlockBackgrounds.regions(for: spans, length: 200,
                                                       limitedTo: window)
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 0, length: 10))
        ], "a region outside the styled window must not be drawn")
    }

    /// A region straddling the window edge is clipped, not dropped — the
    /// visible half still needs its panel.
    func test_aRegionStraddlingTheWindowIsClippedNotDropped() {
        let spans = [StyleSpan(range: 40..<200, kind: .codeBlock(language: nil))]
        let regions = MarkdownBlockBackgrounds.regions(
            for: spans, length: 200, limitedTo: NSRange(location: 0, length: 50))
        XCTAssertEqual(regions, [
            .init(kind: .codePanel, range: NSRange(location: 40, length: 10))
        ])
    }

    /// Body text gets real line height even with no spans at all — the rhythm
    /// is the floor, not something only headings enjoy.
    func test_bodyTextCarriesTheThemesLineHeight() {
        let tokens = TestTokens.make()
        let theme = MarkdownTheme(tokens: tokens)
        let storage = NSTextStorage(string: "just prose")
        MarkdownStyleRenderer.apply([], to: storage, tokens: tokens,
                                    theme: theme, limitedTo: nil)
        let style = storage.attribute(.paragraphStyle, at: 0,
                                      effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(style).lineHeightMultiple,
                       theme.lineHeightMultiple, accuracy: 0.01)
    }
}
