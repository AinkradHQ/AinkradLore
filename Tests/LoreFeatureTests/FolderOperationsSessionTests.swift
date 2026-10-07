import XCTest

@testable import LoreFeature

/// The open-tab, untracked-session and directory-listing half of
/// `FolderOperationsTests` — an extension, so `vault()` and `store(_:)` are shared.
extension FolderOperationsTests {
    // MARK: - Open tabs

    func test_trashFolder_disarmsPendingSaveAndClosesOpenTab() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = folder.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        s.open(url: doc)
        XCTAssertEqual(s.tabs.count, 1)

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertTrue(s.tabs.isEmpty)
    }

    /// CRITICAL. A dirty tab whose flush cannot succeed must REFUSE the whole
    /// folder trash, exactly like `LoreStore.trash` refuses a single document
    /// in the same situation (`TrashTests.test_trashRefusesWhenATabStillHoldsUnsavedEdits`).
    /// Before this fix, `applyTrashFolder` disarmed the pending save, trashed
    /// the folder, then force-closed the tab — `saveNow()` into the now-gone
    /// parent directory failed and was swallowed by `force: true`, destroying
    /// the unsaved edit with no message.
    func test_trashFolder_refusesWhenATabHoldsUnsavedEditsThatCannotBeSaved() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = folder.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        s.open(url: doc)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit"
        session.markChanged()
        session.cancelPendingSave()

        // Drive the session into conflict, which is what makes the flush refuse
        // — same recipe as `TrashTests.test_trashRefusesWhenATabStillHoldsUnsavedEdits`.
        try await Task.sleep(for: .milliseconds(1100))
        let external = "---\nid: a\ntitle: A\n---\nsomebody else"
        try external.write(to: doc, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())
        XCTAssertTrue(session.conflict)

        XCTAssertThrowsError(try s.applyTrashFolder(s.planTrashFolder(folder))) { error in
            guard case LoreError.unsavedEdits = error else {
                return XCTFail("expected .unsavedEdits, got \(error)")
            }
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "the folder was trashed despite the refusal")
        XCTAssertEqual(s.tabs.count, 1, "the tab was closed despite the refusal")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(engine.note.body, "unsaved edit", "the unsaved text was destroyed")
    }

    /// The preview surfaces the count BEFORE the user confirms — a silent
    /// refusal after a confirm click reads as a broken button.
    func test_planTrashFolder_reportsDirtySessionCount() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = folder.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        s.open(url: doc)
        let session = try XCTUnwrap(s.selectedTab)
        (session.engine as? MarkdownEngine)?.note.body = "unsaved"
        session.markChanged()

        let plan = s.planTrashFolder(folder)
        XCTAssertEqual(plan.dirtySessionCount, 1)
    }

    // MARK: - Untracked / unindexed sessions (Important 4)

    /// A tab open on a file the index has not reached yet (created since the
    /// last rescan, so it is not in `plan.documents`) must still be disarmed
    /// and closed — its session set is derived from open tabs' own URLs
    /// tested for subtree containment, not from the index rows.
    func test_trashFolder_disarmsAndClosesATabNotYetInTheIndex() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let indexed = folder.appendingPathComponent("indexed.md")
        try "---\nid: i\ntitle: I\n---\nx".write(to: indexed, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()

        // Created AFTER the rescan: it is a real open tab, but not in `rows`.
        let fresh = folder.appendingPathComponent("fresh.md")
        try "---\nid: f\ntitle: F\n---\nx".write(to: fresh, atomically: true, encoding: .utf8)
        s.open(url: fresh)
        XCTAssertFalse(
            s.rows.contains { $0.path.lastPathComponent == "fresh.md" },
            "the fixture must NOT be indexed yet, or this test proves nothing")
        XCTAssertEqual(s.tabs.count, 1)

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertTrue(s.tabs.isEmpty, "the untracked tab was left open")
    }

    /// A sibling folder sharing a name prefix (`Old2`) must NOT be treated as
    /// contained in `Old` — the containment check uses a trailing-slash
    /// prefix, not a raw string prefix.
    func test_trashFolder_doesNotMatchASiblingWithASharedPrefix() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        let sibling = root.appendingPathComponent("Old2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingDoc = sibling.appendingPathComponent("keep.md")
        try "---\nid: k\ntitle: K\n---\nx".write(to: siblingDoc, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        s.open(url: siblingDoc)

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertEqual(s.tabs.count, 1, "the sibling folder's tab must not be touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDoc.path))
    }

    // MARK: - Fix round 2

    /// Genuinely order-sensitive, unlike `plan.documents[].path`:
    /// `DocumentSession` never canonicalizes the URL it was opened with, so
    /// `forgetOpenMTime(session.url)` MUST run while the folder still exists,
    /// or `VaultIndexCoordinator.canonical` cannot resolve the vanished path
    /// and falls back to the session's raw (here, non-canonical —
    /// `root` comes from `FileManager.default.temporaryDirectory`, which is
    /// `/var/folders/...`, distinct from its `/private/var/folders/...`
    /// realpath) spelling, which misses the CANONICALLY-keyed baseline `load`
    /// set below. Observed indirectly through the public
    /// `externalChangeDetected(for:)`, since `openMTimes` itself is private:
    /// a correctly forgotten baseline means NO entry exists, so
    /// `externalChangeDetected` is `false` no matter what the recreated
    /// file's mtime is; a stale, un-forgotten baseline (always OLDER than a
    /// file recreated afterward) makes it misfire `true`.
    ///
    /// The fixture is deliberately a file NOT in `s.rows`: the FIRST cut of
    /// this test used an indexed file, and it passed under BOTH orderings —
    /// the row-based loop (`for row in documents { ... forgetOpenMTime(row.path)
    /// }`, always order-insensitive, see the function's doc comment) had
    /// already cleared the very same canonical key, making the
    /// session-based call redundant and the test blind to its ordering.
    /// Using an unindexed file removes that overlap: the ONLY loop that can
    /// clear this baseline is the session-based one.
    func test_trashFolder_forgetsSessionMTimeBeforeTheMoveNotAfter() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()

        // Created AFTER the rescan: a real file, but NOT in `s.rows`.
        let doc = folder.appendingPathComponent("fresh.md")
        try "---\nid: f\ntitle: F\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        XCTAssertFalse(
            s.rows.contains { $0.path.lastPathComponent == "fresh.md" },
            "the fixture must NOT be indexed yet, or this test proves nothing")

        // Populate the legacy mtime baseline directly, keyed CANONICALLY —
        // `load` only needs a row SHAPED like the file, not one that is
        // actually present in `s.rows`.
        let canonicalDoc = VaultIndexCoordinator.canonical(doc)
        let manualRow = IndexRow(
            path: canonicalDoc, id: "f", title: "F", tags: [], aliases: [],
            updated: Date(), type: MarkdownEngine.identifier, properties: [])
        _ = try s.load(manualRow)

        // Opened via the RAW (non-canonical) `doc` URL — the exact condition
        // `forgetOpenMTime(session.url)` must handle correctly.
        s.open(url: doc)
        XCTAssertEqual(s.tabs.count, 1)

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))

        // Recreate a file at the SAME path — the "restored from Trash" case
        // `transferOpenMTime`'s own doc comment warns about.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nid: f\ntitle: F\n---\nrestored".write(to: doc, atomically: true, encoding: .utf8)
        let restored = Frontmatter.parse(try String(contentsOf: doc, encoding: .utf8), path: doc)
        XCTAssertFalse(
            s.externalChangeDetected(for: restored),
            "a stale mtime baseline survived the trash and misfired on the "
                + "recreated file — forgetOpenMTime(session.url) likely ran too late")
    }

    /// A forged `FolderTrashPlan` — a legitimate, in-vault `folder` paired
    /// with a `documents` list containing a row from OUTSIDE that folder —
    /// must not have that outside row's index entry removed. Only
    /// `plan.folder` itself is ever passed to `trashItem`, so no FILE is at
    /// risk here; this is specifically about index-only damage.
    func test_applyTrashFolder_ignoresDocumentsOutsideTheForgedPlansFolder() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outsider = root.appendingPathComponent("elsewhere.md")
        try "---\nid: e\ntitle: E\n---\nx".write(to: outsider, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        let outsiderRow = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "elsewhere.md" })

        let forged = FolderTrashPlan(
            folder: VaultIndexCoordinator.canonical(folder),
            documents: [outsiderRow])
        _ = try s.applyTrashFolder(forged)

        XCTAssertTrue(
            s.rows.contains { $0.path.lastPathComponent == "elsewhere.md" },
            "a document outside the trashed folder was removed from the index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path))
    }

    // MARK: - directoryPaths (whole-branch review round 4, Critical)

    /// Trashing a folder must not leave it as a ghost node in
    /// `directoryPaths`. Goes through the REAL `applyTrashFolder` API — no
    /// manual rebuild — the shape the reviewer's probe used to reproduce the
    /// bug (`directoryPaths after trash = ["Parent/Q1"]` with the directory
    /// already gone from disk). Nested one level — the recursive
    /// `FolderWatcher` would eventually see this too, but only after its
    /// coalescing latency and a full rescan, so this test still goes through
    /// the synchronous `noteDirectoryRemoved` path, not the watcher.
    func test_applyTrashFolder_removesTheFolderFromDirectoryPaths() async throws {
        let root = try vault()
        let parent = root.appendingPathComponent("Parent")
        let child = parent.appendingPathComponent("Q1")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertTrue(s.directoryPaths.contains("Parent/Q1"))

        _ = try s.applyTrashFolder(s.planTrashFolder(parent))

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertFalse(
            s.directoryPaths.contains("Parent"),
            "the trashed folder must not survive as a ghost node: \(s.directoryPaths)")
        XCTAssertFalse(
            s.directoryPaths.contains("Parent/Q1"),
            "a subfolder of the trashed folder must not survive either: "
                + "\(s.directoryPaths)")
    }

    /// Renaming a folder must retire the OLD name from `directoryPaths` and
    /// carry its empty subfolders over to the NEW name — through the real
    /// `plan(renameFolder:to:)`/`apply(_:)` API, no manual rebuild.
    func test_renameFolder_updatesDirectoryPathsForOldAndNewNames() async throws {
        let root = try vault()
        let parent = root.appendingPathComponent("Parent")
        let child = parent.appendingPathComponent("Q1")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertTrue(s.directoryPaths.contains("Parent/Q1"))

        let plan = s.plan(renameFolder: parent, to: "Renamed")
        XCTAssertNil(plan.refusal)
        let report = s.apply(plan)
        XCTAssertTrue(report.failed.isEmpty, "rename must not fail: \(report.failed)")

        XCTAssertFalse(
            s.directoryPaths.contains("Parent"),
            "the old folder name must not survive as a ghost node: \(s.directoryPaths)")
        XCTAssertFalse(
            s.directoryPaths.contains("Parent/Q1"),
            "nor should its old-named subfolder: \(s.directoryPaths)")
        XCTAssertTrue(
            s.directoryPaths.contains("Renamed"),
            "the new name must be visible: \(s.directoryPaths)")
        XCTAssertTrue(
            s.directoryPaths.contains("Renamed/Q1"),
            "and its empty subfolder must have moved with it, not gone missing: "
                + "\(s.directoryPaths)")
    }
}
