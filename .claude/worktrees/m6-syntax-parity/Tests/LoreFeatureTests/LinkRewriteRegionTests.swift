import XCTest
@testable import LoreFeature

/// Which REGIONS of a file a rewrite is allowed to touch, and how a
/// percent-encoded markdown link survives a rename.
///
/// A separate file from `LinkRewriterTests.swift` on purpose: that file is
/// already 927 lines, over the project's 500-line ceiling, and adding to it
/// would make a standing breach worse. Everything here is new material, so it
/// starts in its own file rather than being appended to that one.
@MainActor
final class LinkRewriteRegionTests: XCTestCase {

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-regions-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    private func mtime(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }

    // MARK: - Code regions and frontmatter are not links

    /// THE regression test for the fence-blind rewriter: one real link in a
    /// file used to drag every `[[Design]]` written inside a code block, inside
    /// inline code, and inside the frontmatter along with it — unrequested
    /// mutation of a file the user never opened, with no undo.
    func test_renameRewritesOnlyRealLinksAndLeavesCodeAndFrontmatterByteIdentical() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("a.md")
        let text = """
        ---
        id: a
        title: A
        note: see [[Design]] in the properties
        ---
        A real link to [[Design]].

        Inline code: `[[Design]]` is how you write one.

        ```
        [[Design]]
        ```

        ~~~markdown
        [[Design]]
        ~~~
        """
        try text.write(to: file, atomically: true, encoding: .utf8)

        let outcome = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture")],
            to: file, baseline: try mtime(of: file))
        XCTAssertEqual(outcome, .written)

        let after = try String(contentsOf: file, encoding: .utf8)
        // Exactly one occurrence changed…
        XCTAssertEqual(after.components(separatedBy: "[[Architecture]]").count - 1, 1)
        XCTAssertTrue(after.contains("A real link to [[Architecture]]."))
        // …and every excluded region is byte-identical to what was written.
        XCTAssertTrue(after.contains("note: see [[Design]] in the properties"))
        XCTAssertTrue(after.contains("Inline code: `[[Design]]` is how you write one."))
        XCTAssertTrue(after.contains("```\n[[Design]]\n```"))
        XCTAssertTrue(after.contains("~~~markdown\n[[Design]]\n~~~"))
    }

    /// A file whose ONLY `[[Design]]` sits in a code block has nothing to
    /// rewrite: it must be reported `unchanged`, and not rewritten to bump its
    /// mtime for nothing.
    func test_aLinkOnlyInsideAFenceIsNotAnEditAtAll() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("b.md")
        let text = "Docs:\n\n```\n[[Design]]\n```\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        let outcome = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture")],
            to: file, baseline: try mtime(of: file))
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }

    /// Aliases, embeds and fragments still rewrite — the range replacement
    /// covers the TARGET only, so the display half is untouched.
    func test_realLinksOfEverySyntaxStillRewrite() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("c.md")
        try "[[Design|why it looks like that]] ![[Design]] [[Design#Overview]] [t](Design.md)"
            .write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture"),
             LinkEdit(file: file, oldTarget: "Design#Overview",
                      newTarget: "Architecture#Overview"),
             LinkEdit(file: file, oldTarget: "Design.md", newTarget: "Architecture.md")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "[[Architecture|why it looks like that]] ![[Architecture]] "
                       + "[[Architecture#Overview]] [t](Architecture.md)")
    }

    /// Two edits in one file whose replacements differ in length: the spans are
    /// applied back to front precisely so the second one's offsets are still
    /// valid after the first one shifts the text.
    func test_multipleEditsOfDifferentLengthsAllLandCorrectly() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("d.md")
        try "[[A]] then [[B]] then [[A]]".write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "A", newTarget: "A Much Longer Name"),
             LinkEdit(file: file, oldTarget: "B", newTarget: "C")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "[[A Much Longer Name]] then [[C]] then [[A Much Longer Name]]")
    }

    // MARK: - Percent-encoded markdown links

    func test_parserDecodesMarkdownTargetsForResolutionButStoresThemRaw() {
        let link = LinkParser.links(in: "see [text](Design%20Doc.md)").first
        XCTAssertEqual(link?.rawTarget, "Design%20Doc.md")      // for rewriting
        XCTAssertEqual(link?.resolutionTarget, "Design Doc.md") // for resolution
    }

    /// Obsidian never percent-encodes a wikilink target, so a `%` inside one is
    /// a literal `%` in a filename. Decoding it would resolve the link to the
    /// wrong document, or to none.
    func test_wikilinkTargetsAreNeverPercentDecoded() {
        let link = LinkParser.links(in: "see [[100%20off]]").first
        XCTAssertEqual(link?.rawTarget, "100%20off")
        XCTAssertEqual(link?.resolutionTarget, "100%20off")
    }

    /// End to end, on a real vault: the encoded link resolves, contributes a
    /// backlink, and is rewritten — re-encoded in the author's own style —
    /// when its target is renamed.
    func test_anEncodedMarkdownLinkResolvesBacklinksAndSurvivesARename() async throws {
        let root = tempDir()
        let s = try makeStore(root)
        let target = root.appendingPathComponent("Design Doc.md")
        try "---\nid: d\ntitle: Design Doc\n---\nbody"
            .write(to: target, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [the doc](Design%20Doc.md)"
            .write(to: source, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        // Criterion 1/3: it resolves, so it is a backlink rather than a
        // `target_path NULL` orphan.
        XCTAssertEqual(s.inboundLinkCount(to: target), 1)
        XCTAssertEqual(s.backlinks(to: target).map { $0.row.title }, ["A"])

        let row = s.rows.first { $0.path.lastPathComponent == "Design Doc.md" }!
        let plan = s.plan(rename: row.path, to: "Spec Sheet")
        XCTAssertNil(plan.refusal)
        let report = s.apply(plan)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty)

        // Rewritten, and written back in the SAME encoded style the author used.
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8),
                       "---\nid: a\ntitle: A\n---\nsee [the doc](Spec%20Sheet.md)")
    }

    /// SUPERSEDES an earlier assertion that a raw space stayed raw. It did, and
    /// that was the interop break: CommonMark and Obsidian both END a link
    /// destination at an unencoded space, so `[t](Spec Sheet.md)` is not a link
    /// to `Spec Sheet.md` anywhere except inside Lore. Encoding is now driven by
    /// what the NEW target needs, not by how the old one was spelled.
    func test_aRewriteEncodesASpaceEvenWhenTheOriginalWasUnencoded() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("e.md")
        try "[t](Design Doc.md)".write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design Doc.md", newTarget: "Spec Sheet.md")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[t](Spec%20Sheet.md)")
    }

    /// An encoded link that needs no change must not be "normalised" to its
    /// decoded form — that would be a content mutation dressed up as a rename.
    func test_anEncodedLinkThatNeedsNoChangeProducesNoEdit() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design Doc.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design Doc.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/a.md"), "Design%20Doc", .markdown)],
            vaultRoot: URL(fileURLWithPath: "/v"))
        // Bare target, no extension: a move leaves it resolving by basename.
        XCTAssertTrue(plan.edits.isEmpty)
    }
}
