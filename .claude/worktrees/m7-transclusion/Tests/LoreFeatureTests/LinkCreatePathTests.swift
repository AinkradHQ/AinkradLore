import XCTest
@testable import LoreFeature

/// The SINGLE create-from-a-link path, `LoreStore.createAndOpenNote(forLinkTarget:syntax:)`.
///
/// Both "Create note" affordances — the backlinks panel's unresolved list and
/// the Cmd-click prompt — route through it. They used to have one
/// implementation each, and the panel's copy was still carrying the bug the
/// other had been fixed for: it passed `LinkResolver.basename(of:)` (which
/// keeps `/` and keeps `|alias`) to `create(title:)` and swallowed the result
/// in a `try?`, so the button silently did nothing. These tests pin the store
/// behaviour, which is what makes the two buttons unable to differ.
@MainActor
final class LinkCreatePathTests: XCTestCase {
    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-createpath-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// The blocker: `[[Projects/Design]]` used to slug to `projects/design`,
    /// write into a folder that did not exist, throw, and be swallowed.
    func test_folderedTargetCreatesTheNoteAndTheLinkThenResolves() throws {
        let (_, store) = try store()
        let note = try store.createAndOpenNote(forLinkTarget: "Projects/Design", syntax: .wikilink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "Projects")
        XCTAssertEqual(store.resolveLink("Projects/Design"), note.path)
    }

    /// The sibling: `[[Design|why]]` used to create `design|why.md`, which does
    /// not resolve the link it was created for.
    func test_aliasedTargetCreatesTheDocumentItNamesAndResolves() throws {
        let (_, store) = try store()
        let note = try store.createAndOpenNote(forLinkTarget: "Design|why", syntax: .wikilink)
        XCTAssertEqual(note.path.lastPathComponent, "design.md")
        XCTAssertEqual(store.resolveLink("Design"), note.path)
    }

    func test_fragmentIsNotPartOfTheCreatedName() throws {
        let (_, store) = try store()
        let note = try store.createAndOpenNote(forLinkTarget: "Design#Overview", syntax: .wikilink)
        XCTAssertEqual(note.path.lastPathComponent, "design.md")
    }

    /// The created note is opened, which is what makes the button feel like it
    /// did something.
    func test_theCreatedNoteIsOpened() throws {
        let (_, store) = try store()
        let note = try store.createAndOpenNote(forLinkTarget: "Design", syntax: .wikilink)
        XCTAssertEqual(store.selectedTab?.url.standardizedFileURL,
                       note.path.standardizedFileURL)
    }

    /// A genuine failure must be THROWN so the caller can show it. Swallowing
    /// it in a `try?` is the whole defect.
    func test_aCreateThatFailsThrowsRatherThanDoingNothing() {
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: FileManager.default.temporaryDirectory
                                  .appendingPathComponent("\(UUID()).sqlite"))
        XCTAssertThrowsError(try store.createAndOpenNote(forLinkTarget: "Design", syntax: .wikilink)) {
            XCTAssertEqual($0 as? LoreError, .noVault)
        }
    }

    /// A target that names no document at all is refused with a message a view
    /// can show, not with a file called `/`.
    func test_aTargetThatNamesNoNoteIsRefusedWithAMessage() throws {
        let (_, store) = try store()
        XCTAssertThrowsError(try store.createAndOpenNote(forLinkTarget: "/", syntax: .wikilink)) {
            XCTAssertEqual(($0 as? UncreatableLinkTarget)?.target, "/")
            XCTAssertNotNil(($0 as? UncreatableLinkTarget)?.errorDescription)
        }
    }

    /// A trailing slash still names the last real component, so it creates that
    /// note rather than refusing — `[[Projects/]]` is a `Projects` note.
    func test_aTrailingSlashStillNamesTheLastComponent() throws {
        let (_, store) = try store()
        let note = try store.createAndOpenNote(forLinkTarget: "Projects/", syntax: .wikilink)
        XCTAssertEqual(note.path.lastPathComponent, "projects.md")
    }
}

/// The last-resort branch of `insertableTarget`, which used to return
/// `candidates.last` UNVERIFIED.
final class InsertableTargetFallbackTests: XCTestCase {
    private func row(path: String, title: String) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: path), id: "x", title: title, tags: [],
                 aliases: [], updated: Date(), type: "markdown", properties: [])
    }

    /// The premise is deliberately contrived — it is the shape the old code
    /// could not distinguish: the MOST SPECIFIC candidate resolves to a
    /// DIFFERENT document, while a less specific one resolves to nothing.
    ///
    /// Inserting the specific one produces a link that silently opens the wrong
    /// note, and nothing in the UI ever flags it. Inserting the dead one
    /// produces a link that shows as unresolved and that "Create note" fixes.
    /// The dead one wins.
    func test_prefersACandidateThatResolvesNowhereOverOneThatResolvesElsewhere() {
        let wanted = row(path: "/v/Projects/Design.md", title: "Design")
        let target = LinkCompletionContext.insertableTarget(
            for: wanted, relativePath: "Projects/Design",
            resolves: { candidate in
                candidate == "Projects/Design"
                    ? URL(fileURLWithPath: "/v/Somewhere/Else.md") : nil
            })
        XCTAssertEqual(target, "Design")
    }

    /// When every spelling resolves — and every one resolves elsewhere — there
    /// is no honest answer left, so the most specific candidate is written.
    func test_fallsBackToTheMostSpecificCandidateWhenEverySpellingIsTaken() {
        let wanted = row(path: "/v/Projects/Design.md", title: "Design")
        let target = LinkCompletionContext.insertableTarget(
            for: wanted, relativePath: "Projects/Design",
            resolves: { _ in URL(fileURLWithPath: "/v/Somewhere/Else.md") })
        XCTAssertEqual(target, "Projects/Design")
    }

    /// The verified path is unchanged: a candidate that round-trips still wins,
    /// and the prettiest such candidate is still preferred.
    func test_averifiedCandidateStillWins() {
        let wanted = row(path: "/v/Projects/Design.md", title: "Design")
        let target = LinkCompletionContext.insertableTarget(
            for: wanted, relativePath: "Projects/Design",
            resolves: { _ in URL(fileURLWithPath: "/v/Projects/Design.md") })
        XCTAssertEqual(target, "Design")
    }
}
