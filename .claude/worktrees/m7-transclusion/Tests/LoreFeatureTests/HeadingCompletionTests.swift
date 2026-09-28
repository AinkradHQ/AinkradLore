import XCTest
@testable import LoreFeature

/// `[[Doc#…]]` heading completion.
@MainActor
final class HeadingCompletionTests: XCTestCase {

    // MARK: - Recognising the query

    func test_ahashSplitsTheDocumentFromTheHeading() {
        let query = LinkCompletionContext.headingQuery(inPrefix: "Design#over")
        XCTAssertEqual(query?.document, "Design")
        XCTAssertEqual(query?.heading, "over")
    }

    /// No `#` typed yet means an ordinary document query.
    func test_noHashIsNotAHeadingQuery() {
        XCTAssertNil(LinkCompletionContext.headingQuery(inPrefix: "Design"))
    }

    /// The `#` alone, immediately after it, is a heading query with an empty
    /// filter — which is what lets the popup list ALL of a document's headings
    /// the moment `#` is typed.
    func test_abareHashListsEverything() {
        let query = LinkCompletionContext.headingQuery(inPrefix: "Design#")
        XCTAssertEqual(query?.document, "Design")
        XCTAssertEqual(query?.heading, "")
    }

    /// A fragment with no document names nothing to look inside.
    func test_ahashWithNoDocumentIsNotAQuery() {
        XCTAssertNil(LinkCompletionContext.headingQuery(inPrefix: "#over"))
        XCTAssertNil(LinkCompletionContext.headingQuery(inPrefix: "   #over"))
    }

    /// Split on the FIRST `#`: markdown headings can contain `#` and the
    /// fragment syntax has no escape for it, so `Doc#C# notes` asks for the
    /// heading "C# notes" — the only reading that lets such a heading be
    /// linked at all.
    func test_alaterHashBelongsToTheHeading() {
        let query = LinkCompletionContext.headingQuery(inPrefix: "Doc#C# notes")
        XCTAssertEqual(query?.document, "Doc")
        XCTAssertEqual(query?.heading, "C# notes")
    }

    // MARK: - Looking the headings up

    private func vault(_ label: String) throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    private func write(_ root: URL, _ name: String, _ body: String) throws {
        try "---\nid: \(name)\ntitle: \(name)\n---\n\(body)"
            .write(to: root.appendingPathComponent("\(name).md"),
                   atomically: true, encoding: .utf8)
    }

    func test_headingsComeBackForANamedDocument() async throws {
        let (root, store) = try vault("headings")
        try write(root, "Design", "# Overview\n\ntext\n\n## Deployment and rollback\n\nmore")
        await store.settleForTesting(); try store.rebuild()

        let found = try XCTUnwrap(store.headingCompletions(inDocumentNamed: "Design",
                                                          matching: ""))
        XCTAssertEqual(found.headings, ["Overview", "Deployment and rollback"])
    }

    /// Substring, not prefix: headings are sentences, and the word worth
    /// typing is often not the first one.
    func test_filteringMatchesAnywhereInTheHeading() async throws {
        let (root, store) = try vault("headings-filter")
        try write(root, "Design", "# Overview\n\n## Deployment and rollback")
        await store.settleForTesting(); try store.rebuild()

        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "Design",
                                                matching: "rollback")?.headings,
                       ["Deployment and rollback"])
        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "Design",
                                                matching: "ROLL")?.headings.count, 1,
                       "matching must ignore case")
    }

    /// A name still being typed resolves to nothing, which is ordinary rather
    /// than an error.
    func test_anUnresolvableNameYieldsNothing() async throws {
        let (_, store) = try vault("headings-missing")
        await store.settleForTesting()
        XCTAssertNil(store.headingCompletions(inDocumentNamed: "Nope", matching: ""))
    }

    func test_adocumentWithNoHeadingsYieldsNothing() async throws {
        let (root, store) = try vault("headings-none")
        try write(root, "Flat", "just prose, no headings at all")
        await store.settleForTesting(); try store.rebuild()
        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "Flat", matching: "")?.headings,
                       [])
    }

    /// The cache is per DOCUMENT: switching the named document must not keep
    /// serving the previous one's headings.
    func test_theCacheFollowsTheNamedDocument() async throws {
        let (root, store) = try vault("headings-cache")
        try write(root, "First", "# Alpha")
        try write(root, "Second", "# Beta")
        await store.settleForTesting(); try store.rebuild()

        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "First", matching: "")?.headings,
                       ["Alpha"])
        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "Second", matching: "")?.headings,
                       ["Beta"])
        XCTAssertEqual(store.headingCompletions(inDocumentNamed: "First", matching: "")?.headings,
                       ["Alpha"], "switching back must not serve the other document")
    }

    /// The link written must reach the document whose headings were OFFERED.
    ///
    /// Two notes can share a title in different folders: `resolveLink` picks
    /// one by preference and the popup lists its headings, so writing the
    /// TYPED name would produce a link that may later resolve to the namesake
    /// — which does not have that heading. The document-completion path has
    /// always inserted a resolver-verified target; this is the same guarantee
    /// for the fragment path.
    func test_theInsertTargetDistinguishesNamesakes() async throws {
        let (root, store) = try vault("headings-namesake")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try write(root, "Design", "# Current overview")
        try "---\nid: old\ntitle: Design\n---\n# Old overview"
            .write(to: root.appendingPathComponent("Archive/Design.md"),
                   atomically: true, encoding: .utf8)
        await store.settleForTesting(); try store.rebuild()

        let found = try XCTUnwrap(store.headingCompletions(inDocumentNamed: "Design",
                                                           matching: ""))
        // Whichever the resolver preferred, the target must resolve back to
        // THAT file — not merely repeat what was typed and hope.
        let resolved = try XCTUnwrap(store.resolveLink(found.insertTarget))
        let offeringOverview = found.headings.first
        let contents = try String(contentsOf: resolved, encoding: .utf8)
        XCTAssertTrue(contents.contains(try XCTUnwrap(offeringOverview)),
                      "the inserted target reaches a document without the heading offered")
    }

    // MARK: - The rows it produces

    func test_aheadingRowReadsAsTheHeading() {
        XCTAssertEqual(LinkCompletionItem.heading(document: "Design", text: "Overview").label,
                       "Overview")
    }
}
