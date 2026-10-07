import XCTest

@testable import LoreFeature

@MainActor
final class RelatedNotesTests: XCTestCase {
    private func note(_ root: URL, _ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    /// Linked-to beats shared-citation beats shared-tag; backlinks, the note
    /// itself and unconnected notes are left out.
    func test_relatedNotes_scoresLinksCitationsAndTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-rel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try note(root, "me", "---\ntitle: Me\ntags: [mail]\n---\nsee [[Target]] and [[Hub]]")
        try note(root, "target", "---\ntitle: Target\n---\nplain")
        try note(root, "hub", "---\ntitle: Hub\n---\nplain")
        try note(root, "cites", "---\ntitle: Cites\n---\nalso [[Hub]]")
        try note(root, "tagged", "---\ntitle: Tagged\ntags: [mail]\n---\nplain")
        try note(root, "fan", "---\ntitle: Fan\n---\nlinks [[Me]]")
        try note(root, "stranger", "---\ntitle: Stranger\n---\nnothing")

        let store = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        await store.settleForTesting()
        try store.rebuild()
        // The link-and-tag half, deterministically: no meaning scores mixed in.
        await store.coordinator.settleEmbeddingsForTesting()
        store.coordinator.embeddings = [:]

        let me = try XCTUnwrap(store.rows.first { $0.title == "Me" })
        let titles = store.relatedNotes(to: me.path).map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)).sorted(), ["Hub", "Target"])  // 3 each
        XCTAssertEqual(Array(titles.dropFirst(2)), ["Cites", "Tagged"])  // 2, then 1
    }
}
