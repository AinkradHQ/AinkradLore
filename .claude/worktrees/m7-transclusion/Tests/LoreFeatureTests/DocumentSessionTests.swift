import XCTest
@testable import LoreFeature

@MainActor
final class DocumentSessionTests: XCTestCase {
    private func vault() throws -> (URL, VaultIndexCoordinator) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-sess-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = VaultIndexCoordinator(indexPath: root.appendingPathComponent(".idx.sqlite"))
        try c.activate(root: root)
        return (root, c)
    }

    private func note(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tempFile(_ name: String, _ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-sess-file-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_markChanged_setsDirty() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertFalse(s.isDirty)
        s.markChanged()
        XCTAssertTrue(s.isDirty)
    }

    func test_saveNow_clearsDirtyAndWritesFile() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "changed body"
        s.markChanged()
        try s.saveNow()
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("changed body"))
    }

    func test_title_comesFromEngineAndRefreshesOnSave() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertEqual(s.title, "T")
        (s.engine as! MarkdownEngine).note.title = "T2"
        try s.saveNow()
        XCTAssertEqual(s.title, "T2")
    }

    func test_externalChange_blocksSaveAndFlagsConflict() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        Thread.sleep(forTimeInterval: 1.1)   // exceed filesystem mtime granularity
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        XCTAssertTrue(s.conflict)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("EXTERNAL"))
    }

    func test_resolveByOverwriting_writesOurVersion() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        try s.resolveByOverwriting()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("ours"))
        XCTAssertFalse(s.conflict)
    }

    func test_resolveBySavingCopy_leavesOriginalIntact() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        let copy = try s.resolveBySavingCopy()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("EXTERNAL"))
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("ours"))
    }

    func test_resolveByReloading_discardsOurEdits() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        try s.resolveByReloading()
        XCTAssertFalse(s.conflict)
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue((s.engine as! MarkdownEngine).note.body.contains("EXTERNAL"))
    }

    /// Ruling 2: the editors seed `@State` in `.onAppear`, so a reload that
    /// mutates the engine in place needs a signal the view can key its `.id()`
    /// off, or the user sees the old text after clicking Reload.
    func test_resolveByReloading_bumpsReloadGeneration() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertEqual(s.reloadGeneration, 0)
        try s.resolveByReloading()
        XCTAssertEqual(s.reloadGeneration, 1)
        try s.resolveByReloading()
        XCTAssertEqual(s.reloadGeneration, 2)
    }

    // MARK: - Ruling 1: read-only (lossily decoded) documents

    /// A `.txt` whose bytes are not valid UTF-8, so `PlainTextEngine.load`
    /// falls back to a lossy decode and `save` refuses to write it.
    private func lossyFile(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("bad.txt")
        try Data([0x68, 0x69, 0xFF, 0xFE, 0x0A]).write(to: url)
        return url
    }

    func test_lossilyDecodedDocument_isReadOnly() throws {
        let (root, c) = try vault()
        let s = try DocumentSession.open(url: try lossyFile(root), coordinator: c)
        XCTAssertTrue(s.isReadOnly)
        let ok = try DocumentSession.open(
            url: try note(root, "fine.txt", "hello"), coordinator: c)
        XCTAssertFalse(ok.isReadOnly)
    }

    func test_readOnlySession_saveNowThrowsNotRoundTrippable() throws {
        let (root, c) = try vault()
        let url = try lossyFile(root)
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertThrowsError(try s.saveNow()) { error in
            XCTAssertEqual(error as? EngineError, .notRoundTrippable(url))
        }
    }

    func test_readOnlySession_markChangedDoesNotAutosave() async throws {
        let (root, c) = try vault()
        let url = try lossyFile(root)
        let before = try Data(contentsOf: url)
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! PlainTextEngine).text = "clobbered"
        s.markChanged()
        // Never marked dirty: nothing could ever clear it, and Task 9's close
        // confirmation would nag forever on a file that cannot be saved.
        XCTAssertFalse(s.isDirty)
        // Well past the 500ms autosave debounce.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_readOnlySession_resolutionsAreGuarded() throws {
        let (root, c) = try vault()
        let url = try lossyFile(root)
        let s = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertThrowsError(try s.resolveByOverwriting())
        XCTAssertThrowsError(try s.resolveBySavingCopy())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("bad (Lore copy).txt").path))
    }

    // MARK: - Review finding 1: the session adopts the copy

    func test_resolveBySavingCopy_adoptsTheCopyForSubsequentSaves() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        let copy = try s.resolveBySavingCopy()

        XCTAssertEqual(s.url, copy)
        XCTAssertFalse(s.conflict)
        // Keep typing: it must land in the copy, not re-conflict forever.
        (s.engine as! MarkdownEngine).note.body = "ours again"
        s.markChanged()
        try s.saveNow()
        XCTAssertFalse(s.conflict)
        XCTAssertFalse(s.isDirty)
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("ours again"))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("EXTERNAL"))
    }

    // MARK: - Review finding 2: non-conflict save failures are visible

    func test_nonConflictSaveFailure_setsLastSaveErrorAndKeepsDirty() throws {
        let (root, c) = try vault()
        let dir = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try note(dir, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "ours"
        s.markChanged()

        // A real failure, not a mock: an unwritable directory defeats the
        // atomic write's temp file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        XCTAssertThrowsError(try s.saveNow())
        XCTAssertNotNil(s.lastSaveError)
        XCTAssertFalse(s.conflict)   // not conflated with the conflict path
        XCTAssertTrue(s.isDirty)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try s.saveNow()
        XCTAssertNil(s.lastSaveError)
        XCTAssertFalse(s.isDirty)
    }

    func test_conflictDoesNotSetLastSaveError() throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        Thread.sleep(forTimeInterval: 1.1)
        try "---\nid: a\ntitle: T\n---\nEXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        s.markChanged()
        XCTAssertThrowsError(try s.saveNow())
        XCTAssertTrue(s.conflict)
        XCTAssertNil(s.lastSaveError)
    }

    // MARK: - Review finding 3: the debounce actually fires

    // MARK: - Task 1: isEditable / replaceContents

    func test_engine_defaultsToEditable() throws {
        let url = try tempFile("n.md", "---\ntitle: N\n---\nbody\n")
        let engine = try EngineRegistry.load(url)
        XCTAssertTrue(engine.isEditable)
    }

    func test_replaceContents_copiesMarkdownBody() throws {
        let url = try tempFile("n.md", "---\ntitle: N\n---\nfirst\n")
        let mine = try MarkdownEngine.load(url)
        try "---\ntitle: N\n---\nsecond\n".write(to: url, atomically: true, encoding: .utf8)
        let theirs = try MarkdownEngine.load(url)
        mine.replaceContents(with: theirs)
        XCTAssertEqual(mine.note.body, theirs.note.body)
    }

    func test_lossilyDecodedPlainText_isNotEditable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-ro-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bad.txt")
        try Data([0xFF, 0xFE, 0x41]).write(to: url)
        let engine = try PlainTextEngine.load(url)
        XCTAssertFalse(engine.isEditable)
    }

    func test_markChanged_autosavesAfterTheDebounce() async throws {
        let (root, c) = try vault()
        let url = try note(root, "a.md", "---\nid: a\ntitle: T\n---\nbody")
        let s = try DocumentSession.open(url: url, coordinator: c)
        (s.engine as! MarkdownEngine).note.body = "debounced body"
        s.markChanged()
        XCTAssertTrue(s.isDirty)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("debounced body"))
        // Well past the 500ms debounce.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("debounced body"))
        XCTAssertFalse(s.isDirty)
        XCTAssertNil(s.lastSaveError)
    }
}
