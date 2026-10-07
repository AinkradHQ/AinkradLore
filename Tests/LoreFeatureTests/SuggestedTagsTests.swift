import XCTest

@testable import LoreFeature

@MainActor
final class SuggestedTagsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-tags-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func note(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }
    private func store() async throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        await s.settleForTesting()
        try s.rebuild()
        return s
    }

    /// A vault tag named in the text comes first; tags already on the note
    /// never appear; nothing is written by suggesting.
    func test_suggestsVaultTagsNamedInTheNote() async throws {
        try note("other", "---\ntitle: Other\ntags: [release-notes, mail]\n---\nx")
        try note("me", "---\ntitle: Me\ntags: [mail]\n---\nDrafting the release notes for 0.21.")
        let s = try await store()
        let me = try XCTUnwrap(s.rows.first { $0.title == "Me" })
        let before = try String(contentsOf: me.path, encoding: .utf8)
        let tags = s.suggestedTags(for: me.path)
        XCTAssertEqual(tags.first, "release-notes")
        XCTAssertFalse(tags.contains("mail"))
        XCTAssertEqual(try String(contentsOf: me.path, encoding: .utf8), before)
    }

    func test_repeatedNounsNeedThreeUses() {
        let nouns = LoreStore.repeatedNouns(in: "The garden. A garden grows. My garden. One river.")
        XCTAssertEqual(nouns, ["garden"])
    }

    func test_addTag_writesFrontmatterAndReindexes() async throws {
        try note("me", "---\ntitle: Me\ntags: [mail]\n---\nbody")
        let s = try await store()
        let me = try XCTUnwrap(s.rows.first { $0.title == "Me" })
        try s.addTag("release-notes", to: me.path)
        XCTAssertEqual(s.rows.first { $0.title == "Me" }?.tags.sorted(), ["mail", "release-notes"])
        XCTAssertTrue(try String(contentsOf: me.path, encoding: .utf8).contains("release-notes"))
    }
}
