import XCTest
@testable import LoreFeature

/// The SAVE path, measured the way `MarkdownStylingBenchmark` measures the
/// keystroke path.
///
/// This benchmark exists because its absence is how the defect survived twelve
/// gates. Task 10 measured keystrokes → parses and found zero; nobody measured
/// what happens 500 ms later when the debounced autosave fires, and by then
/// `indexPayload` had become two full AST parses and `saveNow` was computing it
/// twice — four parses on the main actor, on a path that used to be two cheap
/// hand scans.
///
/// MEASURED, Debug (unoptimised), 2026-07-30, ~255 KB body, Apple silicon.
/// `xcodebuild` wall-clock averages over 10 iterations:
///
///                          BEFORE               AFTER              speed-up
///   `indexPayload`         0.943 s (2 parses)   0.506 s (rsd 0.7%)   1.9×
///   the save path total    1.885 s (4 parses)   0.516 s (rsd 3.6%)   3.7×
///   one parse (the floor)                       0.447 s (rsd 1.3%)
///
/// The save-path BEFORE is `test_before_theSavePathWithFourUnsharedParses`
/// measured directly (1.885 s, rsd 0.7%); the `indexPayload` BEFORE is half of
/// it, because `test_before_indexPayloadWithTwoUnsharedParses` came back at
/// 55% rsd on this machine — its stable mode was 0.96 s, agreeing with the
/// halved figure, but the noisy run is not the number to quote.
///
/// AFTER now sits ~0.06 s above the one-parse floor, which is the payload's
/// non-parse work (the link scan over the shared index, ~0.05 s by
/// `MarkdownStylingBenchmark.test_theWikilinkScanAlone`). There is no second
/// parse left to remove.
///
/// The parse COUNTS, which do not vary with hardware and are what actually
/// regressed, are asserted in `M2aSavePathParseCountTests` — a timing here that
/// drifts on faster silicon still cannot hide a reintroduced double parse.
final class MarkdownSavePathBenchmark: XCTestCase {

    /// ~230 KB with links, code spans and headings — everything both halves of
    /// `indexPayload` have to walk.
    static var largeBody: String {
        String(repeating: "# H\n\nSome **bold** text with a [[Link]] and `code`.\n\n",
               count: 5_000)
    }

    private func engine(_ body: String) throws -> MarkdownEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID()).md")
        try "---\nid: a\ntitle: T\n---\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        return try MarkdownEngine.load(url)
    }

    /// One `indexPayload`. Was two parses (outline + `LinkParser.links`, which
    /// built its own model); is one.
    func test_indexPayloadOnALargeNote() throws {
        let engine = try engine(Self.largeBody)
        measure { _ = engine.indexPayload }
    }

    /// What `DocumentSession.write()` actually does after a debounce: refresh
    /// the cached title, then hand the engine to the coordinator to index. Both
    /// halves used to build a full payload.
    func test_theSavePathsDerivationOnALargeNote() throws {
        let engine = try engine(Self.largeBody)
        measure {
            _ = engine.indexTitle
            _ = engine.indexPayload
        }
    }

    /// The floor the two above are measured against: one parse of the same
    /// fixture. `indexPayload` should now sit on it.
    func test_oneParseOfTheSameFixture() throws {
        let body = Self.largeBody
        measure { _ = MarkdownDocumentModel(body: body).outline }
    }

    // MARK: - BEFORE

    /// The BEFORE number, written out as code rather than quoted from a report
    /// — this is verbatim what `indexPayload` used to do, and it still compiles,
    /// so the comparison can be re-run rather than trusted.
    func test_before_indexPayloadWithTwoUnsharedParses() throws {
        let body = Self.largeBody
        measure {
            _ = MarkdownDocumentModel(body: body).outline
            _ = LinkParser.links(in: body)
        }
    }

    /// And the BEFORE for the whole save path: `cachedTitle =
    /// engine.indexPayload.title` followed by `indexDocument`, which read
    /// `indexPayload` again.
    func test_before_theSavePathWithFourUnsharedParses() throws {
        let body = Self.largeBody
        measure {
            for _ in 0..<2 {
                _ = MarkdownDocumentModel(body: body).outline
                _ = LinkParser.links(in: body)
            }
        }
    }
}
