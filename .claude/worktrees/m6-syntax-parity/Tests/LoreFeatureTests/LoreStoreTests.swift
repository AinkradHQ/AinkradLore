import XCTest
@testable import LoreFeature
import AinkradAppKit

final class FakeDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

@MainActor
final class LoreStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)   // bypasses security-scoped bookmark in tests
        return s
    }

    func test_create_writesFileAndIndexes() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "First")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertEqual(s.rows.map(\.title), ["First"])
    }

    func test_save_updatesBodyAndSearch() throws {
        let root = tempDir(); let s = try makeStore(root)
        var note = try s.create(title: "Note")
        note.body = "searchable haystack"
        try s.save(note)
        XCTAssertEqual(s.search("haystack").map(\.id), [note.id])
    }

    /// `delete(_:)` — a permanent `removeItem` with a known
    /// autosave-resurrection defect — is gone; `trash(_:)` is the only deletion
    /// path. It must still satisfy what this test always asserted.
    func test_trash_removesFileAndRow() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "Trash")
        try s.trash(s.rows.first { $0.id == note.id }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path.path))
        XCTAssertTrue(s.rows.isEmpty)
    }

    func test_rebuild_picksUpExternalFile() throws {
        let root = tempDir(); let s = try makeStore(root)
        let ext = root.appendingPathComponent("outside.md")
        try "---\nid: ext\ntitle: Outside\ntags: []\ncreated: 2026-07-19\nupdated: 2026-07-19\n---\nhi"
            .write(to: ext, atomically: true, encoding: .utf8)
        try s.rebuild()
        XCTAssertTrue(s.rows.contains { $0.id == "ext" })
    }

    func test_allTags_areDedupedAndSorted() throws {
        let root = tempDir(); let s = try makeStore(root)
        var a = try s.create(title: "A"); a.tags = ["zeta", "alpha"]; try s.save(a)
        var b = try s.create(title: "B"); b.tags = ["alpha", "mid"]; try s.save(b)
        XCTAssertEqual(s.allTags, ["alpha", "mid", "zeta"])
    }

    func test_defaultNoteFolder_createsInSubfolderAndPersists() throws {
        let root = tempDir()
        let docs = FakeDocs()
        let idx = root.appendingPathComponent(".index.sqlite")
        let s = LoreStore(documents: docs, indexPath: idx)
        try s.setVaultRootForTesting(root)
        s.setDefaultNoteFolder("inbox")
        let note = try s.create(title: "Captured")
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "inbox")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        // A fresh store sharing the same documents restores the setting.
        let s2 = LoreStore(documents: docs, indexPath: idx)
        XCTAssertEqual(s2.defaultNoteFolder, "inbox")
    }

    /// The collapse survives relaunch, like `sidebarMode` and
    /// `expandedFolders` — a panel that reopens itself every launch is a
    /// preference the app keeps forgetting.
    func test_sidebarCollapsePersists() throws {
        let root = tempDir()
        let docs = FakeDocs()
        let idx = root.appendingPathComponent(".index.sqlite")
        let s = LoreStore(documents: docs, indexPath: idx)
        try s.setVaultRootForTesting(root)
        XCTAssertFalse(s.sidebarCollapsed, "a first launch shows the sidebar")
        s.setSidebarCollapsed(true)

        let reopened = LoreStore(documents: docs, indexPath: idx)
        XCTAssertTrue(reopened.sidebarCollapsed)
    }

    func test_rebuild_isRecursiveAndPrunesDeleted() throws {
        let root = tempDir(); let s = try makeStore(root)
        let sub = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let deep = sub.appendingPathComponent("deep.md")
        try "---\nid: deep\ntitle: Deep\ntags: []\ncreated: 2026-07-19\nupdated: 2026-07-19\n---\nhi"
            .write(to: deep, atomically: true, encoding: .utf8)
        try s.rebuild()
        XCTAssertTrue(s.rows.contains { $0.id == "deep" }, "recursive scan should find nested notes")
        try FileManager.default.removeItem(at: deep)
        try s.rebuild()
        XCTAssertFalse(s.rows.contains { $0.id == "deep" }, "rebuild should prune deleted files")
    }

    func test_scanVault_indexesEveryEngineOpenableType() throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Note\n---\nalpha".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "beta text".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "gamma".write(
            to: root.appendingPathComponent("c.xlsx"), atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        // `.xlsx` is indexed as an ATTACHMENT row rather than skipped: the list
        // must not lie about what is in the vault (see `scanVault`). It carries
        // no plaintext, so it is metadata only.
        XCTAssertEqual(Set(entries.map(\.type)), ["markdown", "plaintext", AttachmentEngine.identifier])
        XCTAssertEqual(entries.first { $0.type == AttachmentEngine.identifier }?.payload.plaintext, "")
    }

    func test_search_findsPlainTextDocuments() async throws {
        let root = tempDir()
        try "beta needle".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertEqual(s.search("needle").map(\.title), ["b"])
    }

    /// A vault under a dot-prefixed ancestor (`~/.local/share/notes`, a
    /// `.worktrees/` checkout, a sandbox container) must still index. Judging
    /// the absolute path made those vaults silently empty.
    func test_scanVault_indexesAVaultUnderADotPrefixedAncestor() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hidden-\(UUID())", isDirectory: true)
        let root = parent.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try "alpha".write(to: root.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        // ...while a dot directory INSIDE the vault is still skipped.
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "beta".write(to: git.appendingPathComponent("b.txt"),
                         atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["a.txt"])
    }

    func test_scanVault_capsIndexedPlaintextButStillSearchesIt() throws {
        let root = tempDir()
        let limit = VaultIndexCoordinator.maxIndexedPlaintextBytes
        // "needle" up front, then well past the cap.
        let big = "needle\n" + String(repeating: "x", count: limit + 5_000)
        try big.write(to: root.appendingPathComponent("big.log"),
                      atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertLessThanOrEqual(entries[0].payload.plaintext.utf8.count, limit)
        XCTAssertLessThan(entries[0].payload.plaintext.utf8.count, big.utf8.count)

        let index = try LoreIndex(path: root.appendingPathComponent("i.sqlite"))
        try index.replaceAll(with: entries)
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["big"])
    }

    func test_cappedTruncatesOnAScalarBoundary() {
        let limit = VaultIndexCoordinator.maxIndexedPlaintextBytes
        // Every "é" is 2 UTF-8 bytes; the leading "a" makes the byte cap land
        // in the middle of one.
        let text = "a" + String(repeating: "é", count: limit)
        let capped = VaultIndexCoordinator.capped(text)
        XCTAssertEqual(capped.utf8.count, limit - 1, "half a scalar was kept or too much dropped")
        XCTAssertFalse(capped.unicodeScalars.contains("\u{FFFD}"),
                       "truncation cut through a scalar")
        XCTAssertTrue(capped.dropFirst().allSatisfy { $0 == "é" })
    }

    // MARK: - attachment file types
    //
    // A vault full of `.xlsx` must not make the file list lie about what is
    // there. Files no specific engine claims are indexed and opened as
    // metadata-only `AttachmentEngine` rows so they list, and clicking one
    // opens a read-only QuickLook preview.

    private func makeMixedVault() throws -> URL {
        let root = tempDir()
        try "---\nid: m\ntitle: Note\n---\nbody".write(
            to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        try "let x = 1".write(
            to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try "%PDF-1.4 zorkmid".write(
            to: root.appendingPathComponent("paper.pdf"), atomically: true, encoding: .utf8)
        try "sheetstuff zorkmid".write(
            to: root.appendingPathComponent("book.xlsx"), atomically: true, encoding: .utf8)
        return root
    }

    func test_mixedVault_listsEveryFileIncludingAttachmentTypes() throws {
        let root = try makeMixedVault(); let s = try makeStore(root)
        try s.rebuild()
        XCTAssertEqual(Set(s.rows.map(\.path.lastPathComponent)),
                       ["note.md", "log.txt", "code.swift", "paper.pdf", "book.xlsx"])
    }

    func test_attachmentRow_isMetadataOnlyAndTitledByFilename() throws {
        let root = try makeMixedVault(); let s = try makeStore(root)
        try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "book.xlsx" })
        XCTAssertEqual(row.type, AttachmentEngine.identifier)
        XCTAssertEqual(row.title, "book.xlsx")
        XCTAssertTrue(row.tags.isEmpty)
        XCTAssertTrue(row.properties.isEmpty)
        let entry = try XCTUnwrap(VaultIndexCoordinator.scanVault(at: root)
            .first { $0.url.lastPathComponent == "book.xlsx" })
        XCTAssertEqual(entry.payload.plaintext, "")
    }

    func test_attachmentRows_doNotMatchSearchesForBodyTextTheyDoNotHave() throws {
        let root = try makeMixedVault(); let s = try makeStore(root)
        try s.rebuild()
        XCTAssertTrue(s.search("zorkmid").isEmpty,
                      "an attachment row matched body text that was never indexed")
        // The filename IS indexed as the title, so the row is still findable.
        XCTAssertEqual(s.search("book").map(\.path.lastPathComponent), ["book.xlsx"])
    }

    /// Engine resolution is now TOTAL (Task 2): a file no specific engine
    /// claims no longer sets `openError` — it opens as a read-only
    /// `AttachmentEngine` tab, previewed via QuickLook. This replaces the old
    /// `test_openingUnclaimedRow_setsUnsupportedOpenError`, whose expectation
    /// (open always fails for `.xlsx`) is exactly the behavior this task
    /// removes.
    func test_openingAttachmentRow_opensAReadOnlyTab() throws {
        let root = try makeMixedVault(); let s = try makeStore(root)
        try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "book.xlsx" })
        s.open(row)
        XCTAssertNil(s.openError)
        let tab = try XCTUnwrap(s.selectedTab)
        XCTAssertTrue(tab.engine is AttachmentEngine)
        XCTAssertTrue(tab.isReadOnly)
    }

    func test_scanVault_stillSkipsDotPrefixedComponentsBelowTheRoot() throws {
        let root = tempDir()
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "obj".write(to: git.appendingPathComponent("pack.idx"), atomically: true, encoding: .utf8)
        XCTAssertTrue(VaultIndexCoordinator.scanVault(at: root).isEmpty)
    }

    func test_scanVault_doesNotIndexDirectoriesAsUnclaimedRows() throws {
        let root = tempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertTrue(VaultIndexCoordinator.scanVault(at: root).isEmpty)
    }

    func test_scanVault_indexesAPackageAsOneAttachmentRowNotItsInternals() throws {
        let root = tempDir()
        let pkg = root.appendingPathComponent("Report.pages", isDirectory: true)
        let contents = pkg.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try "<xml/>".write(
            to: contents.appendingPathComponent("index.xml"), atomically: true, encoding: .utf8)
        try "jpegbytes".write(
            to: pkg.appendingPathComponent("preview.jpg"), atomically: true, encoding: .utf8)

        // Confirm the fixture is actually treated as a package on this
        // system before trusting the assertions below — package-ness comes
        // from UTI registration, not the `.pages` name alone, and a false
        // negative here would make the test pass for the wrong reason.
        let isPackage = try pkg.resourceValues(forKeys: [.isPackageKey]).isPackage
        XCTAssertEqual(isPackage, true, "fixture is not recognized as a package on this system")

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.type, AttachmentEngine.identifier)
        XCTAssertEqual(entries.first?.payload.title, "Report.pages")
    }

    func test_scanVault_plainSubdirectoryYieldsNoRowButItsFilesAreStillIndexed() throws {
        let root = tempDir()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "log line".write(
            to: folder.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url.lastPathComponent, "run.log")
        XCTAssertFalse(entries.contains { $0.url.lastPathComponent == "Projects" })
    }

    func test_externalChange_flagsOpenNote() throws {
        let root = tempDir(); let s = try makeStore(root)
        let note = try s.create(title: "Open")
        usleep(20_000)  // ensure the external write lands on a later mtime tick
        // simulate external edit bumping mtime
        try "changed".write(to: note.path, atomically: true, encoding: .utf8)
        XCTAssertTrue(s.externalChangeDetected(for: note))
    }

    func test_scanVault_resolvesLinksBetweenDocuments() throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Alpha\n---\nlinks to [[Beta]]"
            .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: Beta\n---\nno links"
            .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)

        let entries = VaultIndexCoordinator.scanVault(at: root)
        let alpha = entries.first { $0.url.lastPathComponent == "alpha.md" }
        XCTAssertEqual(alpha?.resolvedLinks.first?.rawTarget, "Beta")
        XCTAssertEqual(alpha?.resolvedLinks.first?.targetPath?.lastPathComponent, "beta.md")
    }

    func test_scanVault_leavesUnknownTargetsUnresolved() throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Alpha\n---\n[[Nowhere]]"
            .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        let entries = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertNil(entries.first?.resolvedLinks.first?.targetPath)
        XCTAssertEqual(entries.first?.resolvedLinks.first?.rawTarget, "Nowhere")
    }

    func test_backlinksIncludeSurroundingLineAsContext() async throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Alpha\n---\nintro\nwe discussed [[Beta]] at length\noutro"
            .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: Beta\n---\n"
            .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        let links = s.backlinks(to: root.appendingPathComponent("beta.md"))
        XCTAssertEqual(links.map(\.row.title), ["Alpha"])
        XCTAssertEqual(links.first?.context, "we discussed [[Beta]] at length")
    }

    func test_unresolvedLinksAreReported() async throws {
        let root = tempDir()
        try "---\nid: a\ntitle: Alpha\n---\n[[Nowhere]]"
            .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertEqual(s.unresolvedLinks(from: root.appendingPathComponent("alpha.md")),
                       [UnresolvedLink(rawTarget: "Nowhere", syntax: .wikilink)])
    }

    func test_openLinkOpensResolvedTargetInATab() async throws {
        let root = tempDir()
        try "---\nid: b\ntitle: Beta\n---\n"
            .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertTrue(s.openLink("Beta"))
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "beta.md")
    }

    func test_openLinkReturnsFalseWhenUnresolved() async throws {
        let root = tempDir()
        let s = try makeStore(root)
        await s.settleForTesting()
        XCTAssertFalse(s.openLink("Nowhere"))
        XCTAssertNil(s.selectedTab)
    }

    func test_linkCompletionsMatchTitlesAndAliases() async throws {
        let root = tempDir()
        try "---\nid: b\ntitle: Beta Notes\naliases: [Bravo]\n---\n"
            .write(to: root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
        let s = try makeStore(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertEqual(s.linkCompletions(matching: "bet").map(\.title), ["Beta Notes"])
    }
}
