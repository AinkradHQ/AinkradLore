import XCTest
import AppKit
@testable import LoreFeature

/// Pure-geometry proof for Task C's fix round: an inline embed image's draw
/// rect must never overflow the container on either side, and an RTL
/// paragraph's image must sit at the RIGHT margin growing leftward, not the
/// left margin growing rightward past it. No `NSTextView`, no window, no
/// live layout — see `EmbedGeometry.drawRect`'s doc comment for why it
/// deliberately takes none of those as input.
final class EmbedGeometryTests: XCTestCase {
    private let containerWidth: CGFloat = 400
    private let imageSize = NSSize(width: 100, height: 60)

    func test_ltrTopLevel_sitsAtTheLeftMargin() {
        let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                          writingDirection: .leftToRight,
                                          indent: 0, imageSize: imageSize)
        XCTAssertEqual(rect.origin.x, 0)
        XCTAssertEqual(rect.size, imageSize)
    }

    func test_rtlTopLevel_sitsAtTheRightMargin() {
        let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                          writingDirection: .rightToLeft,
                                          indent: 0, imageSize: imageSize)
        // The image's RIGHT edge must be flush with the container's right
        // edge, growing LEFTWARD from there — the exact defect the owner
        // hit: the buggy code grew rightward from a right-margin x and
        // painted past the container.
        XCTAssertEqual(rect.origin.x, containerWidth - imageSize.width)
        XCTAssertLessThanOrEqual(rect.origin.x + rect.size.width, containerWidth,
                                 "must never overflow the right edge")
    }

    func test_indentedLTR_sitsAtTheListOrBlockquoteIndent() {
        let indent: CGFloat = 40
        let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                          writingDirection: .leftToRight,
                                          indent: indent, imageSize: imageSize)
        XCTAssertEqual(rect.origin.x, indent,
                       "a list/blockquote-nested embed must sit at its context's indent, "
                       + "not reset to zero")
    }

    func test_indentedRTL_sitsInFromTheRightMargin() {
        let indent: CGFloat = 40
        let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                          writingDirection: .rightToLeft,
                                          indent: indent, imageSize: imageSize)
        XCTAssertEqual(rect.origin.x, containerWidth - indent - imageSize.width)
        XCTAssertGreaterThanOrEqual(rect.origin.x, 0, "must never overflow the left edge either")
    }

    /// `drawRect` only ever POSITIONS an image — the SIZE arriving here is
    /// already `applyEmbeds`'s own `maxWidth`/`maxHeight`-capped scale, so an
    /// image wider than the container is a contract violation upstream, not
    /// something this function can fix by shrinking it. What it MUST still
    /// guarantee, for either direction: the origin never goes negative, i.e.
    /// the image is pinned flush to the LEFT edge rather than pushed further
    /// off-screen — the clamp's `upperBound` floors at 0 for exactly this
    /// case.
    func test_imageWiderThanTheContainer_originIsPinnedNotNegative() {
        let hugeImage = NSSize(width: 900, height: 60)
        for direction: NSWritingDirection in [.leftToRight, .rightToLeft] {
            let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                              writingDirection: direction,
                                              indent: 0, imageSize: hugeImage)
            XCTAssertEqual(rect.origin.x, 0, "\(direction)")
        }
    }

    func test_imageWiderThanTheRoomLeftByAnIndent_isClamped() {
        // Indent alone would push the image origin past the container's own
        // right edge (RTL) or leave no room on the left (LTR); the clamp
        // must win over the indent in that squeeze, not just over the raw
        // container width.
        let indent: CGFloat = 350
        for direction: NSWritingDirection in [.leftToRight, .rightToLeft] {
            let rect = EmbedGeometry.drawRect(containerWidth: containerWidth,
                                              writingDirection: direction,
                                              indent: indent, imageSize: imageSize)
            XCTAssertGreaterThanOrEqual(rect.origin.x, 0, "\(direction)")
            XCTAssertLessThanOrEqual(rect.origin.x + rect.size.width, containerWidth, "\(direction)")
        }
    }

    // MARK: - naturalWritingDirection

    func test_naturalWritingDirection_arabicTextIsRTL() {
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: "مرحبا بالعالم"), .rightToLeft)
    }

    func test_naturalWritingDirection_latinTextIsLTR() {
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: "Hello world"), .leftToRight)
    }

    func test_naturalWritingDirection_arabicWithLeadingPunctuationIsStillRTL() {
        // The embed's own source markers/punctuation carry no strong bidi
        // class; the first STRONG character must decide it.
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: "«مرحبا»"), .rightToLeft)
    }

    func test_naturalWritingDirection_emptyOrNeutralTextFallsBackToLTR() {
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: ""), .leftToRight)
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: "123 !!"), .leftToRight)
    }

    // MARK: - contextualWritingDirection (fix round 1, Critical 1)

    /// THE INPUT THAT WAS ACTUALLY BROKEN: an Arabic document whose embed
    /// sits alone on its own paragraph, `![[screenshot.png]]` — a LATIN
    /// filename. `naturalWritingDirection(of:)` on that paragraph ALONE
    /// resolves `.leftToRight` every time (the filename is the only strong
    /// character in it), which is exactly what made the RTL branch
    /// unreachable for the owner's real notes. `contextualWritingDirection`
    /// must instead look at the ARABIC PROSE around the embed and resolve
    /// `.rightToLeft`.
    func test_contextualWritingDirection_arabicParagraphBeforeALatinFilenameEmbed_resolvesRTL() {
        let text = "مرحبا بكم في الملاحظات\n\n![[screenshot.png]]\n" as NSString
        // The FULL paragraph range, terminator included — matching exactly
        // what `EmbedRendering.applyEmbeds` passes (`text.paragraphRange(for:
        // full_)`), so `NSMaxRange(embedParagraph)` lands past the `\n` and a
        // forward scan cannot loop back onto the embed's own paragraph.
        let embedParagraph = text.paragraphRange(for: text.range(of: "![[screenshot.png]]"))
        // Sanity: the embed's OWN paragraph text alone would resolve LTR —
        // this is the precondition that makes the test meaningful at all.
        XCTAssertEqual(EmbedGeometry.naturalWritingDirection(of: "![[screenshot.png]]"),
                       .leftToRight, "precondition: the embed's own text is Latin-only")

        let resolved = EmbedGeometry.contextualWritingDirection(
            paragraph: embedParagraph, in: text)
        XCTAssertEqual(resolved, .rightToLeft,
                       "the Arabic paragraph ABOVE the embed must decide its direction, "
                       + "not the Latin filename inside it")
    }

    /// The other neighbour: no text before the embed (it opens the
    /// document), but Arabic prose follows it.
    func test_contextualWritingDirection_fallsForwardToTheNextParagraphWhenNoneComesBefore() {
        let text = "![[screenshot.png]]\n\nمرحبا بكم\n" as NSString
        // The FULL paragraph range, terminator included — matching exactly
        // what `EmbedRendering.applyEmbeds` passes (`text.paragraphRange(for:
        // full_)`), so `NSMaxRange(embedParagraph)` lands past the `\n` and a
        // forward scan cannot loop back onto the embed's own paragraph.
        let embedParagraph = text.paragraphRange(for: text.range(of: "![[screenshot.png]]"))
        let resolved = EmbedGeometry.contextualWritingDirection(
            paragraph: embedParagraph, in: text)
        XCTAssertEqual(resolved, .rightToLeft)
    }

    /// Neither neighbour has a strong character (both blank/neutral): the
    /// DOCUMENT's own dominant direction — the caller's `documentFallback`
    /// — decides it, rather than silently defaulting to LTR.
    func test_contextualWritingDirection_fallsBackToTheDocumentFallbackWhenNoNeighbourIsStrong() {
        let text = "   \n\n![[screenshot.png]]\n\n   \n" as NSString
        // The FULL paragraph range, terminator included — matching exactly
        // what `EmbedRendering.applyEmbeds` passes (`text.paragraphRange(for:
        // full_)`), so `NSMaxRange(embedParagraph)` lands past the `\n` and a
        // forward scan cannot loop back onto the embed's own paragraph.
        let embedParagraph = text.paragraphRange(for: text.range(of: "![[screenshot.png]]"))
        let resolved = EmbedGeometry.contextualWritingDirection(
            paragraph: embedParagraph, in: text, documentFallback: .rightToLeft)
        XCTAssertEqual(resolved, .rightToLeft)

        let resolvedLTR = EmbedGeometry.contextualWritingDirection(
            paragraph: embedParagraph, in: text, documentFallback: .leftToRight)
        XCTAssertEqual(resolvedLTR, .leftToRight)
    }

    /// A LATIN document is completely unaffected by this fix: the immediate
    /// neighbour is Latin prose, so the result is still `.leftToRight` —
    /// this is the regression guard for "existing English notes must look
    /// exactly as before".
    func test_contextualWritingDirection_latinParagraphBeforeAnEmbed_resolvesLTR() {
        let text = "Here is a screenshot of the bug:\n\n![[screenshot.png]]\n" as NSString
        // The FULL paragraph range, terminator included — matching exactly
        // what `EmbedRendering.applyEmbeds` passes (`text.paragraphRange(for:
        // full_)`), so `NSMaxRange(embedParagraph)` lands past the `\n` and a
        // forward scan cannot loop back onto the embed's own paragraph.
        let embedParagraph = text.paragraphRange(for: text.range(of: "![[screenshot.png]]"))
        let resolved = EmbedGeometry.contextualWritingDirection(
            paragraph: embedParagraph, in: text)
        XCTAssertEqual(resolved, .leftToRight)
    }
}
