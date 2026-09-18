import XCTest
@testable import LoreFeature

/// The `[[` popup's "Create …" row.
@MainActor
final class CompletionCreateRowTests: XCTestCase {

    private func row(_ title: String) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: "/v/\(title).md"), id: title, title: title,
                 tags: [], aliases: [], updated: Date(),
                 type: MarkdownEngine.identifier, properties: [])
    }

    private func items(_ prefix: String, _ matches: [IndexRow],
                       canCreate: Bool = true) -> [LinkCompletionItem] {
        MarkdownEditor.Coordinator.completionItems(for: prefix, matches: matches,
                                                   canCreate: canCreate)
    }

    func test_typingSomethingNewOffersToCreateIt() {
        let result = items("Design Doc", [row("Design Notes")])
        XCTAssertEqual(result.last, .create("Design Doc"))
    }

    /// LAST, never first. The common case is picking a note that exists, and a
    /// create row at the top is one stray Return away from a duplicate.
    func test_theCreateRowComesLast() {
        let result = items("Des", [row("Design"), row("Desktop")])
        XCTAssertEqual(result.count, 3)
        if case .document = result[0] {} else { XCTFail("matches must lead") }
        XCTAssertEqual(result.last, .create("Des"))
    }

    /// No create row when the typed text already names something offered: a
    /// second document with the same name is the one outcome a vault cannot
    /// easily undo.
    func test_noCreateRowWhenTheNameAlreadyExists() {
        XCTAssertFalse(items("Design", [row("Design")]).contains(.create("Design")))
    }

    /// Matched case-insensitively — `design` and `Design` are the same note as
    /// far as someone typing a link is concerned.
    func test_theExistingNameCheckIgnoresCase() {
        XCTAssertFalse(items("design", [row("Design")]).contains(.create("design")))
    }

    /// A partial prefix that merely PREFIXES an existing note still offers to
    /// create: typing "Des" when "Design" exists is not the same as having
    /// typed "Design".
    func test_aPartialPrefixStillOffersCreate() {
        XCTAssertTrue(items("Des", [row("Design")]).contains(.create("Des")))
    }

    func test_noCreateRowWithoutAWayToCreate() {
        XCTAssertFalse(items("Anything", [], canCreate: false).contains(.create("Anything")))
    }

    /// Whitespace-only input names nothing.
    func test_blankInputOffersNothing() {
        XCTAssertTrue(items("   ", []).isEmpty)
    }

    func test_labelsReadAsActions() {
        XCTAssertEqual(LinkCompletionItem.create("Q1 Plan").label, "Create “Q1 Plan”")
        XCTAssertEqual(LinkCompletionItem.document(row("Q1 Plan")).label, "Q1 Plan")
    }

    // MARK: - Create without opening

    /// The store-level guarantee the row depends on: creating a note for a link
    /// must NOT navigate, or accepting a completion abandons the sentence being
    /// written.
    func test_creatingANoteForALinkDoesNotOpenIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-createrow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        await store.settleForTesting()

        let note = try store.createNote(forLinkTarget: "Fresh Idea", syntax: .wikilink)

        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertTrue(store.tabs.isEmpty, "creating from a completion must not navigate")
        XCTAssertNil(store.selectedTab)
    }

    /// …while the Cmd-click path still DOES open, since that one is a
    /// deliberate navigation.
    func test_theCmdClickPathStillOpens() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-createopen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        await store.settleForTesting()

        _ = try store.createAndOpenNote(forLinkTarget: "Followed", syntax: .wikilink)

        // Compared case-INSENSITIVELY: `create(title:)` slugifies the filename
        // ("followed.md") while the frontmatter title keeps the typed case
        // ("Followed"). Asserting they match exactly tests the slug rule, not
        // the navigation this test is about.
        let opened = try XCTUnwrap(store.selectedTab)
        XCTAssertEqual(opened.url.deletingPathExtension().lastPathComponent
                        .compare("Followed", options: .caseInsensitive), .orderedSame)
    }
}
