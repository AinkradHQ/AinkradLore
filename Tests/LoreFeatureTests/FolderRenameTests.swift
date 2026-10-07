import XCTest

@testable import LoreFeature

/// Folder rename moves the FOLDER ITSELF, then rewrites links — it is not N
/// independent document moves. These tests pin the reasons why.
@MainActor
final class FolderRenameTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-folder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(
            documents: FakeDocs(),
            indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    @discardableResult
    private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The headline: every document beneath the folder moves, inbound links are
    /// rewritten, and the OLD FOLDER IS GONE. The N-document-moves version left
    /// it behind, empty, in no report.
    func test_folderRenameMovesTheFolderAndRewritesInboundLinks() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        try write(folder, "Notes.md", "---\nid: n\ntitle: Notes\n---\ny")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        await s.settleForTesting()
        try s.rebuild()

        let plan = s.plan(renameFolder: folder, to: "Work")
        XCTAssertEqual(plan.documentMoves.count, 2)
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Work")
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Work/Design]]"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "the old folder survived the rename")
        for name in ["Design.md", "Notes.md"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Work/\(name)").path), name)
        }
    }

    /// The defect that forced the redesign: an attachment no engine claims (so
    /// no index row, so no plan) used to be left behind in the old folder while
    /// the note referencing it moved away. Moving the directory makes that
    /// impossible by construction.
    func test_unindexedFilesAndAttachmentsTravelWithTheFolder() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        let nested = folder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\n![[diagram.png]]")
        // Binary-ish: no engine claims `.png`, so it is a metadata-only row at
        // best and never something `plan` could produce a move for.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: nested.appendingPathComponent("diagram.png"))
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: nested.appendingPathComponent("spec.pdf"))
        await s.settleForTesting()
        try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "Work"))
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        for relative in ["Work/Design.md", "Work/assets/diagram.png", "Work/assets/spec.pdf"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relative).path), relative)
        }
    }

    /// A folder with nothing indexed in it used to yield `[]` plans and a report
    /// that could not be told apart from success. It must rename, and say so.
    func test_folderWithNoIndexedDocumentsStillRenames() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await s.settleForTesting()
        try s.rebuild()

        let plan = s.plan(renameFolder: folder, to: "Renamed")
        XCTAssertTrue(plan.hasNoIndexedDocuments)
        XCTAssertNil(plan.refusal)
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(
            report.movedTo?.lastPathComponent, "Renamed",
            "an empty folder rename must report the move, not nothing")
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Renamed").path))
    }

    /// An existing destination is refused BEFORE anything is written — the same
    /// mass-link-break guard single-document rename has.
    func test_existingDestinationFolderIsRefusedBeforeAnyWrite() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Work"),
            withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        await s.settleForTesting()
        try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "Work"))
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(
            try String(contentsOf: a, encoding: .utf8).contains("[[Projects/Design]]"),
            "links were rewritten for a move that was refused")
    }

    /// A case-only rename resolves to the SAME directory on a case-insensitive
    /// volume (the macOS default), so the "already exists" guard must not
    /// mistake it for a collision.
    func test_caseOnlyFolderRenameIsNotMistakenForACollision() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "projects"))
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.movedTo?.lastPathComponent, "projects")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("projects/Design.md").path))
    }

    /// The third appearance of M1's recurring failure mode, now impossible to
    /// reach: `indexDocument` used to upsert the caller's URL verbatim, so a
    /// document indexed outside a full rescan could sit in the index under a
    /// non-canonical spelling and be dropped from `documentMoves` by a
    /// raw-versus-canonical prefix comparison — no rewrite plan, the file still
    /// travelling with the directory, its inbound links broken, and nothing in
    /// any report bucket.
    ///
    /// Task 8b closed it at the source: indexing via a NON-CANONICAL URL now
    /// STORES a canonical `documents.path`. This test therefore pins the
    /// invariant itself as well as the rename outcome — the setup deliberately
    /// hands `indexDocument` the raw URL and asserts the row came back
    /// canonical anyway.
    func test_documentIndexedUnderANonCanonicalSpellingIsStillPlannedAndRewritten() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let design = try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        await s.settleForTesting()
        try s.rebuild()

        let canonicalDesign = VaultIndexCoordinator.canonical(design)
        try XCTSkipIf(
            canonicalDesign.path == design.path,
            "this machine's temp root is already canonical; nothing to mix")

        // Re-index `Design.md` through the RAW spelling — the exact call any
        // document written outside a full rescan takes. `removeFromIndex` drops
        // the canonical row and the links it is the SOURCE of, so a.md's inbound
        // link survives untouched; the only variable is the URL spelling handed
        // to `indexDocument`.
        try s.coordinator.removeFromIndex(canonicalDesign)
        try s.coordinator.indexDocument(MarkdownEngine.load(design), at: design)
        // THE INVARIANT: the raw URL went in, a canonical row came out.
        XCTAssertTrue(
            s.rows.contains { $0.path.path == canonicalDesign.path },
            "indexDocument stored a non-canonical documents.path")
        XCTAssertFalse(
            s.rows.contains { $0.path.path == design.path },
            "a non-canonical spelling reached documents.path")

        let plan = s.plan(renameFolder: folder, to: "Work")
        XCTAssertEqual(
            plan.documentMoves.count, 1,
            "a non-canonically indexed row fell silently out of the plan")
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertTrue(
            try String(contentsOf: a, encoding: .utf8).contains("[[Work/Design]]"),
            "the inbound link broke silently")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Work/Design.md").path))
    }

    /// The case-only skip must be conditioned on the volume ACTUALLY being
    /// case-insensitive. Whichever kind of volume the tests run on, one of these
    /// two branches is the real one; both are asserted rather than assumed.
    func test_caseOnlySkipIsConditionedOnTheVolumeNotAssumed() async throws {
        let (root, s) = try vault()
        let upper = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        try write(upper, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        // Empirical probe: on a case-insensitive volume the lowercase spelling
        // already "exists", because it is the same directory.
        let caseInsensitive = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("projects").path)

        if caseInsensitive {
            // The skip must apply: this is one directory, not a collision.
            let report = s.apply(s.plan(renameFolder: upper, to: "projects"))
            XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
            XCTAssertEqual(report.movedTo?.lastPathComponent, "projects")
        } else {
            // Case-sensitive volume: `projects` is a genuinely different
            // directory, so an existing one IS a collision and must be refused
            // before any link is rewritten.
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("projects"),
                withIntermediateDirectories: true)
            let report = s.apply(s.plan(renameFolder: upper, to: "projects"))
            XCTAssertNil(report.movedTo, "a real collision was waved through")
            XCTAssertEqual(report.failed.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: upper.path))
        }
    }

    /// Task 7's protection, inherited: a tab holding unsaved edits to a file the
    /// rename would rewrite is EXCLUDED from the write and reported in
    /// `skipped`. The folder still moves — a partial result the caller can see
    /// beats aborting halfway with no record.
    func test_dirtyConflictedTabIsSkippedWhileTheFolderStillMoves() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        try write(folder, "Notes.md", "---\nid: n\ntitle: Notes\n---\ny")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        let b = try write(root, "b.md", "---\nid: b\ntitle: B\n---\n[[Projects/Notes]]")
        await s.settleForTesting()
        try s.rebuild()

        // `a.md` is open, dirty, AND in conflict — so the flush inside apply
        // refuses and its unsaved text must be left strictly alone.
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "a.md" })
        s.open(row)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved [[Projects/Design]]"
        session.markChanged()
        session.cancelPendingSave()
        // Force the conflict: an external write newer than the session baseline.
        try await Task.sleep(for: .milliseconds(1100))
        try "---\nid: a\ntitle: A\n---\nexternal [[Projects/Design]]"
            .write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())
        XCTAssertTrue(session.isDirty)

        let report = s.apply(s.plan(renameFolder: folder, to: "Work"))

        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), ["a.md"])
        // The CAUSE travels with the file: the report must not describe an
        // unsaved-edits skip as somebody else's edit, or vice versa.
        XCTAssertEqual(report.skipped.map(\.reason), [.unsavedEdits])
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["b.md"])
        // Nothing was written to the excluded file, and the tab kept its edits.
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("external"))
        XCTAssertTrue(engine.note.body.contains("unsaved"))
        XCTAssertTrue(session.isDirty)
        // The other document's links were rewritten, and the folder still moved.
        XCTAssertTrue(try String(contentsOf: b, encoding: .utf8).contains("[[Work/Notes]]"))
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Task 7's protection, inherited: a session on a document INSIDE the folder
    /// follows it to the new location, rather than pointing at a path that is
    /// gone and autosaving the file back into existence there.
    func test_openTabOnADocumentInsideTheFolderFollowsIt() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "Design.md" })
        s.open(row)
        let session = try XCTUnwrap(s.selectedTab)

        _ = s.apply(s.plan(renameFolder: folder, to: "Work"))

        XCTAssertEqual(session.url.lastPathComponent, "Design.md")
        XCTAssertEqual(session.url.deletingLastPathComponent().lastPathComponent, "Work")
        XCTAssertEqual(s.tabs.count, 1)
        // A save through the followed session must land at the NEW path and
        // must not recreate the old one.
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "after"
        try session.saveNow()
        XCTAssertTrue(
            try String(
                contentsOf: root.appendingPathComponent("Work/Design.md"),
                encoding: .utf8
            ).contains("after"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Task 7's protection, inherited: a file changed on disk after the plan was
    /// computed is skipped, never overwritten.
    func test_fileChangedOnDiskAfterPlanningIsSkipped() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        await s.settleForTesting()
        try s.rebuild()

        let plan = s.plan(renameFolder: folder, to: "Work")
        try await Task.sleep(for: .milliseconds(1100))
        let external = "---\nid: a\ntitle: A\n---\nedited elsewhere [[Projects/Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)

        let report = s.apply(plan)
        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), ["a.md"])
        // The CAUSE travels with the file: the report must not describe an
        // unsaved-edits skip as somebody else's edit, or vice versa.
        XCTAssertEqual(report.skipped.map(\.reason), [.changedOnDisk])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), external)
    }
}
