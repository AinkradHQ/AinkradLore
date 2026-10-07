import XCTest

@testable import LoreFeature

@MainActor
final class RenameApplicationTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        try makeRenameVault(prefix: "lore-rename")
    }

    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        try writeRenameFixture(root, name, text)
    }

    func test_renameRewritesInboundLinksAndMovesTheFile() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        let plan = s.plan(rename: design, to: "Architecture")
        XCTAssertEqual(plan.edits.count, 1)
        let report = s.apply(plan)

        XCTAssertEqual(report.skipped, [])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Architecture]]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: design.path))
        XCTAssertTrue(
            FileManager.default
                .fileExists(atPath: root.appendingPathComponent("Architecture.md").path))
    }

    func test_fileChangedOnDiskIsSkippedAndReportedNotOverwritten() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

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
        await s.settleForTesting()
        try s.rebuild()

        let report = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(report.movedTo?.lastPathComponent, "Architecture.md")
        XCTAssertEqual(report.rewritten.count, 1)
    }

    func test_openTabOnARewrittenFileIsReloadedNotClobbered() async throws {
        let (root, s) = try vault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nsee [[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

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
        await s.settleForTesting()
        try s.rebuild()

        s.open(url: design)
        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        XCTAssertEqual(s.selectedTab?.url.lastPathComponent, "Architecture.md")
    }

    func test_renameRefusesWhenDestinationExists() async throws {
        let (root, s) = try vault()
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        _ = try write(root, "Architecture.md", "---\nid: e\ntitle: Arch\n---\ny")
        await s.settleForTesting()
        try s.rebuild()

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
        await s.settleForTesting()
        try s.rebuild()

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
        await s.settleForTesting()
        try s.rebuild()

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
        let a = try write(
            root, "a.md",
            "---\nid: a\ntitle: A\n---\nThe design of [[Design Notes]] and [[Design]].")
        _ = try write(root, "Design Notes.md", "---\nid: n\ntitle: Design Notes\n---\nn")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        _ = s.apply(s.plan(rename: design, to: "Architecture"))
        let text = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(text.contains("The design of [[Design Notes]] and [[Architecture]]."), text)
    }
}
