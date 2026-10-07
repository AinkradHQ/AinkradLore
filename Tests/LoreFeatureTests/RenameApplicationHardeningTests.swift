import XCTest

@testable import LoreFeature

/// The four defects the Task 7 review found after the first pass.
@MainActor
final class RenameApplicationHardeningTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        try makeRenameVault(prefix: "lore-rename2")
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        try writeRenameFixture(root, name, text)
    }

    /// FINDING 1. A tab that is dirty AND already conflicted cannot flush: its
    /// `saveNow` re-throws `externalChange`. The plan-time baseline was
    /// captured AFTER that external edit, so the mtime guard would let the
    /// rewrite through and the post-rewrite reload would then replace the
    /// engine's contents — silently destroying the user's unsaved text.
    func test_dirtyConflictedTabKeepsUnsavedTextAndIsReportedAsSkipped() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        s.open(url: a)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "UNSAVED WORK\n\nsee [[Design]]"
        session.markChanged()
        session.cancelPendingSave()

        // An external edit lands BEFORE planning, so the session is already in
        // conflict and the plan-time baseline already reflects that edit.
        try await Task.sleep(for: .seconds(1.1))
        let external = "---\nid: a\ntitle: A\n---\nEXTERNAL [[Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())
        XCTAssertTrue(session.conflict)
        XCTAssertTrue(session.isDirty)

        let report = s.apply(s.plan(rename: design, to: "Architecture"))

        // The file was not written...
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), external)
        // ...the outcome is in the report...
        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), ["a.md"])
        // The CAUSE travels with the file: the report must not describe an
        // unsaved-edits skip as somebody else's edit, or vice versa.
        XCTAssertEqual(report.skipped.map(\.reason), [.unsavedEdits])
        XCTAssertFalse(report.rewritten.contains { $0.lastPathComponent == "a.md" })
        // ...and the unsaved text is still in the editor, still conflicted,
        // for the user to resolve themselves.
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.conflict)
        XCTAssertTrue(engine.note.body.contains("UNSAVED WORK"))
    }

    /// FINDING 2. `moveItem` can fail for reasons other than a collision. A
    /// missing destination folder must be refused BEFORE any link is rewritten.
    func test_moveIntoMissingFolderRefusesAndWritesNothing() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Projects/Design]]")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let design = try write(
            root, "Projects/Design.md",
            "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        let missing = root.appendingPathComponent("Nope")
        let plan = s.plan(move: design, toFolder: missing)
        XCTAssertFalse(plan.edits.isEmpty, "precondition: there is something to rewrite")

        let report = s.apply(plan)
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.rewritten, [])
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Projects/Design]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// FINDING 3. A self-linking document is both the move source and a rewrite
    /// target. Matching sessions by path after `adoptRenamed` never finds it,
    /// so it kept pre-rewrite text and its next save reverted the self-link.
    func test_selfLinkingDocumentSurvivesRenameAcrossItsNextSave() async throws {
        let (root, s) = try vault()
        let design = try write(
            root, "Design.md",
            "---\nid: d\ntitle: Design\n---\nsee [[Design]] here")
        await s.settleForTesting()
        try s.rebuild()

        s.open(url: design)
        let session = try XCTUnwrap(s.selectedTab)
        let plan = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(plan.edits.count, 1, "precondition: the self-link is an edit")

        _ = s.apply(plan)
        let moved = root.appendingPathComponent("Architecture.md")
        XCTAssertEqual(session.url.lastPathComponent, "Architecture.md")
        XCTAssertTrue(try String(contentsOf: moved, encoding: .utf8).contains("[[Architecture]]"))

        // The real regression: the session's next save must not write a stale
        // pre-rewrite buffer back over the rewrite.
        session.markChanged()
        session.cancelPendingSave()
        try session.saveNow()
        let text = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertTrue(text.contains("[[Architecture]]"), text)
        XCTAssertFalse(text.contains("[[Design]]"), text)
    }

    /// FINDING 4. "Opened it and nothing matched" is neither a write nor a
    /// refusal, and reporting it as `rewritten` makes the report untruthful.
    func test_applyEditsDistinguishesWrittenUnchangedAndSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outcome-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.md")
        try "see [[Design]]".write(to: file, atomically: true, encoding: .utf8)
        let baseline = try XCTUnwrap(
            FileManager.default
                .attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        let hit = [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture")]
        let miss = [LinkEdit(file: file, oldTarget: "Nothing", newTarget: "Else")]

        // Nothing matches: unchanged, and the file is left byte-identical.
        XCTAssertEqual(
            try LinkRewriter.applyEdits(miss, to: file, baseline: baseline),
            .unchanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // No baseline: fail closed.
        XCTAssertEqual(
            try LinkRewriter.applyEdits(hit, to: file, baseline: nil),
            .skipped(.unverifiable))
        // Stale baseline: refuse.
        XCTAssertEqual(
            try LinkRewriter.applyEdits(
                hit, to: file,
                baseline: .distantPast),
            .skipped(.changedOnDisk))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // A real match writes.
        XCTAssertEqual(
            try LinkRewriter.applyEdits(hit, to: file, baseline: baseline),
            .written)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Architecture]]")
    }

    /// MINOR. The moved file, when it was itself rewritten, must be reported at
    /// its NEW path — the old one no longer exists by the time the UI renders.
    func test_reportNamesTheMovedFileAtItsNewPath() async throws {
        let (root, s) = try vault()
        let design = try write(
            root, "Design.md",
            "---\nid: d\ntitle: Design\n---\nsee [[Design]]")
        await s.settleForTesting()
        try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["Architecture.md"])
        for url in report.rewritten {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    /// The other half of the same root cause: an edit's file spelling need not
    /// match the canonical session URL the exclude-dirty-tabs check compares
    /// against. Keyed raw, the check never fires and the file is rewritten out
    /// from under a tab holding unsaved edits — defeating the protection
    /// entirely. `LoreStore+Rename.swift`'s `pathKey`-keyed `editedByFile` /
    /// session loop is what prevents it.
    ///
    /// ## Why the plan is hand-built (Task 8b)
    ///
    /// This test used to create the mixed spelling by re-indexing `a.md` through
    /// a RAW URL — and that premise is now UNREACHABLE, because `indexDocument`
    /// canonicalizes. Left as it was, the test passed vacuously and the
    /// `pathKey` check had no mixed-spelling coverage at all.
    ///
    /// So the condition is constructed through the path that CAN still produce
    /// it: `RenamePlan` and `LinkEdit` are both public, so Task 10's preview UI
    /// (or any future caller) can hand `apply` an edit whose `file` carries any
    /// spelling it likes. That is precisely the input `pathKey` exists to
    /// normalize, and it is the only remaining way in — which is the point: the
    /// invariant covers everything the STORE writes, not everything a caller can
    /// construct.
    func test_dirtyTabBlocksTheRewriteEvenWhenTheIndexSpellsTheFileDifferently() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        let canonicalA = VaultIndexCoordinator.canonical(a)
        try XCTSkipIf(
            canonicalA.path == a.path,
            "this machine's temp root is already canonical; nothing to mix")

        // The tab is opened under the CANONICAL spelling, and the plan's edit
        // will name the RAW one, so its session path and the edit-file path
        // disagree. It is left DIRTY but not
        // conflicted, so the flush inside `apply` succeeds — which is what makes
        // this test discriminating. A conflicted session would land in `skipped`
        // either way (a mismatched key also means a missing baseline, and
        // `applyEdits` fails closed on that), so the outcome would look correct
        // while the exclude-dirty-tabs machinery never ran at all.
        //
        // With the session correctly matched, `apply` flushes it first, so the
        // unsaved text reaches disk and the rewrite is applied ON TOP of it.
        // With the paths compared raw, the session is never seen: not flushed,
        // not disarmed, and its unsaved text is absent from the rewritten file
        // while an armed autosave still holds pre-rewrite content.
        s.open(url: canonicalA)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit, see [[Design]]"
        session.markChanged()
        session.cancelPendingSave()
        XCTAssertTrue(session.isDirty)

        // The plan as the store computes it (edits canonically spelled, since
        // `inboundLinks` canonicalizes what it returns), re-emitted with the edit
        // file spelled RAW. Everything else — source, destination, unrewritable,
        // and the CANONICALLY keyed baselines — is carried over untouched, so the
        // only variable is the edit's spelling. Keeping the real baselines is
        // what makes the test discriminating: with a raw baseline key too, the
        // broken code would fail closed in `applyEdits` (a missing baseline is
        // treated as unsafe-to-write) and land in `skipped` for the RIGHT reason
        // while the exclude-dirty-tabs machinery never ran — the exact
        // right-outcome-wrong-mechanism trap the previous round caught.
        let computed = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(
            computed.edits.map(\.file.path), [canonicalA.path],
            "the store's own plan should already be canonical")
        let plan = RenamePlan(
            source: computed.source, destination: computed.destination,
            edits: computed.edits.map {
                LinkEdit(file: a, oldTarget: $0.oldTarget, newTarget: $0.newTarget)
            },
            unrewritable: computed.unrewritable, baselines: computed.baselines,
            refusal: computed.refusal)

        let report = s.apply(plan)

        XCTAssertFalse(
            session.isDirty,
            "the session was never seen by apply, so it was never flushed")
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["a.md"])
        let onDisk = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(
            onDisk.contains("unsaved edit"),
            "the tab's unsaved text was not flushed before the rewrite")
        XCTAssertTrue(onDisk.contains("[[Architecture]]"), onDisk)
        XCTAssertFalse(onDisk.contains("[[Design]]"), onDisk)
        // The session was reloaded, so its next save cannot revert the rewrite.
        XCTAssertTrue(engine.note.body.contains("[[Architecture]]"), engine.note.body)
    }

    // MARK: - name validation
    //
    // `newName` is a basename, never a path. Unvalidated it builds a
    // destination outside the folder's parent — and a folder rename's
    // destination tree does not exist yet, so any
    // `createDirectory(withIntermediateDirectories:)` on that path
    // MATERIALIZES the escape where a bare `moveItem` would have failed.

    func test_invalidNewNamesAreRefusedWithoutWritingOrCreatingAnything() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        let before = try String(contentsOf: a, encoding: .utf8)
        await s.settleForTesting()
        try s.rebuild()

        for name in ["", "..", "../escape", "a/b", "."] {
            let plan = s.plan(rename: design, to: name)
            XCTAssertNotNil(plan.refusal, "“\(name)” must be refused")
            XCTAssertTrue(plan.edits.isEmpty, "“\(name)” planned edits")

            let report = s.apply(plan)
            XCTAssertEqual(report.failed.count, 1, "“\(name)”")
            XCTAssertNil(report.movedTo, "“\(name)” moved a file")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: design.path),
                "“\(name)” moved the source away")
            XCTAssertEqual(
                try String(contentsOf: a, encoding: .utf8), before,
                "“\(name)” rewrote a link")
        }
        // Nothing was created anywhere: the vault holds exactly the two files.
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(contents, ["Design.md", "a.md"])
        // …and nothing escaped into the parent directory either.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("escape.md").path))
    }

    func test_invalidFolderNamesAreRefusedWithoutMovingTheFolder() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        for name in ["", "..", "../escape", "a/b"] {
            let plan = s.plan(renameFolder: folder, to: name)
            XCTAssertNotNil(plan.refusal, "“\(name)” must be refused")
            XCTAssertTrue(plan.documentMoves.isEmpty, "“\(name)” planned moves")
            let report = s.apply(plan)
            XCTAssertNil(report.movedTo, "“\(name)” moved the folder")
            XCTAssertEqual(report.failed.count, 1, "“\(name)”")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }
}
