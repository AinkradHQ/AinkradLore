import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Bound 5: a rename parses each document at most once.
@MainActor
final class RenameParseCountBenchmark: XCTestCase {

    /// `LinkRewriter.replacingLinkTargets` scans a document ONCE and replaces
    /// every span from that one scan. Rebuilding the model per link — which is
    /// what a `replacingOccurrences`-per-edit shape would do — would make a
    /// rename O(links) parses of every inbound file.
    func test_rewritingManyLinksInOneDocumentParsesItOnce() {
        let body =
            "---\nid: a\ntitle: A\n---\n"
            + (0..<200).map { "see [[Design]] and [[Other \($0)]]\n" }.joined()
        let edits = [
            LinkEdit(
                file: URL(fileURLWithPath: "/tmp/a.md"),
                oldTarget: "Design", newTarget: "Architecture")
        ]
        resetParseCounter()
        let out = LinkRewriter.replacingLinkTargets(in: body, edits: edits)
        XCTAssertEqual(
            MarkdownParseCounter.count, 1,
            "200 rewritten links must cost one parse, not 200")
        XCTAssertEqual(out.components(separatedBy: "[[Architecture]]").count - 1, 200)
        XCTAssertFalse(out.contains("[[Design]]"))
    }

    /// And across documents: N inbound files cost N parses in the rewrite, not
    /// N × links.
    func test_rewritingManyDocumentsParsesEachOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename-perf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [URL] = []
        for index in 0..<8 {
            let url = root.appendingPathComponent("n\(index).md")
            try
                ("---\nid: n\(index)\ntitle: N\(index)\n---\n"
                + String(repeating: "see [[Design]]\n", count: 25))
                .write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        let baseline = Date().addingTimeInterval(60)

        resetParseCounter()
        for file in files {
            let edit = LinkEdit(
                file: file, oldTarget: "Design",
                newTarget: "Architecture")
            XCTAssertEqual(
                try LinkRewriter.applyEdits([edit], to: file, baseline: baseline),
                .written)
        }
        XCTAssertEqual(
            MarkdownParseCounter.count, files.count,
            "each document may be parsed at most once by the rewrite")
    }
}
