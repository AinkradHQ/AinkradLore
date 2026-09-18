import XCTest
@testable import LoreFeature

/// Search excerpts: the marker parsing, and the real thing through SQLite.
@MainActor
final class SearchSnippetTests: XCTestCase {

    private let open = SearchSnippet.open
    private let close = SearchSnippet.close

    // MARK: - Parsing

    func test_parseExtractsTextAndMatchRange() {
        let snippet = SearchSnippet.parse(marked: "the \(open)quick\(close) fox")
        XCTAssertEqual(snippet.text, "the quick fox")
        XCTAssertEqual(snippet.matches.count, 1)
        XCTAssertEqual(String(snippet.text[snippet.matches[0]]), "quick")
    }

    /// FTS returns one marked span per matched term, so several in one excerpt
    /// is the ordinary case, not an edge case.
    func test_parseHandlesSeveralMatches() {
        let snippet = SearchSnippet.parse(
            marked: "\(open)red\(close) and \(open)blue\(close)")
        XCTAssertEqual(snippet.text, "red and blue")
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["red", "blue"])
    }

    /// A match at the very start and one at the very end — the two positions
    /// where an off-by-one in the parse would be invisible in casual testing.
    func test_parseHandlesMatchesAtBothEnds() {
        let snippet = SearchSnippet.parse(marked: "\(open)a\(close)bc\(open)d\(close)")
        XCTAssertEqual(snippet.text, "abcd")
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["a", "d"])
    }

    func test_parseHandlesAdjacentMatches() {
        let snippet = SearchSnippet.parse(marked: "\(open)ab\(close)\(open)cd\(close)")
        XCTAssertEqual(snippet.text, "abcd")
        XCTAssertEqual(snippet.matches.map { String(snippet.text[$0]) }, ["ab", "cd"])
    }

    /// A malformed excerpt must degrade to "no highlight", never to "no
    /// result" — the row is still a genuine hit.
    func test_parseToleratesUnbalancedMarkers() {
        let dangling = SearchSnippet.parse(marked: "text \(open)unclosed")
        XCTAssertEqual(dangling.text, "text unclosed")
        XCTAssertTrue(dangling.matches.isEmpty)

        let orphanClose = SearchSnippet.parse(marked: "text\(close) more")
        XCTAssertEqual(orphanClose.text, "text more")
        XCTAssertTrue(orphanClose.matches.isEmpty)
    }

    func test_parseWithNoMarkersIsPlainText() {
        let snippet = SearchSnippet.parse(marked: "nothing special")
        XCTAssertEqual(snippet.text, "nothing special")
        XCTAssertTrue(snippet.matches.isEmpty)
    }

    // MARK: - Styled output

    /// Built by concatenation rather than by index translation, so text
    /// outside the BMP must survive intact — an emoji in a note is not exotic,
    /// and character-counting between `String.Index` and
    /// `AttributedString.Index` is exactly where that breaks.
    func test_attributedPreservesTextIncludingNonBMPCharacters() {
        let snippet = SearchSnippet.parse(marked: "🎉 \(open)party\(close) 🎉")
        let attributed = snippet.attributed { $0.inlinePresentationIntent = .stronglyEmphasized }
        XCTAssertEqual(String(attributed.characters), "🎉 party 🎉")
    }

    func test_attributedMarksOnlyTheMatchedRun() {
        let snippet = SearchSnippet.parse(marked: "a \(open)b\(close) c")
        let attributed = snippet.attributed { $0.inlinePresentationIntent = .stronglyEmphasized }
        let emphasised = attributed.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(emphasised, ["b"])
    }

    // MARK: - Through the real index

    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-snippet-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// The end-to-end promise: a body match comes back with an excerpt that
    /// contains the term, marked.
    func test_aBodyMatchComesBackWithAnExcerpt() async throws {
        let (root, store) = try vault()
        try """
        ---
        id: a
        title: Alpha
        ---
        The quick brown fox jumps over the lazy dog and keeps going for a while.
        """.write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        await store.settleForTesting(); try store.rebuild()

        let hits = store.searchHits("brown")
        let hit = try XCTUnwrap(hits.first { $0.row.path.lastPathComponent == "a.md" })
        let snippet = try XCTUnwrap(hit.snippet, "a body match must carry an excerpt")
        XCTAssertTrue(snippet.text.lowercased().contains("brown"))
        XCTAssertFalse(snippet.matches.isEmpty, "the excerpt must mark what matched")
    }

    /// A title-only match carries NO excerpt: the title is already the row's
    /// headline, and FTS would otherwise hand back a leading fragment of the
    /// body as though it were the reason for the match.
    func test_aTitleOnlyMatchCarriesNoExcerpt() async throws {
        let (root, store) = try vault()
        try """
        ---
        id: z
        title: Zebra
        ---
        Body text that does not contain the search term at all.
        """.write(to: root.appendingPathComponent("z.md"), atomically: true, encoding: .utf8)
        await store.settleForTesting(); try store.rebuild()

        let hits = store.searchHits("Zebra")
        let hit = try XCTUnwrap(hits.first { $0.row.path.lastPathComponent == "z.md" })
        XCTAssertNil(hit.snippet)
    }

    /// The FTS-expression hardening still applies on this path: a query with
    /// operator characters must not throw its way to an empty list.
    func test_punctuationInAQueryStillReturnsHits() async throws {
        let (root, store) = try vault()
        try """
        ---
        id: c
        title: Config
        ---
        The setting size: 3 is documented here.
        """.write(to: root.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        await store.settleForTesting(); try store.rebuild()

        XCTAssertFalse(store.searchHits("size: 3").isEmpty,
                       "a colon made search look broken before ftsExpression existed")
    }

    /// Hits and plain search must agree on WHICH documents matched — they are
    /// the same query, and a sidebar that showed a different set from the one
    /// the rest of the app resolves would be its own bug.
    func test_hitsAgreeWithPlainSearch() async throws {
        let (root, store) = try vault()
        for name in ["one", "two", "three"] {
            try "---\nid: \(name)\ntitle: \(name)\n---\nshared term here"
                .write(to: root.appendingPathComponent("\(name).md"),
                       atomically: true, encoding: .utf8)
        }
        await store.settleForTesting(); try store.rebuild()

        let plain = Set(store.search("shared").map(\.path))
        let hits = Set(store.searchHits("shared").map(\.row.path))
        XCTAssertEqual(plain, hits)
        XCTAssertEqual(plain.count, 3)
    }
}
