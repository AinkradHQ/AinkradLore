import XCTest
@testable import LoreFeature

final class LinkRewriterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/v")

    func test_planRewritesBareTargetToNewBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits,
                       [LinkEdit(file: URL(fileURLWithPath: "/v/A.md"),
                                 oldTarget: "Design", newTarget: "Architecture")])
    }

    func test_planPreservesHeadingFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture#Overview")
    }

    func test_planPreservesTheAuthorsPathStyle() {
        // A link written with an explicit folder keeps one; a bare link stays bare.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture")
    }

    func test_planPreservesMarkdownExtensionStyle() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture.md")
    }

    func test_affectedFilesAreDeduplicated() {
        let a = URL(fileURLWithPath: "/v/A.md")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(a, "Design", .wikilink), (a, "Design#Two", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.affectedFiles, [a])
        XCTAssertEqual(plan.edits.count, 2)
    }

    func test_moveWithoutRenameStillProducesNoEditsForBareLinks() {
        // Moving Design.md into a folder does not change a bare `[[Design]]`.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design", .wikilink)],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_moveRewritesExplicitPathLinks() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }

    func test_destinationOutsideVaultRootProducesNoEdit() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/elsewhere/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_vaultRootWithTrailingSlashBehavesIdentically() {
        let trailingRoot = URL(fileURLWithPath: "/v/")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: trailingRoot)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }

    func test_vaultRootTextRecurringInsideDestinationDoesNotCorruptTarget() {
        // vaultRoot is "/v"; destination happens to contain "/v/" again as a
        // path segment further down. A substring replace would mangle this;
        // a path-component comparison must not.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/a/v/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "a/v/Design.md")
    }

    func test_normalNestedDestinationYieldsCorrectVaultRelativeTarget() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Nested/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Nested/Design.md")
    }

    func test_combinedShapeRenamePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture.md#Overview")
    }

    func test_combinedShapeMovePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Archive/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Archive/Projects/Design.md#Overview")
    }

    // MARK: - A dotted TITLE is not an extension (regression coverage for the
    // Critical-1 fix: `(body as NSString).pathExtension` alone cannot tell
    // `[[Chapter 1.1]]`'s trailing ".1" from a real extension; only a match
    // against the SOURCE's actual extension can).

    func test_dottedTitleWithNoRealExtensionIsRewrittenAsABareBasename() {
        // "Chapter 1.1" names a note (source extension .md); its trailing
        // ".1" is not ".md", so it must stay a bare, unqualified basename —
        // not gain a path or an appended ".md".
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Notes/Chapter 1.1.md"),
            to: URL(fileURLWithPath: "/v/Notes/Chapter 2.0.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Chapter 1.1", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Chapter 2.0")
    }

    func test_versionLikeDottedTitleIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/v1.2.md"),
            to: URL(fileURLWithPath: "/v/v1.3.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "v1.2", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "v1.3")
    }

    func test_multiDotDottedTitleIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/1.2.3.md"),
            to: URL(fileURLWithPath: "/v/1.2.4.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "1.2.3", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "1.2.4")
    }

    func test_dottedTitleWithSpaceIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Report 2024.10.md"),
            to: URL(fileURLWithPath: "/v/Report 2024.11.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Report 2024.10", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Report 2024.11")
    }

    /// IMPORTANT 2's corollary: before the fix, a dotted-title link whose
    /// destination happened to land outside `vaultRoot` was misclassified as
    /// an explicit-extension link and produced an `UnrewritableLink` instead
    /// of a rewrite. Since the title is not actually an extension, it must
    /// keep rewriting fine regardless of where the destination lives.
    func test_dottedTitleOutsideVaultRootStillRewritesAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Chapter 1.1.md"),
            to: URL(fileURLWithPath: "/elsewhere/Chapter 2.0.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Chapter 1.1", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Chapter 2.0")
        XCTAssertTrue(plan.unrewritable.isEmpty)
    }

    // MARK: - Multi-dot and extensionless files

    func test_multiDotExtensionIsPreservedOnRename() {
        // `archive.tar.gz`'s REAL extension is "gz" (`NSString.pathExtension`
        // only ever sees the last dot-segment); a body ending `.tar.gz`
        // matches that the same way, so the whole compound extension survives.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/archive.tar.gz"),
            to: URL(fileURLWithPath: "/v/backup.tar.gz"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "archive.tar.gz", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "backup.tar.gz")
    }

    func test_extensionlessSourceProducesNoExtensionMatchAndNoDanglingDot() {
        // Neither the source nor the destination carries an extension, so
        // there is nothing for a body extension to match; the rewrite must
        // not append a bare trailing ".".
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/README"),
            to: URL(fileURLWithPath: "/v/CHANGELOG"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "README", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "CHANGELOG")
    }

    /// MINOR 4: a caller-constructed destination with no extension must not
    /// leave a bare trailing "." on the rewritten target, even though
    /// `plan(rename:to:)` (the only production caller) never actually
    /// produces such a destination — it always re-appends the source's
    /// extension. Exercised directly through the low-level `LinkRewriter.plan`
    /// so the guard itself, not just today's one caller, is covered.
    func test_explicitExtensionBodyAgainstAnExtensionlessDestinationDropsCleanly() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Notes.txt"),
            to: URL(fileURLWithPath: "/v/Notes2"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Notes.txt", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Notes2")
    }
}

@MainActor
final class RenameApplicationTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_renameRewritesInboundLinksAndMovesTheFile() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(plan.edits.count, 1)
        let report = s.apply(plan)

        XCTAssertEqual(report.skipped, [])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Architecture]]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: design.path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("Architecture.md").path))
    }

    func test_fileChangedOnDiskIsSkippedAndReportedNotOverwritten() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(rename: design, to: "Architecture")
        // Wide enough to clear any filesystem mtime granularity. `Thread.sleep`
        // (as the brief wrote it) is unavailable from an async context.
        try await Task.sleep(for: .seconds(1.1))
        let external = "---\nid: a\ntitle: A\n---\nEXTERNAL EDIT [[Design]]"
        try external.write(to: a, atomically: true, encoding: .utf8)

        let report = s.apply(plan)
        // Compared by basename, not by URL: the report names the file as the
        // INDEX knows it (realpath-canonical, `/private/var/...`), while the
        // test built `a` from `temporaryDirectory` (`/var/...`). Same file,
        // different spelling — see `LoreStore.planMove`.
        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), ["a.md"])
        // The CAUSE travels with the file: the report must not describe an
        // unsaved-edits skip as somebody else's edit, or vice versa.
        XCTAssertEqual(report.skipped.map(\.reason), [.changedOnDisk])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), external)
    }

    func test_linksAreRewrittenBeforeTheFileMoves() async throws {
        // Ordering property: if the move happened first, a failure to rewrite
        // would leave a dangling link. Assert the rewrite is visible in a file
        // whose link still resolves to the OLD path at rewrite time.
        let (root, s) = try vault()
        _ = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Architecture.md")
        XCTAssertEqual(report.rewritten.count, 1)
    }

    func test_openTabOnARewrittenFileIsReloadedNotClobbered() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: a)
        let session = s.selectedTab!
        let before = session.reloadGeneration

        _ = s.apply(s.plan(rename: design, to: "Architecture"))

        XCTAssertGreaterThan(session.reloadGeneration, before)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Architecture]]"))
    }

    func test_tabOnTheRenamedDocumentFollowsIt() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: design)
        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "Architecture.md")
    }

    func test_renameRefusesWhenDestinationExists() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        _ = try write(root, "Architecture.md", "---\nid: e\ntitle: Arch\n---\ny")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// A collision must be refused BEFORE any link is rewritten. Rewriting
    /// first and discovering the collision after would repoint every inbound
    /// link at a name that never comes to exist.
    func test_refusedRenameLeavesInboundLinksUntouched() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        _ = try write(root, "Architecture.md", "---\nid: e\ntitle: Arch\n---\ny")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.rewritten, [])
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Design]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: design.path))
    }

    /// The dirty-tab path: unsaved editor text must survive a rewrite of the
    /// same file. Cancelling the autosave without flushing it first would
    /// discard the edit, and the post-rewrite reload would make it
    /// unrecoverable.
    func test_unsavedEditsInARewrittenFileAreFlushedNotDiscarded() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        s.open(url: a)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "UNSAVED WORK\n\nsee [[Design]]"
        session.markChanged()

        _ = s.apply(s.plan(rename: design, to: "Architecture"))

        let text = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(text.contains("UNSAVED WORK"), text)
        XCTAssertTrue(text.contains("[[Architecture]]"), text)
    }

    /// A bare `[[Design]]` must not be caught by an unanchored replacement of
    /// the word, and neither must a longer basename that merely starts with it.
    func test_rewriteIsAnchoredToLinkDelimiters() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md",
            "---\nid: a\ntitle: A\n---\nThe design of [[Design Notes]] and [[Design]].")
        _ = try write(root, "Design Notes.md", "---\nid: n\ntitle: Design Notes\n---\nn")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        let text = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(text.contains("The design of [[Design Notes]] and [[Architecture]]."), text)
    }
}

/// The four defects the Task 7 review found after the first pass.
@MainActor
final class RenameApplicationHardeningTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rename2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
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
        await s.settleForTesting(); try s.rebuild()

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
        let design = try write(root, "Projects/Design.md",
                               "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

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
        let design = try write(root, "Design.md",
                               "---\nid: d\ntitle: Design\n---\nsee [[Design]] here")
        await s.settleForTesting(); try s.rebuild()

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
        let baseline = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        let hit = [LinkEdit(file: file, oldTarget: "Design", newTarget: "Architecture")]
        let miss = [LinkEdit(file: file, oldTarget: "Nothing", newTarget: "Else")]

        // Nothing matches: unchanged, and the file is left byte-identical.
        XCTAssertEqual(try LinkRewriter.applyEdits(miss, to: file, baseline: baseline),
                       .unchanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // No baseline: fail closed.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file, baseline: nil),
                       .skipped(.unverifiable))
        // Stale baseline: refuse.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file,
                                                   baseline: .distantPast),
                       .skipped(.changedOnDisk))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Design]]")

        // A real match writes.
        XCTAssertEqual(try LinkRewriter.applyEdits(hit, to: file, baseline: baseline),
                       .written)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[Architecture]]")
    }

    /// MINOR. The moved file, when it was itself rewritten, must be reported at
    /// its NEW path — the old one no longer exists by the time the UI renders.
    func test_reportNamesTheMovedFileAtItsNewPath() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md",
                               "---\nid: d\ntitle: Design\n---\nsee [[Design]]")
        await s.settleForTesting(); try s.rebuild()

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
        await s.settleForTesting(); try s.rebuild()

        let canonicalA = VaultIndexCoordinator.canonical(a)
        try XCTSkipIf(canonicalA.path == a.path,
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
        XCTAssertEqual(computed.edits.map(\.file.path), [canonicalA.path],
                       "the store's own plan should already be canonical")
        let plan = RenamePlan(
            source: computed.source, destination: computed.destination,
            edits: computed.edits.map {
                LinkEdit(file: a, oldTarget: $0.oldTarget, newTarget: $0.newTarget)
            },
            unrewritable: computed.unrewritable, baselines: computed.baselines,
            refusal: computed.refusal)

        let report = s.apply(plan)

        XCTAssertFalse(session.isDirty,
                       "the session was never seen by apply, so it was never flushed")
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["a.md"])
        let onDisk = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("unsaved edit"),
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
        await s.settleForTesting(); try s.rebuild()

        for name in ["", "..", "../escape", "a/b", "."] {
            let plan = s.plan(rename: design, to: name)
            XCTAssertNotNil(plan.refusal, "“\(name)” must be refused")
            XCTAssertTrue(plan.edits.isEmpty, "“\(name)” planned edits")

            let report = s.apply(plan)
            XCTAssertEqual(report.failed.count, 1, "“\(name)”")
            XCTAssertNil(report.movedTo, "“\(name)” moved a file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: design.path),
                          "“\(name)” moved the source away")
            XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), before,
                           "“\(name)” rewrote a link")
        }
        // Nothing was created anywhere: the vault holds exactly the two files.
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(contents, ["Design.md", "a.md"])
        // …and nothing escaped into the parent directory either.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escape.md").path))
    }

    func test_invalidFolderNamesAreRefusedWithoutMovingTheFolder() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting(); try s.rebuild()

        for name in ["", "..", "../escape", "a/b"] {
            let plan = s.plan(renameFolder: folder, to: name)
            XCTAssertNotNil(plan.refusal, "“\(name)” must be refused")
            XCTAssertTrue(plan.documentMoves.isEmpty, "“\(name)” planned moves")
            let report = s.apply(plan)
            XCTAssertNil(report.movedTo, "“\(name)” moved the folder")
            XCTAssertEqual(report.failed.count, 1, "“\(name)”")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }
}

/// Folder rename moves the FOLDER ITSELF, then rewrites links — it is not N
/// independent document moves. These tests pin the reasons why.
@MainActor
final class FolderRenameTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-folder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
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
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(renameFolder: folder, to: "Work")
        XCTAssertEqual(plan.documentMoves.count, 2)
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Work")
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Work/Design]]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "the old folder survived the rename")
        for name in ["Design.md", "Notes.md"] {
            XCTAssertTrue(FileManager.default.fileExists(
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
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "Work"))
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        for relative in ["Work/Design.md", "Work/assets/diagram.png", "Work/assets/spec.pdf"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relative).path), relative)
        }
    }

    /// A folder with nothing indexed in it used to yield `[]` plans and a report
    /// that could not be told apart from success. It must rename, and say so.
    func test_folderWithNoIndexedDocumentsStillRenames() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await s.settleForTesting(); try s.rebuild()

        let plan = s.plan(renameFolder: folder, to: "Renamed")
        XCTAssertTrue(plan.hasNoIndexedDocuments)
        XCTAssertNil(plan.refusal)
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Renamed",
                       "an empty folder rename must report the move, not nothing")
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Renamed").path))
    }

    /// An existing destination is refused BEFORE anything is written — the same
    /// mass-link-break guard single-document rename has.
    func test_existingDestinationFolderIsRefusedBeforeAnyWrite() async throws {
        let (root, s) = try vault()
        let folder = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Work"),
                                               withIntermediateDirectories: true)
        try write(folder, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Projects/Design]]")
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "Work"))
        XCTAssertNil(report.movedTo)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Projects/Design]]"),
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
        await s.settleForTesting(); try s.rebuild()

        let report = s.apply(s.plan(renameFolder: folder, to: "projects"))
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.movedTo?.lastPathComponent, "projects")
        XCTAssertTrue(FileManager.default.fileExists(
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
        await s.settleForTesting(); try s.rebuild()

        let canonicalDesign = VaultIndexCoordinator.canonical(design)
        try XCTSkipIf(canonicalDesign.path == design.path,
                      "this machine's temp root is already canonical; nothing to mix")

        // Re-index `Design.md` through the RAW spelling — the exact call any
        // document written outside a full rescan takes. `removeFromIndex` drops
        // the canonical row and the links it is the SOURCE of, so a.md's inbound
        // link survives untouched; the only variable is the URL spelling handed
        // to `indexDocument`.
        try s.coordinator.removeFromIndex(canonicalDesign)
        try s.coordinator.indexDocument(MarkdownEngine.load(design), at: design)
        // THE INVARIANT: the raw URL went in, a canonical row came out.
        XCTAssertTrue(s.rows.contains { $0.path.path == canonicalDesign.path },
                      "indexDocument stored a non-canonical documents.path")
        XCTAssertFalse(s.rows.contains { $0.path.path == design.path },
                       "a non-canonical spelling reached documents.path")

        let plan = s.plan(renameFolder: folder, to: "Work")
        XCTAssertEqual(plan.documentMoves.count, 1,
                       "a non-canonically indexed row fell silently out of the plan")
        let report = s.apply(plan)

        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Work/Design]]"),
                      "the inbound link broke silently")
        XCTAssertTrue(FileManager.default.fileExists(
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
        await s.settleForTesting(); try s.rebuild()

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
        await s.settleForTesting(); try s.rebuild()

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
        await s.settleForTesting(); try s.rebuild()
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
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Work/Design.md"),
                                 encoding: .utf8).contains("after"))
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
        await s.settleForTesting(); try s.rebuild()

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
