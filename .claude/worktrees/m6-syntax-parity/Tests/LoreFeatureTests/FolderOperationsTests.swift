import XCTest
@testable import LoreFeature

/// `LoreStore.forTesting(vaultRoot:)` named in the Task 10 brief does not
/// exist — mirrors `TrashTests.vault()`/`AttachmentWriteTests.store(_:)`,
/// the real seam every store test already uses:
/// `LoreStore(documents:indexPath:)` + `setVaultRootForTesting`, then
/// `settleForTesting()` + `rebuild()` to force a synchronous rescan.
@MainActor
final class FolderOperationsTests: XCTestCase {
    private func vault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-folders-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    // MARK: - createFolder

    func test_createFolder_createsAndRejectsDuplicates() throws {
        let root = try vault()
        let s = try store(root)
        let created = try s.createFolder(named: "Projects", in: root)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertThrowsError(try s.createFolder(named: "Projects", in: root))
    }

    func test_createFolder_rejectsPathSeparators() throws {
        let root = try vault()
        let s = try store(root)
        XCTAssertThrowsError(try s.createFolder(named: "../escape", in: root)) { error in
            guard case LoreError.invalidName = error else {
                return XCTFail("expected .invalidName, got \(error)")
            }
        }
    }

    /// A leading-dot name would be created on disk but never appear in the
    /// sidebar: `VaultIndexCoordinator.scanVault` skips any path component
    /// starting with `.`. Refusing is better than creating a folder the user
    /// cannot see. Also covers `.`/`..`/`...`, all of which start with `.`.
    func test_createFolder_rejectsLeadingDot() throws {
        let root = try vault()
        let s = try store(root)
        for name in [".hidden", ".", "..", "..."] {
            XCTAssertThrowsError(try s.createFolder(named: name, in: root),
                                 "expected \(name) to be rejected") { error in
                guard case LoreError.invalidName = error else {
                    return XCTFail("expected .invalidName for \(name), got \(error)")
                }
            }
        }
    }

    func test_createFolder_rejectsControlCharacters() throws {
        let root = try vault()
        let s = try store(root)
        XCTAssertThrowsError(try s.createFolder(named: "Notes\u{0007}Bell", in: root)) { error in
            guard case LoreError.invalidName = error else {
                return XCTFail("expected .invalidName, got \(error)")
            }
        }
    }

    // MARK: - planTrashFolder / applyTrashFolder — containment

    /// CRITICAL. Without this guard, `applyTrashFolder(planTrashFolder(vaultRoot))`
    /// trashes the entire vault — the only thing stopping it today would be a
    /// UI-layer accident (the root tree node happens to have no folder menu).
    func test_planTrashFolder_refusesTheVaultRootItself() async throws {
        let root = try vault()
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        let plan = s.planTrashFolder(root)
        XCTAssertNotNil(plan.refusal)
        XCTAssertThrowsError(try s.applyTrashFolder(plan))
    }

    func test_planTrashFolder_refusesATargetOutsideTheVault() async throws {
        let root = try vault()
        let outside = try vault() // a second, unrelated temp directory
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        let plan = s.planTrashFolder(outside)
        XCTAssertNotNil(plan.refusal)
        XCTAssertThrowsError(try s.applyTrashFolder(plan)) { error in
            guard case LoreError.outsideVault = error else {
                return XCTFail("expected .outsideVault, got \(error)")
            }
        }
    }

    /// `applyTrashFolder` re-derives the containment guard itself rather than
    /// trusting `plan.refusal` — a plan is a value, and a caller can construct
    /// or replay one that was never planned by `planTrashFolder`. This forges
    /// a plan claiming the vault root as its target with `refusal: nil` and
    /// confirms `apply` still refuses.
    func test_applyTrashFolder_refusesAForgedPlanTargetingTheRoot() async throws {
        let root = try vault()
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        let forged = FolderTrashPlan(folder: VaultIndexCoordinator.canonical(root))
        XCTAssertThrowsError(try s.applyTrashFolder(forged)) { error in
            guard case LoreError.outsideVault = error else {
                return XCTFail("expected .outsideVault, got \(error)")
            }
        }
        // Nothing was touched: the vault root must still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - planTrashFolder — reporting

    func test_trashFolder_reportsWhatItWillTake() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nid: a\ntitle: A\n---\na".write(
            to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: B\n---\nb".write(
            to: folder.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        let plan = s.planTrashFolder(folder)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.documents.count, 2)
    }

    // MARK: - The ordering rule

    /// Direct proof of the mechanism `applyTrashFolder`'s doc comment
    /// describes: `VaultIndexCoordinator.canonical` is `realpath(3)`, which
    /// FAILS on a path that no longer exists and then returns the caller's
    /// RAW argument unchanged — a different string from the canonical
    /// spelling SQLite has on file (`root` here is a `/var/folders/...` path;
    /// its canonical form is `/private/var/folders/...`, the classic macOS
    /// temp-dir split). Removing a row by canonicalizing AFTER the move
    /// therefore uses the wrong spelling and misses it, leaving a ghost row —
    /// canonicalizing BEFORE the move (while the path still resolves) matches
    /// it. This is genuinely order-sensitive: swap the two calls below and
    /// the assertions invert. See the task report for the recorded run of
    /// each order.
    func test_orderingRule_canonicalizingAfterTheMoveMissesTheRow() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("target.md")
        try "---\nid: t\ntitle: Target\n---\nx".write(to: file, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        XCTAssertEqual(s.rows.count, 1)

        // WRONG ORDER: the move happens, THEN the row is canonicalized and
        // removed — using the same raw `file` URL a naive re-derivation
        // (recomputing the document list from a caller-supplied URL after
        // the fact, instead of a plan captured before any mutation) would use.
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        try? s.coordinator.removeFromIndex(file)

        XCTAssertFalse(s.rows.isEmpty,
                       "removal AFTER the move should MISS the row (asserting the hazard, "
                       + "not the fix — see test_orderingRule_canonicalizingBeforeTheMoveFindsTheRow)")
    }

    /// The correct order, same setup, same raw `file` URL: canonicalizing
    /// (and therefore removing) BEFORE the move succeeds, because
    /// `realpath(3)` can still resolve the path. This is what
    /// `applyTrashFolder` does — it captures `plan.documents` (already
    /// canonical, via `planTrashFolder`) BEFORE `trashItem` ever runs.
    func test_orderingRule_canonicalizingBeforeTheMoveFindsTheRow() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("target.md")
        try "---\nid: t\ntitle: Target\n---\nx".write(to: file, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        XCTAssertEqual(s.rows.count, 1)

        // RIGHT ORDER: canonicalize/remove first, move second.
        try? s.coordinator.removeFromIndex(file)
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)

        XCTAssertTrue(s.rows.isEmpty, "removal BEFORE the move should find and remove the row")
    }

    /// End-to-end regression using the real `applyTrashFolder`, confirming it
    /// leaves no ghost row. Not, by itself, order-sensitive to a two-line
    /// swap WITHIN `applyTrashFolder` — see the report's "Critical 1" section
    /// for why (it never recanonicalizes from a raw URL after the move, so
    /// reordering its own two calls does not reproduce the hazard the two
    /// tests above isolate directly). Kept as the integration-level check
    /// that the real code path produces a clean index.
    func test_trashFolder_removesIndexRowsNotJustTheFiles() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nid: t\ntitle: Target\n---\ngone".write(
            to: folder.appendingPathComponent("target.md"), atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
        XCTAssertEqual(s.rows.count, 1)

        let trashed = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertEqual(trashed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(s.rows.isEmpty, "index still carries a row for a trashed file: \(s.rows)")
    }

    // MARK: - Links

    func test_trashFolder_rewritesLinksBeforeMoving() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nid: t\ntitle: Target\n---\ngone".write(
            to: folder.appendingPathComponent("target.md"), atomically: true, encoding: .utf8)
        let referrer = root.appendingPathComponent("keeps.md")
        try "---\nid: k\ntitle: Keeps\n---\nsee [[Target]]".write(
            to: referrer, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        // The referrer survives, and its link is left as an UNRESOLVED link to
        // a name — not silently deleted, not pointing into the trash.
        let text = try String(contentsOf: referrer, encoding: .utf8)
        XCTAssertTrue(text.contains("[[Target]]"))
        XCTAssertEqual(s.unresolvedLinks(from: referrer).count, 1)
    }

    // MARK: - Open tabs

    func test_trashFolder_disarmsPendingSaveAndClosesOpenTab() async throws {
        let root = try vault()
        let folder = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = folder.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        let s = try store(root)
        await s.settleForTesting(); try s.rebuild()
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
        await s.settleForTesting(); try s.rebuild()
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

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path),
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
        await s.settleForTesting(); try s.rebuild()
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
        await s.settleForTesting(); try s.rebuild()

        // Created AFTER the rescan: it is a real open tab, but not in `rows`.
        let fresh = folder.appendingPathComponent("fresh.md")
        try "---\nid: f\ntitle: F\n---\nx".write(to: fresh, atomically: true, encoding: .utf8)
        s.open(url: fresh)
        XCTAssertFalse(s.rows.contains { $0.path.lastPathComponent == "fresh.md" },
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
        await s.settleForTesting(); try s.rebuild()
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
        await s.settleForTesting(); try s.rebuild()

        // Created AFTER the rescan: a real file, but NOT in `s.rows`.
        let doc = folder.appendingPathComponent("fresh.md")
        try "---\nid: f\ntitle: F\n---\nx".write(to: doc, atomically: true, encoding: .utf8)
        XCTAssertFalse(s.rows.contains { $0.path.lastPathComponent == "fresh.md" },
                       "the fixture must NOT be indexed yet, or this test proves nothing")

        // Populate the legacy mtime baseline directly, keyed CANONICALLY —
        // `load` only needs a row SHAPED like the file, not one that is
        // actually present in `s.rows`.
        let canonicalDoc = VaultIndexCoordinator.canonical(doc)
        let manualRow = IndexRow(path: canonicalDoc, id: "f", title: "F", tags: [], aliases: [],
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
        XCTAssertFalse(s.externalChangeDetected(for: restored),
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
        await s.settleForTesting(); try s.rebuild()
        let outsiderRow = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "elsewhere.md" })

        let forged = FolderTrashPlan(folder: VaultIndexCoordinator.canonical(folder),
                                     documents: [outsiderRow])
        _ = try s.applyTrashFolder(forged)

        XCTAssertTrue(s.rows.contains { $0.path.lastPathComponent == "elsewhere.md" },
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
        await s.settleForTesting(); try s.rebuild()
        XCTAssertTrue(s.directoryPaths.contains("Parent/Q1"))

        _ = try s.applyTrashFolder(s.planTrashFolder(parent))

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertFalse(s.directoryPaths.contains("Parent"),
                       "the trashed folder must not survive as a ghost node: \(s.directoryPaths)")
        XCTAssertFalse(s.directoryPaths.contains("Parent/Q1"),
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
        await s.settleForTesting(); try s.rebuild()
        XCTAssertTrue(s.directoryPaths.contains("Parent/Q1"))

        let plan = s.plan(renameFolder: parent, to: "Renamed")
        XCTAssertNil(plan.refusal)
        let report = s.apply(plan)
        XCTAssertTrue(report.failed.isEmpty, "rename must not fail: \(report.failed)")

        XCTAssertFalse(s.directoryPaths.contains("Parent"),
                       "the old folder name must not survive as a ghost node: \(s.directoryPaths)")
        XCTAssertFalse(s.directoryPaths.contains("Parent/Q1"),
                       "nor should its old-named subfolder: \(s.directoryPaths)")
        XCTAssertTrue(s.directoryPaths.contains("Renamed"),
                      "the new name must be visible: \(s.directoryPaths)")
        XCTAssertTrue(s.directoryPaths.contains("Renamed/Q1"),
                      "and its empty subfolder must have moved with it, not gone missing: "
                      + "\(s.directoryPaths)")
    }
}
