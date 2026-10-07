import NaturalLanguage
import XCTest

@testable import LoreFeature

@MainActor
final class SemanticSearchTests: XCTestCase {
    /// A query sharing no word with a note still finds it by meaning, after
    /// the keyword hits — and an unrelated note is not dragged in.
    func test_searchFindsANoteByMeaning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-sem-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\ntitle: Inbox\n---\nReading and answering my mail messages every morning."
            .write(to: root.appendingPathComponent("inbox.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Bread\n---\nBaking sourdough with a long cold proof."
            .write(to: root.appendingPathComponent("bread.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Email rules\n---\nfilters for email"
            .write(to: root.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)

        let store = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        await store.settleForTesting()
        await store.coordinator.settleEmbeddingsForTesting()
        try XCTSkipIf(LoreEmbeddings.model() == nil, "no English sentence embedding on this machine")
        XCTAssertEqual(store.coordinator.embeddings.count, 3)

        let titles = store.search("email inbox").map(\.title)
        XCTAssertEqual(titles.first, "Email rules", "keyword hits stay first")
        XCTAssertTrue(titles.contains("Inbox"), "a note about mail was not found by meaning")
        XCTAssertFalse(titles.contains("Bread"))
    }

    func test_unknownWordsGetNoMeaningResults() throws {
        let vocabulary = try XCTUnwrap(NLEmbedding.wordEmbedding(for: .english))
        XCTAssertFalse(LoreEmbeddings.hasKnownWord("zorkmid", vocabulary: vocabulary))
        XCTAssertTrue(LoreEmbeddings.hasKnownWord("zorkmid mail", vocabulary: vocabulary))
    }

    func test_cosine() {
        XCTAssertEqual(LoreEmbeddings.cosine([1, 0], [1, 0]), 1)
        XCTAssertEqual(LoreEmbeddings.cosine([1, 0], [0, 1]), 0)
        XCTAssertEqual(LoreEmbeddings.cosine([0, 0], [1, 0]), 0)
    }
}
