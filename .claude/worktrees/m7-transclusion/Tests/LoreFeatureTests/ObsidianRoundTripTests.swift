import XCTest
@testable import LoreFeature

/// The milestone's headline claim, asserted rather than assumed: a vault
/// round-trips between Lore and Obsidian without loss.
///
/// The Obsidian half of that needs Obsidian and stays a manual walkthrough
/// step. The LORE half is mechanical and belongs here — every offset the
/// index, the link graph and the MCP tools hold is measured against the
/// unmodified source, so if any pass mutates the text, every one of those is
/// silently wrong. Nothing in the suite pinned that invariant across the five
/// M6 syntaxes until now.
final class ObsidianRoundTripTests: XCTestCase {

    /// One document exercising every syntax M6 added, plus the ones it had to
    /// keep working alongside — including the awkward neighbours: a code
    /// fence that must suppress all of them, CRLF, and an emoji whose UTF-16
    /// width is not its character width.
    private let document = """
    ---
    title: Round trip
    tags: [alpha, beta]
    ---
    # Heading with a ^caret and #tag

    Prose with ~~strike~~, ==highlight==, a #tag/nested, a [[wikilink]],
    a footnote[^note], and math $\\frac{a}{b}$ inline. Emoji 🎯 then more.

    > [!note] A callout
    > with ==highlight== inside it.

    | col | alignment |
    |:----|----------:|
    | a   | b         |

    ```swift
    // none of these render: ~~x~~ ==y== #z ^id [^fn]
    let s = "==not a highlight=="
    ```

    A block anchor line. ^block-id

    [^note]: The footnote definition, with ==highlight== in it.
    """

    /// Parsing must not rewrite, normalise or reorder a single byte.
    func test_modelDoesNotMutateTheSource() {
        let model = MarkdownDocumentModel(body: document)
        _ = model.extensionSpans
        XCTAssertEqual(model.fullText, document)
    }

    /// CRLF is the classic corruption: `"\r\n"` is ONE Character and TWO
    /// UTF-16 units, so any pass doing Character arithmetic silently eats a
    /// byte on a Windows-authored vault — which Obsidian users have.
    func test_crlfDocumentSurvivesUnchanged() {
        let crlf = document.replacingOccurrences(of: "\n", with: "\r\n")
        let model = MarkdownDocumentModel(body: crlf)
        _ = model.extensionSpans
        XCTAssertEqual(model.fullText, crlf)
    }

    /// Every emitted span must address real text. A span that runs past the
    /// end, or inverts, is a crash or a wrong collapse the moment Live
    /// Preview hides the markers — and it would hide the user's own content.
    func test_everySpanIsWithinBounds() {
        for source in [document, document.replacingOccurrences(of: "\n", with: "\r\n")] {
            let model = MarkdownDocumentModel(body: source)
            let length = (source as NSString).length
            for span in model.extensionSpans {
                XCTAssertLessThanOrEqual(span.range.upperBound, length,
                                         "span \(span.kind) runs past the end")
                XCTAssertLessThanOrEqual(span.range.lowerBound, span.range.upperBound,
                                         "span \(span.kind) is inverted")
                XCTAssertTrue(span.range.lowerBound <= span.content.lowerBound
                              && span.content.upperBound <= span.range.upperBound,
                              "span \(span.kind) content escapes its own range")
            }
        }
    }

    /// The code fence is the suppression contract: nothing inside it renders,
    /// so nothing inside it may be collapsed.
    func test_noSpanFallsInsideTheCodeFence() {
        let ns = document as NSString
        let fenceStart = ns.range(of: "```swift").location
        let fenceEnd = ns.range(of: "```", options: .backwards).location + 3
        XCTAssertNotEqual(fenceStart, NSNotFound)

        let model = MarkdownDocumentModel(body: document)
        for span in model.extensionSpans {
            let insideFence = span.range.lowerBound >= fenceStart && span.range.upperBound <= fenceEnd
            XCTAssertFalse(insideFence, "\(span.kind) span emitted inside the code fence")
        }
    }

    /// M7's headline claim, for embed-bearing documents specifically: adding
    /// `![[…]]` transclusion syntax must not give the editor a new way to
    /// write to the host document. If this fails, transclusion is mutating
    /// the host text — a stop-the-world defect, not something to work
    /// around.
    func test_aDocumentWithEmbedsStillRoundTrips() {
        let source = """
        # Host

        ![[target]]

        ![[target#heading]]

        ![[target#^anchor]]

        Prose after.
        """
        let model = MarkdownDocumentModel(body: source)
        _ = model.styleSpans
        XCTAssertEqual(model.fullText, source)
    }

    /// Pins the code-fence suppression for embeds specifically: M6 built the
    /// code mask, and this proves transclusion honours it rather than
    /// re-deriving its own (possibly disagreeing) notion of "inside a fence".
    func test_noTransclusionIsEmittedInsideACodeFence() {
        let source = """
        Real one:

        ![[target]]

        ```markdown
        ![[not-an-embed]]
        ```
        """
        let model = MarkdownDocumentModel(body: source)
        let ns = source as NSString
        let fenceStart = ns.range(of: "```markdown").location
        let fenceEnd = ns.range(of: "```", options: .backwards).location + 3

        for span in model.styleSpans where span.isTransclusionEmbed {
            let inside = span.range.lowerBound >= fenceStart
                && span.range.upperBound <= fenceEnd
            XCTAssertFalse(inside, "a fenced ![[…]] was treated as a transclusion")
        }
    }
}
