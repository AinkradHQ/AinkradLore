import XCTest
@testable import LoreFeature

/// The open-document model.
///
/// `tabs` is no longer a strip the user reads — the tab bar is gone. It is now
/// a WARM-SESSION CACHE: documents that stay loaded behind the one on screen so
/// that navigating away never has to flush or close them. The close semantics
/// asserted here are unchanged and still load-bearing (⌘W and the header's
/// close both route through `closeTab`'s refusal), which is why these tests
/// survive the tab bar that motivated them.
///
/// History and eviction live in `DocumentHistoryTests`.
@MainActor
final class TabsTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-tabs-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    func test_openTwoDocuments_bothTabsStayOpen() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "b.txt")
    }

    func test_openingSameDocumentTwice_selectsExistingTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
    }

    /// Closing falls back to the MOST RECENTLY USED document.
    ///
    /// This was `selectsNeighbor`, which was right while `tabs` was a visible
    /// strip: the eye expects the gap to close sideways. With the strip gone,
    /// adjacency in a cache is meaningless and "what I was looking at before
    /// this one" is the only answer a user can predict.
    func test_closeTab_selectsTheMostRecentlyUsedDocument() throws {
        let root = tempDir(); let s = try makeStore(root)
        try "---\nid: a\ntitle: A\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "plain".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.open(url: root.appendingPathComponent("a.md"))
        s.open(url: root.appendingPathComponent("b.txt"))
        s.closeTab(s.selectedTab!)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "a.md")
    }

    /// Engine resolution is now TOTAL (Task 2): a file no specific engine
    /// claims opens as a read-only `AttachmentEngine` tab instead of setting
    /// `openError`. Replaces the old
    /// `test_openUnsupportedType_recordsErrorWithoutOpeningTab`, whose
    /// expectation is exactly the behavior this task removes.
    func test_openUnrecognizedType_opensAReadOnlyAttachmentTab() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("sheet.xlsx")
        try "binary".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        XCTAssertNil(s.openError)
        let session = try XCTUnwrap(s.selectedTab)
        XCTAssertTrue(session.engine is AttachmentEngine)
        XCTAssertTrue(session.isReadOnly)
    }

    func test_closeTab_savesDirtySessionBeforeClosing() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "edited content"
        session.markChanged()
        XCTAssertTrue(session.isDirty)
        let closed = s.closeTab(session)
        XCTAssertTrue(closed)
        XCTAssertTrue(s.tabs.isEmpty)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("edited content"))
    }

    func test_closeTab_refusesWhenSaveConflictsWithExternalChange() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "my edit"
        session.markChanged()

        // Simulate an external writer changing the file after we loaded it,
        // with a comfortably later mtime so the conflict check is unambiguous.
        let externalContent = "---\nid: a\ntitle: A\n---\nexternal change"
        try externalContent.write(to: url, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

        let closed = s.closeTab(session)
        XCTAssertFalse(closed)
        XCTAssertEqual(s.tabs.count, 1)
        XCTAssertTrue(s.tabs.contains { $0 === session })
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, externalContent)
    }

    func test_closeTab_forceClosesDespiteConflict() async throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "my edit"
        session.markChanged()

        let externalContent = "---\nid: a\ntitle: A\n---\nexternal change"
        try externalContent.write(to: url, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

        let closed = s.closeTab(session, force: true)
        XCTAssertTrue(closed)
        XCTAssertTrue(s.tabs.isEmpty)
        // "Close anyway → those edits are lost" must be TRUE on disk, not just
        // in the tab bar: the external writer's content is what stays.
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, externalContent)

        // And it must still be true after the 500ms autosave debounce elapses.
        // Without `cancelPendingSave`, the task armed by `markChanged` above
        // outlives the closed tab and writes the discarded edit back out.
        try await Task.sleep(for: .milliseconds(900))
        let afterDebounce = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(afterDebounce, externalContent)
    }

    /// The seventh data-loss defect: a dirty tab that is force-closed and then
    /// DELETED must stay deleted. The pending autosave used to survive the
    /// close, fire after the unlink, and recreate the file the user just
    /// deleted — containing the content they chose to discard.
    func test_deleteAfterForceClose_doesNotRecreateFileAfterDebounce() async throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        try s.rebuild()
        // Open through the ROW, exactly as the sidebar does, so the session's
        // url and the row's path are the same value `deleteDocument` matches on.
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "a.md" })
        s.open(row)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "discarded edit"
        session.markChanged()

        // The real delete affordance, not a re-implementation of it.
        deleteDocument(row, in: s)
        XCTAssertTrue(s.tabs.isEmpty, "delete must close the document's tab")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "pending autosave resurrected a deleted file")
    }

    /// The primitive item 2 adds, tested on its own: an armed autosave that is
    /// cancelled never writes.
    func test_cancelPendingSave_stopsTheDebouncedWrite() async throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        let original = "---\nid: a\ntitle: A\n---\nx"
        try original.write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "never written"
        session.markChanged()
        session.cancelPendingSave()

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertTrue(session.isDirty, "cancelling must not pretend the document was saved")
    }

    /// Item 3: teardown must not silently discard a dirty tab.
    func test_shutdown_savesDirtyTabsBeforeClearingThem() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "work in progress"
        session.markChanged()

        s.shutdown()
        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertNil(s.selectedTab)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("work in progress"))
    }

    /// Item 4: switching vaults must go through the same lifecycle as teardown.
    /// Tabs from vault A must not survive into vault B, still autosaving into A.
    func test_setVaultRoot_savesDirtyTabsIntoOldVaultAndClearsThem() throws {
        let rootA = tempDir(); let s = try makeStore(rootA)
        let url = rootA.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        s.open(url: url)
        let session = s.selectedTab!
        guard let engine = session.engine as? MarkdownEngine else {
            return XCTFail("expected MarkdownEngine")
        }
        engine.note.body = "belongs to vault A"
        session.markChanged()

        let rootB = tempDir()
        try s.setVaultRootForTesting(rootB)

        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertNil(s.selectedTab)
        XCTAssertNil(s.openError)
        // `vaultRoot` is CANONICAL since Task 8b (`activate` canonicalizes what
        // it stores, so the same spelling reaches the index, `scanVault`'s
        // enumerator and `LinkRewriter`). `rootB` is a raw
        // `FileManager.temporaryDirectory` path, which on macOS is `/var/...`
        // while its canonical form is `/private/var/...`.
        XCTAssertEqual(s.vaultRoot, VaultIndexCoordinator.canonical(rootB))
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("belongs to vault A"))
    }

    func test_closeTab_readOnlySessionClosesImmediately() throws {
        let root = tempDir(); let s = try makeStore(root)
        let url = root.appendingPathComponent("bad.txt")
        // Invalid UTF-8 byte sequence forces PlainTextEngine into lossy
        // decoding, which makes the session read-only.
        let invalidUTF8 = Data([0xFF, 0xFE, 0x00, 0x80])
        try invalidUTF8.write(to: url)
        s.open(url: url)
        let session = s.selectedTab!
        XCTAssertTrue(session.isReadOnly)
        let closed = s.closeTab(session)
        XCTAssertTrue(closed)
        XCTAssertTrue(s.tabs.isEmpty)
    }
}
