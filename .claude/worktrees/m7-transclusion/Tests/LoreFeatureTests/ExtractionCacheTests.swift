import XCTest
@testable import LoreFeature

final class ExtractionCacheTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-cache-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("f.bin")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    override func setUp() { ExtractionCache.shared.removeAll() }

    func test_secondCallForAnUnchangedFile_doesNotReExtract() throws {
        let url = try tempFile("hello")
        var calls = 0
        let first = ExtractionCache.shared.text(for: url) { calls += 1; return "extracted" }
        let second = ExtractionCache.shared.text(for: url) { calls += 1; return "extracted" }
        XCTAssertEqual(first, "extracted")
        XCTAssertEqual(second, "extracted")
        XCTAssertEqual(calls, 1)
    }

    func test_changedFile_reExtracts() throws {
        let url = try tempFile("hello")
        var calls = 0
        _ = ExtractionCache.shared.text(for: url) { calls += 1; return "one" }
        // Rewrite with different content AND a later mtime.
        try "hello there".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let again = ExtractionCache.shared.text(for: url) { calls += 1; return "two" }
        XCTAssertEqual(again, "two")
        XCTAssertEqual(calls, 2)
    }

    func test_isBounded() throws {
        for i in 0..<(ExtractionCache.maxEntries + 50) {
            let url = try tempFile("f\(i)")
            _ = ExtractionCache.shared.text(for: url) { "x" }
        }
        XCTAssertLessThanOrEqual(ExtractionCache.shared.count, ExtractionCache.maxEntries)
    }

    /// Decision 2's regression test: both `PDFEngine` and `RichTextEngine`
    /// derive `isContentTruncated` by comparing raw text against capped text
    /// at extraction time. If the cache stored only the capped string, a
    /// cache HIT would have no raw text left to compare against, and a
    /// truncated document would start silently reporting
    /// `isContentTruncated == false` on the second scan. This proves the
    /// truncation flag, cached alongside the text via
    /// `ExtractionCache.ExtractionResult`, stays truthful on a hit.
    func test_truncationFlag_staysTruthfulOnCacheHit() throws {
        let url = try tempFile("hello")
        var calls = 0

        let first = ExtractionCache.shared.result(for: url) {
            calls += 1
            return ExtractionCache.ExtractionResult(text: "capped-text", isTruncated: true)
        }
        XCTAssertEqual(first.text, "capped-text")
        XCTAssertTrue(first.isTruncated)
        XCTAssertEqual(calls, 1)

        // Second call for the SAME unchanged file: must hit the cache (no
        // second extraction) AND must still report the truncation flag
        // correctly — not silently default to false because the raw text
        // used to compute it is long gone.
        let second = ExtractionCache.shared.result(for: url) {
            calls += 1
            return ExtractionCache.ExtractionResult(text: "capped-text", isTruncated: true)
        }
        XCTAssertEqual(second.text, "capped-text")
        XCTAssertTrue(second.isTruncated, "cache hit must not lose the truncation flag")
        XCTAssertEqual(calls, 1, "a cache hit must not re-run extraction")

        // And a document that was NOT truncated must not somehow start
        // reporting true on a hit, either — the flag round-trips both ways.
        let untruncatedURL = try tempFile("short")
        let untruncated = ExtractionCache.shared.result(for: untruncatedURL) {
            ExtractionCache.ExtractionResult(text: "short", isTruncated: false)
        }
        let untruncatedAgain = ExtractionCache.shared.result(for: untruncatedURL) {
            XCTFail("should have hit the cache")
            return ExtractionCache.ExtractionResult(text: "short", isTruncated: true)
        }
        XCTAssertFalse(untruncated.isTruncated)
        XCTAssertFalse(untruncatedAgain.isTruncated)
    }
}
