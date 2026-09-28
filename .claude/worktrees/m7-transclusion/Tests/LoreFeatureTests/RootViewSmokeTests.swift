import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

@MainActor
final class RootViewSmokeTests: XCTestCase {
    private func makeStore() -> LoreStore {
        LoreStore(documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"))
    }

    private func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_rootView_buildsWithoutVault() {
        _ = LoreRootView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_settingsView_builds() {
        _ = LoreSettingsView(store: makeStore(), theme: HostTheme(TestTokens.make()))
    }

    func test_documentPane_buildsForEachOpenTab() throws {
        let root = try tempVault()
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: root.appendingPathComponent("a.md"))
        store.open(url: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(store.tabs.count, 2)
        for session in store.tabs {
            _ = DocumentPane(store: store, session: session,
                             theme: HostTheme(TestTokens.make()),
                             ops: SidebarOperations(store: store),
                             onOutlineChange: { _ in }, onScrollHandler: { _ in },
                             onTagClick: { _ in },
                             mentionsRequest: .constant(false),
                             showingActions: .constant(false), actionItems: [])
        }
        // The tab strip is gone; the header is the chrome row that replaced
        // it. Built here for BOTH states — with a document and without —
        // because it now renders in the empty state too, where it carries the
        // sidebar toggle and the history chevrons.
        _ = DocumentHeaderBar(session: store.selectedTab, store: store,
                              theme: HostTheme(TestTokens.make()),
                              row: nil, ops: SidebarOperations(store: store),
                              showingActions: .constant(false))
        _ = DocumentHeaderBar(session: nil, store: store,
                              theme: HostTheme(TestTokens.make()),
                              row: nil, ops: SidebarOperations(store: store),
                              showingActions: .constant(false))
        // The ⋯ menu's own contents, which no test could previously reach
        // because it lived inside a context-menu modifier.
        _ = DocumentActionsMenu(items: [], theme: HostTheme(TestTokens.make()),
                                onDismiss: {})
    }

    /// Regression for the whole-branch review finding: linked mentions were
    /// once gated on `session.engine is MarkdownEngine`, so opening a
    /// non-markdown document (a PDF, here) never showed them even though
    /// attachments are resolvable link targets. The list now lives in
    /// `DocumentMentionsList`, shown on request rather than in a panel, and the
    /// rule is unchanged: it must build for a non-markdown tab. This guards
    /// against the gate being reintroduced; `M3AcceptanceTests
    /// .test_criterion3_…` covers the underlying `store.backlinks(to:)` data.
    func test_documentPane_buildsForNonMarkdownTabWithMentions() throws {
        let root = try tempVault()
        try Data().write(to: root.appendingPathComponent("a.pdf"))
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: root.appendingPathComponent("a.pdf"))
        guard let session = store.tabs.first else {
            return XCTFail("expected the PDF to open a tab")
        }
        XCTAssertFalse(session.engine is MarkdownEngine,
                       "this test must exercise a non-markdown engine")
        _ = DocumentPane(store: store, session: session,
                         theme: HostTheme(TestTokens.make()),
                         ops: SidebarOperations(store: store),
                         onOutlineChange: { _ in }, onScrollHandler: { _ in },
                         onTagClick: { _ in },
                         mentionsRequest: .constant(false),
                         showingActions: .constant(false), actionItems: [])
    }

    /// The mentions list, now shown in a slideover on request rather than as a
    /// band under the document. Built in BOTH states: with content, and empty
    /// — the empty case draws nothing at all, and a view that renders nothing
    /// is exactly the one a smoke test is most likely to stop covering.
    func test_mentionsListBuilds() throws {
        let theme = HostTheme(TestTokens.make())
        _ = DocumentMentionsList(backlinks: [], unresolved: [], theme: theme,
                                 onOpen: { _ in }, onCreate: { _ in })
        let row = IndexRow(path: URL(fileURLWithPath: "/v/a.md"), id: "a", title: "A",
                           tags: [], aliases: [], updated: Date(),
                           type: MarkdownEngine.identifier, properties: [])
        _ = DocumentMentionsList(
            backlinks: [LoreStore.Backlink(id: row.path, row: row, context: "see [[B]]")],
            unresolved: [UnresolvedLink(rawTarget: "Ghost", syntax: .wikilink)],
            theme: theme, onOpen: { _ in }, onCreate: { _ in })
    }

    func test_folderTreeGroupsDocumentsByFolder() throws {
        let root = URL(fileURLWithPath: "/v")
        func row(_ path: String, _ title: String) -> IndexRow {
            IndexRow(path: URL(fileURLWithPath: path), id: path, title: title, tags: [],
                     aliases: [], updated: Date(), type: "markdown", properties: [])
        }
        let tree = FolderNode.tree(from: [
            row("/v/a.md", "A"),
            row("/v/Projects/b.md", "B"),
            row("/v/Projects/Deep/c.md", "C"),
        ], directories: [], root: root)

        XCTAssertEqual(tree.documents.map(\.title), ["A"])
        XCTAssertEqual(tree.children.map(\.name), ["Projects"])
        let projects = tree.children[0]
        XCTAssertEqual(projects.documents.map(\.title), ["B"])
        XCTAssertEqual(projects.children.map(\.name), ["Deep"])
        XCTAssertEqual(projects.children[0].documents.map(\.title), ["C"])
    }

    /// Regression for the whole-branch review finding: `New Folder` reports
    /// success but the folder never appears, because `FolderNode.tree` was
    /// built purely from index rows and an empty directory produces zero
    /// rows. `FolderNode.tree` itself is now a pure function over a
    /// caller-supplied `directories` array — this exercises it directly with
    /// the exact call shape `FolderTreeView.body` uses.
    func test_folderTreeIncludesAnEmptyDirectoryWithNoIndexRows() throws {
        let root = try tempVault()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Q1"), withIntermediateDirectories: true)

        let tree = FolderNode.tree(from: [], directories: ["Q1"], root: root)

        XCTAssertEqual(tree.children.map(\.name), ["Q1"],
                       "an empty directory must still appear as a folder node")
        XCTAssertTrue(tree.children.first?.documents.isEmpty ?? false)
    }

    /// Fix-wave regression (round 2 → round 3, CRITICAL 1): Round 2 made
    /// `directoryPaths` a cache keyed off `rows`, and this test originally
    /// proved the cache refreshes by calling `startBackgroundRebuild()` BY
    /// HAND — which does not exercise the real bug at all.
    /// `LoreStore.createFolder` writes a directory directly and never
    /// touches `rows` or the watcher, so THIS is the path that has to prove
    /// a folder becomes visible: going through the real API, with no manual
    /// rebuild trigger, the way `SidebarOperations.commitName()`'s
    /// `.newFolder` branch actually calls it.
    func test_createFolderMakesTheNewFolderVisibleWithNoManualRescan() throws {
        let root = try tempVault()
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        XCTAssertFalse(store.directoryPaths.contains("Q1"))

        _ = try store.createFolder(named: "Q1", in: root)

        XCTAssertTrue(store.directoryPaths.contains("Q1"),
                      "createFolder must make the new folder visible immediately, "
                      + "with no background rebuild or watcher event required")
        let tree = FolderNode.tree(from: store.rows, directories: store.directoryPaths, root: root)
        XCTAssertTrue(tree.children.contains { $0.name == "Q1" },
                      "and the folder tree built from that state must show it")
    }

    /// Same regression, for a folder created INSIDE a subfolder — the shape
    /// that actually broke in round 3. Before `createFolder` called
    /// `coordinator.noteDirectoryCreated` directly, `directoryPaths` had no
    /// synchronous way to learn `Vault/Parent/Q1` existed: even now that
    /// `FolderWatcher`'s `FSEventStream` sees subfolder changes too, that
    /// path runs through FSEvents' coalescing latency and a full
    /// `startBackgroundRebuild()`, not an immediate update — this test
    /// asserts the folder is visible with NEITHER a background rebuild NOR a
    /// watcher event required.
    func test_createFolderInsideASubfolderIsVisibleImmediately() throws {
        let root = try tempVault()
        let parent = root.appendingPathComponent("Parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)

        _ = try store.createFolder(named: "Q1", in: parent)

        XCTAssertTrue(store.directoryPaths.contains("Parent/Q1"),
                      "a folder created inside a subfolder must be visible immediately, "
                      + "without waiting on the watcher's coalescing latency")
    }

    /// The background-rescan path (a watcher event, or a full app relaunch)
    /// must ALSO keep `directoryPaths` current — proven by going around the
    /// store entirely, straight to disk (the way an external `mkdir` or
    /// another app would), then triggering the same rescan the watcher
    /// triggers.
    func test_directoryPathsPicksUpAFolderCreatedAfterActivation() async throws {
        let root = try tempVault()
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        XCTAssertFalse(store.directoryPaths.contains("Q1"))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Q1"), withIntermediateDirectories: true)
        store.startBackgroundRebuild()
        await store.settleForTesting()

        XCTAssertTrue(store.directoryPaths.contains("Q1"),
                      "a folder created after activation must appear once the "
                      + "background rescan that follows it lands")
    }

    func test_folderTreeViewBuilds() throws {
        let root = try tempVault()
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        _ = FolderTreeView(store: store, theme: HostTheme(TestTokens.make()),
                           selected: .constant(nil), onSelect: { _ in },
                           ops: SidebarOperations(store: store))
        _ = NoteListView(store: store, query: .constant(""), selected: .constant(nil),
                         theme: HostTheme(TestTokens.make()), onSelect: { _ in },
                         onNew: {}, ops: SidebarOperations(store: store),
                         activeTag: .constant(nil), focusRequest: .constant(nil))
    }

    func test_documentErrorCard_builds() {
        let url = URL(fileURLWithPath: "/tmp/x.xlsx")
        _ = DocumentErrorCard(url: url, message: "Lore couldn't open this document.",
                              theme: HostTheme(TestTokens.make()))
    }

    /// The delete affordance moved from `NoteEditorPane` to the list row's
    /// context menu; its store-level effect is testable without a view host.
    func test_deleteDocument_removesFileAndClosesOnlyItsTab() throws {
        let root = try tempVault()
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: a, atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: B\n---\ny".write(to: b, atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: a)
        store.open(url: b)
        XCTAssertEqual(store.tabs.count, 2)

        let row = IndexRow(path: a, id: "a", title: "A", tags: [], aliases: [], updated: Date(),
                           type: MarkdownEngine.identifier, properties: [])
        deleteDocument(row, in: store)

        XCTAssertEqual(store.tabs.map(\.url), [b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    /// A reload must be visible in the editor. `DocumentPane` composes the
    /// editor's identity from `reloadGeneration`, so this asserts the value
    /// that identity is built from actually changes.
    func test_reload_bumpsGenerationSoEditorIdentityChanges() throws {
        let root = try tempVault()
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        store.open(url: url)
        let session = try XCTUnwrap(store.selectedTab)
        let before = session.reloadGeneration
        try "---\nid: a\ntitle: A\n---\nchanged".write(to: url, atomically: true, encoding: .utf8)
        try session.resolveByReloading()
        XCTAssertEqual(session.reloadGeneration, before + 1)
    }
}

enum TestTokens {
    static func make() -> HostThemeTokens {
        HostThemeTokens(themeID: "t", background: .black, surface: .gray, surfaceElevated: .gray,
            accentPrimary: .blue, accentSecondary: .teal, accentTertiary: .green, foreground: .white)
    }
}
