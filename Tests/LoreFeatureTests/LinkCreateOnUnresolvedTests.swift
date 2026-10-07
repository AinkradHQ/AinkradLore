import XCTest

@testable import LoreFeature

/// The "this link points nowhere — create it?" path.
@MainActor
final class LinkCreateOnUnresolvedTests: XCTestCase {
    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-create-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(
            documents: FakeDocs(),
            indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// A real containment check: the note's directory must resolve to something
    /// under the vault root, not merely end in a same-named component.
    private func assertInsideVault(
        _ url: URL, _ root: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(
            path.hasPrefix(rootPath + "/"),
            "\(path) is not inside \(rootPath)", file: file, line: line)
    }

    /// `[[Projects/Design]]` used to fail silently: `create` slugged the whole
    /// thing to `projects/design` and wrote into a folder that did not exist.
    func test_createsTheSubfolderNamedByTheLink() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "Projects")
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "Projects")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        assertInsideVault(note.path, root)
        // The whole point: the link the user clicked now resolves.
        XCTAssertEqual(store.resolveLink("Projects/Design"), note.path)
    }

    /// Path arithmetic is not containment. A symlinked folder inside the vault
    /// — ordinary in Obsidian setups — would otherwise let
    /// `withIntermediateDirectories` follow it and write outside the root.
    func test_symlinkedSubfolderCannotEscapeTheVault() throws {
        let (root, store) = try store()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("out"),
            withDestinationURL: outside)

        XCTAssertThrowsError(try store.create(title: "Design", in: "out")) { error in
            guard case .outsideVault(let url) = error as? LoreError ?? .noVault else {
                return XCTFail("expected .outsideVault, got \(error)")
            }
            // Compared by suffix, not by whole URL: the store canonicalises the
            // vault root (`/var` → `/private/var`), so the two spellings of the
            // same directory are not `==`.
            XCTAssertTrue(
                url.standardizedFileURL.path.hasSuffix("/out"),
                "the error must name the offending directory, got \(url.path)")
        }
        XCTAssertTrue(
            try FileManager.default
                .contentsOfDirectory(atPath: outside.path).isEmpty,
            "nothing may be written through the symlink")
    }

    /// A symlink that stays inside the vault is not an escape, and must work.
    func test_symlinkedSubfolderInsideTheVaultIsAllowed() throws {
        let (root, store) = try store()
        let real = root.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Alias"),
            withDestinationURL: real)
        let note = try store.create(title: "Design", in: "Alias")
        assertInsideVault(note.path, root)
    }

    func test_createsNestedSubfolders() throws {
        let (_, store) = try store()
        let note = try store.create(title: "Design", in: "A/B")
        XCTAssertEqual(store.resolveLink("A/B/Design"), note.path)
    }

    /// The folder name is untrusted document text.
    func test_subfolderCannotEscapeTheVault() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "../../etc")
        assertInsideVault(note.path, root)
    }

    /// `[[Design|why]]` names the document "Design", not "Design|why".
    func test_aliasIsNotPartOfTheCreatedNoteName() throws {
        let (_, store) = try store()
        let name = LinkCompletionContext.documentName(of: "Design|why")
        XCTAssertEqual(name, "Design")
        let note = try store.create(title: name)
        XCTAssertEqual(note.title, "Design")
        XCTAssertEqual(store.resolveLink("Design"), note.path)
    }

    /// Failure must be reportable, not swallowed — `create` throws rather than
    /// returning nil, which is what lets `DocumentPane` surface it.
    func test_createThrowsWithoutAVault() {
        let store = LoreStore(
            documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID()).sqlite"))
        XCTAssertThrowsError(try store.create(title: "Design"))
    }

    // MARK: - Trigger detection (`[[` vs `#`)

    func test_trigger_doubleBracketIsWikilink() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "see [[Des", at: 9)?.kind, .wikilink)
    }

    func test_trigger_hashIsTag() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "about #des", at: 10)?.kind, .tag)
    }

    func test_trigger_hashQueryExcludesTheHash() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "about #des", at: 10)?.query, "des")
    }

    func test_trigger_headingHashDoesNotTrigger() {
        // `# ` at line start is a heading, and offering tag completions there
        // would fire on every new heading anyone types.
        XCTAssertNil(LinkCompletionContext.trigger(in: "# ", at: 2))
    }

    func test_trigger_hashInsideWikilinkDoesNotTrigger() {
        // `[[Note#` is a heading fragment — the wikilink trigger owns it.
        XCTAssertEqual(LinkCompletionContext.trigger(in: "[[Note#Head", at: 11)?.kind, .wikilink)
    }

    func test_trigger_nestedTagQueryKeepsTheSlash() {
        XCTAssertEqual(
            LinkCompletionContext.trigger(in: "#project/ain", at: 12)?.query,
            "project/ain")
    }
}
