import XCTest
@testable import LoreFeature

final class InlineTagTests: XCTestCase {

    func test_inlineTags_extractedFromBody() {
        let model = MarkdownDocumentModel(body: "A note about #ainkrad and #design.")
        XCTAssertEqual(model.inlineTags.sorted(), ["ainkrad", "design"])
    }

    func test_inlineTags_deduplicatedWithinBody() {
        let model = MarkdownDocumentModel(body: "#idea and again #idea")
        XCTAssertEqual(model.inlineTags, ["idea"])
    }

    func test_inlineTags_excludeHeadingsAndCode() {
        let model = MarkdownDocumentModel(body: "# Heading\n```\n#notatag\n```\n#real")
        XCTAssertEqual(model.inlineTags, ["real"])
    }

    func test_indexPayload_mergesFrontmatterAndInlineTags() throws {
        let engine = try engine(tags: ["project"], body: "Body with #design in it.")
        XCTAssertEqual(engine.indexPayload.tags, ["design", "project"])
    }

    func test_indexPayload_deduplicatesAcrossFrontmatterAndBody() throws {
        // A note tagged both ways must count ONCE, or `tagCounts` double-counts
        // it in the sidebar chip row.
        let engine = try engine(tags: ["design"], body: "Body with #design in it.")
        XCTAssertEqual(engine.indexPayload.tags, ["design"])
    }

    /// Writes a temp `.md` file with real frontmatter and loads it through
    /// `MarkdownEngine.load(url:)` — the house pattern for constructing a test
    /// engine (see `MarkdownSavePathBenchmark.engine(_:)`), not a hand-built
    /// `Note`. `MarkdownEngine.init(note:)` stays `private`: loading from disk
    /// also exercises `Frontmatter.parse`, the very parse that produces
    /// `note.tags`, the input this task's merge combines with `inlineTags`.
    private func engine(tags: [String], body: String) throws -> MarkdownEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-tag-\(UUID()).md")
        let tagList = tags.map { "  - \($0)" }.joined(separator: "\n")
        let frontmatter = tags.isEmpty
            ? "---\nid: a\ntitle: T\n---\n"
            : "---\nid: a\ntitle: T\ntags:\n\(tagList)\n---\n"
        try (frontmatter + body).write(to: url, atomically: true, encoding: .utf8)
        return try MarkdownEngine.load(url)
    }
}
