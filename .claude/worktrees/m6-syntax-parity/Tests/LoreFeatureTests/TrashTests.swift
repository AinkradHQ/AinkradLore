import XCTest
@testable import LoreFeature

@MainActor
final class TrashTests: XCTestCase {
    private func vault() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    func test_trashMovesTheFileOutOfTheVaultWithoutDeletingIt() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(s.rows.first { $0.path.lastPathComponent == "gone.md" }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(s.rows.allSatisfy { $0.path.lastPathComponent != "gone.md" })
    }

    func test_trashReportsInboundLinkCountWithoutRewritingThem() async throws {
        let (root, s) = try vault()
        let a = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [[Gone]]".write(to: a, atomically: true, encoding: .utf8)
        let gone = root.appendingPathComponent("Gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: gone, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        XCTAssertEqual(s.inboundLinkCount(to: gone), 1)
        let warned = try s.trash(s.rows.first { $0.path.lastPathComponent == "Gone.md" }!)
        XCTAssertEqual(warned, 1)
        // The link is deliberately NOT rewritten: an unresolved link is how the
        // user finds what broke.
        XCTAssertTrue(try String(contentsOf: a, encoding: .utf8).contains("[[Gone]]"))
    }

    func test_trashClosesAnyTabOnTheDocument() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)
        _ = try s.trash(s.rows.first { $0.path.lastPathComponent == "gone.md" }!)
        XCTAssertTrue(s.tabs.isEmpty)
    }

    /// A dirty tab whose flush SUCCEEDS is the ordinary case: the unsaved text
    /// goes to the Trash along with the rest of the file, so a Trash restore
    /// recovers exactly what the user last saw.
    func test_dirtyTabIsFlushedIntoTheTrashedFile() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "gone.md" })
        s.open(row)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit"
        session.markChanged()

        _ = try s.trash(row)
        XCTAssertFalse(session.isDirty, "the flush must have happened")
        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// CRITICAL. The flush can REFUSE — a session already in `conflict`
    /// re-throws `externalChange` and stays dirty. The first cut ignored that
    /// (`try? saveNow()`) and force-closed the tab anyway: the file was trashed
    /// carrying STALE content and the only holder of the user's edits was
    /// destroyed in the same breath, silently, with no channel to report it.
    ///
    /// So trash REFUSES: the file stays, the tab stays open and dirty, its
    /// conflict is intact, and the unsaved text is untouched.
    func test_trashRefusesWhenATabStillHoldsUnsavedEdits() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "gone.md" })
        s.open(row)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit"
        session.markChanged()
        session.cancelPendingSave()

        // Drive the session into conflict, which is what makes the flush refuse.
        try await Task.sleep(for: .milliseconds(1100))
        let external = "---\nid: g\ntitle: Gone\n---\nsomebody else"
        try external.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())
        XCTAssertTrue(session.conflict)

        XCTAssertThrowsError(try s.trash(row)) { error in
            guard case LoreError.unsavedEdits(_, let reason) = error else {
                return XCTFail("expected unsavedEdits, got \(error)")
            }
            XCTAssertTrue(reason.contains("unsaved edits"), reason)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the file was trashed despite the refusal")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), external)
        XCTAssertEqual(s.tabs.count, 1, "the tab was closed despite the refusal")
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.conflict, "the conflict must survive for the user to resolve")
        XCTAssertEqual(engine.note.body, "unsaved edit", "the unsaved text was destroyed")
    }

    /// `trashItem` failing must throw `trashFailed` and NEVER fall back to
    /// `removeItem`. Provoked with a path that does not exist, which is the one
    /// failure a test can force without a network volume.
    func test_trashFailureThrowsAndNeverFallsBackToAPermanentDelete() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "gone.md" })
        // The row is now stale: the file it names is gone from under it.
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try s.trash(row)) { error in
            guard case LoreError.trashFailed(let failedURL, _) = error else {
                return XCTFail("expected trashFailed, got \(error)")
            }
            XCTAssertEqual(failedURL.lastPathComponent, "gone.md")
        }
    }

    /// A failed trash must leave the TAB open too. Tabs used to be force-closed
    /// before `trashItem` ran, so a failure told the user "nothing was deleted"
    /// while the document they had open had vanished from the tab bar. No text
    /// was lost — a dirty session is refused or flushed first — but the UI lied
    /// about what had happened.
    func test_aFailedTrashLeavesTheOpenTabAlone() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let row = try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "gone.md" })
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1, "premise: the document is open")
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try s.trash(row))
        XCTAssertEqual(s.tabs.count, 1, "the tab was closed for a delete that never happened")
        XCTAssertEqual(s.tabs.first?.url.lastPathComponent, "gone.md")
    }

    /// The other side of the same ordering: on SUCCESS the tab still closes.
    func test_aSuccessfulTrashStillClosesTheTab() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("bye.md")
        try "---\nid: b\ntitle: Bye\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        s.open(url: url)
        XCTAssertEqual(s.tabs.count, 1)

        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "bye.md" }))
        XCTAssertTrue(s.tabs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Undo

    /// The round trip: the file comes back where it was, and the index knows
    /// about it again. Both halves matter — a restored file the sidebar cannot
    /// see is not a restored file as far as the user is concerned.
    func test_undoRestoresTheFileAndItsIndexRow() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("oops.md")
        try "---\nid: o\ntitle: Oops\n---\nkeep me".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "oops.md" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(s.lastTrash, "nothing to undo with")

        try s.undoTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).contains("keep me"), true)
        XCTAssertTrue(s.rows.contains { $0.path.lastPathComponent == "oops.md" },
                      "the file is back on disk but missing from the index")
    }

    /// The record is one deep and is CONSUMED, so the same delete cannot be
    /// undone twice — the second press must be a no-op, not a second restore
    /// attempt against a path the first one already emptied.
    func test_undoIsConsumedAndCannotReplay() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("once.md")
        try "---\nid: o\ntitle: Once\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "once.md" }))
        try s.undoTrash()
        XCTAssertNil(s.lastTrash)
        XCTAssertNoThrow(try s.undoTrash(), "a second undo must be a no-op")
    }

    /// The refusal that keeps undo from being destructive: the user trashed
    /// `taken.md`, then made a NEW `taken.md`. Restoring over it would destroy
    /// the newer file to recover the older one, so it is refused.
    func test_undoRefusesWhenTheNameIsTakenAgain() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("taken.md")
        try "---\nid: t\ntitle: Old\n---\nold".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "taken.md" }))

        // A different file now occupies the restored path.
        try "---\nid: n\ntitle: New\n---\nnew".write(to: url, atomically: true, encoding: .utf8)

        // Compared CANONICALLY: `trash` canonicalizes the path before storing
        // the undo record (so the restore re-indexes under the same spelling
        // the index uses), and under `/tmp` — where every test vault lives —
        // canonical means `/private/var/…` while `url` here is the raw
        // `/var/…` spelling. Asserting on the raw URL tests the test's own
        // spelling, not the behaviour.
        XCTAssertThrowsError(try s.undoTrash()) { error in
            XCTAssertEqual(error as? LoreError,
                           .restoreBlocked(VaultIndexCoordinator.canonical(url)))
        }
        // The newer file is untouched.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).contains("new"), true)
    }

    /// Undo deliberately does NOT reopen the tab that `trash` closed. Asserted
    /// so a future "helpful" change to reopen it is a deliberate decision
    /// rather than an accident.
    func test_undoDoesNotReopenTheTab() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("shut.md")
        try "---\nid: s\ntitle: Shut\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        s.open(url: url)
        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "shut.md" }))
        XCTAssertTrue(s.tabs.isEmpty)

        try s.undoTrash()
        XCTAssertTrue(s.tabs.isEmpty, "undo restored the file; reopening the tab is not its job")
    }

    /// An attachment is trashable, so undo must re-index it through
    /// `EngineRegistry` rather than assuming every restored file is markdown.
    func test_undoRestoresANonMarkdownFile() async throws {
        let (root, s) = try vault()
        let url = root.appendingPathComponent("data.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: url)
        await s.settleForTesting(); try s.rebuild()

        _ = try s.trash(try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == "data.zip" }))
        try s.undoTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(s.rows.contains { $0.path.lastPathComponent == "data.zip" })
    }
}
