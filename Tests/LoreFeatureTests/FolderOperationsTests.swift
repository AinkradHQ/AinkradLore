import XCTest

@testable import LoreFeature

/// `LoreStore.forTesting(vaultRoot:)` named in the Task 10 brief does not
/// exist — mirrors `TrashTests.vault()`/`AttachmentWriteTests.store(_:)`,
/// the real seam every store test already uses:
/// `LoreStore(documents:indexPath:)` + `setVaultRootForTesting`, then
/// `settleForTesting()` + `rebuild()` to force a synchronous rescan.
@MainActor
final class FolderOperationsTests: XCTestCase {
    func vault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-folders-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func store(_ root: URL) throws -> LoreStore {
        let s = LoreStore(
            documents: FakeDocs(),
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
        XCTAssertTrue(
            FileManager.default.fileExists(
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
            XCTAssertThrowsError(
                try s.createFolder(named: name, in: root),
                "expected \(name) to be rejected"
            ) { error in
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
        await s.settleForTesting()
        try s.rebuild()
        let plan = s.planTrashFolder(root)
        XCTAssertNotNil(plan.refusal)
        XCTAssertThrowsError(try s.applyTrashFolder(plan))
    }

    func test_planTrashFolder_refusesATargetOutsideTheVault() async throws {
        let root = try vault()
        let outside = try vault()  // a second, unrelated temp directory
        let s = try store(root)
        await s.settleForTesting()
        try s.rebuild()
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
        await s.settleForTesting()
        try s.rebuild()
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
        await s.settleForTesting()
        try s.rebuild()
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
        await s.settleForTesting()
        try s.rebuild()
        XCTAssertEqual(s.rows.count, 1)

        // WRONG ORDER: the move happens, THEN the row is canonicalized and
        // removed — using the same raw `file` URL a naive re-derivation
        // (recomputing the document list from a caller-supplied URL after
        // the fact, instead of a plan captured before any mutation) would use.
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        try? s.coordinator.removeFromIndex(file)

        XCTAssertFalse(
            s.rows.isEmpty,
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
        await s.settleForTesting()
        try s.rebuild()
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
        await s.settleForTesting()
        try s.rebuild()
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
        await s.settleForTesting()
        try s.rebuild()

        _ = try s.applyTrashFolder(s.planTrashFolder(folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        // The referrer survives, and its link is left as an UNRESOLVED link to
        // a name — not silently deleted, not pointing into the trash.
        let text = try String(contentsOf: referrer, encoding: .utf8)
        XCTAssertTrue(text.contains("[[Target]]"))
        XCTAssertEqual(s.unresolvedLinks(from: referrer).count, 1)
    }
}
