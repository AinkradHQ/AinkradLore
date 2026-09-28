import XCTest
@testable import LoreFeature

/// Task E (M3): title and filename stay in sync. Both directions drive the
/// REAL store API — `LoreStore.commitTitleChange` (title field commit) and
/// `LoreStore.syncTitleAfterFileRename` (after a sidebar-style file rename via
/// `plan(rename:)`/`apply(_:)`) — never a parallel test-only helper.
@MainActor
final class TitleSyncTests: XCTestCase {
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-titlesync-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        createdDirs.append(u)
        return u
    }

    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    @discardableResult
    private func write(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Direction A: title field commit renames the file, rewrites links

    func test_titleCommitRenamesTheFileAndRewritesInboundLinks() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Old Name.md", "---\nid: n\ntitle: Old Name\n---\nbody")
        try write(root, "Referrer.md", "---\nid: r\ntitle: Referrer\n---\nSee [[Old Name]].")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "New Name"

        let outcome = store.commitTitleChange(for: session, to: "New Name")
        XCTAssertEqual(outcome, .success, "a legal title commit must succeed")

        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path), "old file must be gone")
        let newURL = root.appendingPathComponent("New Name.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "file must be renamed")

        let onDisk = try String(contentsOf: newURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: New Name"), "frontmatter title must be persisted: \(onDisk)")

        let referrerText = try String(contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)
        XCTAssertTrue(referrerText.contains("[[New Name]]"), "inbound link must be rewritten: \(referrerText)")
        XCTAssertFalse(referrerText.contains("[[Old Name]]"))
    }

    // MARK: - Direction B: file rename updates the title

    func test_fileRenameUpdatesTheFrontmatterTitle() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Old Name.md", "---\nid: n\ntitle: Old Name\n---\nbody")
        try store.rebuild()

        let plan = store.plan(rename: noteURL, to: "New Name")
        XCTAssertNil(plan.refusal)
        let report = store.apply(plan)
        XCTAssertTrue(report.failed.isEmpty, "rename must not fail: \(report.failed)")
        let destination = try XCTUnwrap(report.movedTo)

        store.syncTitleAfterFileRename(at: destination)

        let onDisk = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: New Name"), "title must track the new filename: \(onDisk)")
        XCTAssertFalse(onDisk.contains("title: Old Name"))
    }

    // MARK: - Illegal titles refused, reverted, file untouched

    func test_illegalTitleIsRefusedAndTheFileIsUntouched() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Good Title.md", "---\nid: n\ntitle: Good Title\n---\nbody")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)

        for illegal in ["Bad/Title", "Bad:Title", ".HiddenTitle", "Bad\u{0007}Title"] {
            let outcome = store.commitTitleChange(for: session, to: illegal)
            guard case .refused = outcome else {
                XCTFail("“\(illegal)” must be refused, got \(outcome)")
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path),
                          "“\(illegal)” must not move the original file")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(illegal + ".md").path),
                "“\(illegal)” must not create a new file")
        }
    }

    // MARK: - Collisions refused, both files intact

    func test_collidingTitleIsRefusedAndBothFilesAreIntact() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Note A.md", "---\nid: a\ntitle: Note A\n---\nbody A")
        try write(root, "Note B.md", "---\nid: b\ntitle: Note B\n---\nbody B")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "Note B"

        let outcome = store.commitTitleChange(for: session, to: "Note B")
        guard case .refused = outcome else {
            return XCTFail("a collision must be refused, got \(outcome)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path), "Note A must still exist")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Note B.md").path), "Note B must still exist")
        let aText = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(aText.contains("title: Note A"), "Note A's own title must be untouched")
    }

    // MARK: - A case-only retitle is NOT a collision (Important 6)

    func test_caseOnlyTitleChangeIsNotRefusedAsACollision() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "chapter one.md", "---\nid: c\ntitle: chapter one\n---\nbody")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "Chapter One"

        let outcome = store.commitTitleChange(for: session, to: "Chapter One")
        XCTAssertEqual(outcome, .success, "a capitalization-only retitle must not be refused: \(outcome)")

        let onDisk = try String(
            contentsOf: root.appendingPathComponent("Chapter One.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: Chapter One"))
    }

    // MARK: - Dotted title round-trips without gaining `.md` or a path

    func test_dottedTitleRoundTripsWithoutGainingExtensionOrPath() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Chapter 1.1.md", "---\nid: c\ntitle: Chapter 1.1\n---\nbody")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "Chapter 2.0"

        let outcome = store.commitTitleChange(for: session, to: "Chapter 2.0")
        XCTAssertEqual(outcome, .success)

        let expected = root.appendingPathComponent("Chapter 2.0.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "must land at exactly Chapter 2.0.md, not a nested path or double extension")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Chapter 2.0.md.md").path))
        let onDisk = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: Chapter 2.0"))
    }

    // MARK: - Unknown frontmatter keys survive a title change verbatim

    func test_titleChangePreservesUnknownFrontmatterKeysVerbatim() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Original.md",
            "---\nid: n\ntitle: Original\ncustom_field: keep-me\nanother: 42\n---\nbody")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "Renamed"

        let outcome = store.commitTitleChange(for: session, to: "Renamed")
        XCTAssertEqual(outcome, .success)

        let onDisk = try String(
            contentsOf: root.appendingPathComponent("Renamed.md"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("custom_field: keep-me"), "unknown key must survive: \(onDisk)")
        XCTAssertTrue(onDisk.contains("another: 42"), "unknown key must survive: \(onDisk)")
    }

    // MARK: - No infinite loop

    func test_titleCommitAndFileRenameSyncDoNotLoop() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Loop Me.md", "---\nid: n\ntitle: Loop Me\n---\nbody")
        try store.rebuild()

        // Direction A, then immediately re-run direction B against the
        // resulting file: neither call re-enters the other, so this must
        // settle after one write each, not recurse or alternate forever.
        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "Looped Once"
        XCTAssertEqual(store.commitTitleChange(for: session, to: "Looped Once"), .success)

        let renamed = root.appendingPathComponent("Looped Once.md")
        let before = try String(contentsOf: renamed, encoding: .utf8)
        // Calling the file-rename sync AGAIN on an already-synced file must
        // be a pure no-op — this is the loop-prevention guarantee.
        store.syncTitleAfterFileRename(at: renamed)
        let after = try String(contentsOf: renamed, encoding: .utf8)
        XCTAssertEqual(before, after, "a no-op sync must not rewrite the file")
    }

    /// A note that links to ITSELF is a real, exercised case elsewhere in
    /// this codebase (`LinkRewriterTests`) — and it is exactly the shape that
    /// makes `apply`'s link-rewrite pass reload the very session doing the
    /// renaming, copying the OLD on-disk title back into `engine.note`
    /// (whole-branch review, Critical 4). The final file must still end up
    /// with the NEW title, not the reloaded old one.
    func test_selfLinkingNoteEndsUpWithTheNewTitleNotTheReloadedOldOne() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Old Self.md",
            "---\nid: s\ntitle: Old Self\n---\nSee also [[Old Self]] for more.")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        markdown.note.title = "New Self"

        let outcome = store.commitTitleChange(for: session, to: "New Self")
        if case .refused(let reason) = outcome { XCTFail("must not be refused: \(reason)") }

        let destination = root.appendingPathComponent("New Self.md")
        let onDisk = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("title: New Self"),
                      "the persisted title must be the NEW one, not reloaded-old: \(onDisk)")
        XCTAssertFalse(onDisk.contains("title: Old Self"))
        XCTAssertTrue(onDisk.contains("[[New Self]]"), "the self-link must also be rewritten: \(onDisk)")
    }

    // MARK: - Read-only session writes nothing

    func test_readOnlySessionCommitWritesNothing() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        // Invalid UTF-8 bytes make `PlainTextEngine` load read-only (it
        // cannot round-trip the file), which is `DocumentSession.isReadOnly`
        // — the same guard every other write path in the store honors.
        let url = root.appendingPathComponent("binary.txt")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)
        try store.rebuild()

        store.open(url: url)
        let session = try XCTUnwrap(store.selectedTab)
        XCTAssertTrue(session.isReadOnly)

        let before = try Data(contentsOf: url)
        let outcome = store.commitTitleChange(for: session, to: "renamed")
        guard case .refused = outcome else {
            return XCTFail("a read-only session must refuse the rename, got \(outcome)")
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after, "a read-only session must write nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Already-divergent note is left alone until edited

    func test_alreadyDivergentNoteIsNotTouchedUntilEdited() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        // Title and filename already disagree — pre-existing divergence the
        // owner's ruling says must NOT be reconciled as a side effect of
        // opening, indexing, or rebuilding.
        let url = try write(root, "filename-one.md", "---\nid: n\ntitle: A Totally Different Title\n---\nbody")
        try store.rebuild()
        await store.settleForTesting()

        let before = try String(contentsOf: url, encoding: .utf8)

        // Opening it, and rebuilding the index again, must not sync it.
        store.open(url: url)
        try store.rebuild()
        await store.settleForTesting()

        let afterOpenAndRebuild = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(before, afterOpenAndRebuild,
                       "opening/indexing a divergent note must not sync it")
        XCTAssertTrue(afterOpenAndRebuild.contains("title: A Totally Different Title"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// CRITICAL 1's exact scenario: open a divergent note, commit the title
    /// field UNCHANGED (as a click-in/click-out, or a UI-level blur firing
    /// with no edit, would do). This must be a pure no-op — the guard is
    /// "did the title actually change since this session last loaded/saved
    /// it", never "does the title match the filename". Before the fix, this
    /// assertion failed: the unedited commit renamed the file and rewrote
    /// every inbound link.
    func test_unchangedTitleCommitOnADivergentNoteDoesNothing() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let url = try write(root, "filename-one.md",
            "---\nid: n\ntitle: A Totally Different Title\n---\nbody")
        try write(root, "Referrer.md",
            "---\nid: r\ntitle: Referrer\n---\nSee [[A Totally Different Title]].")
        try store.rebuild()

        store.open(url: url)
        let session = try XCTUnwrap(store.selectedTab)
        let noteTitle = try XCTUnwrap((session.engine as? MarkdownEngine)?.note.title)

        let before = try String(contentsOf: url, encoding: .utf8)
        let referrerBefore = try String(
            contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)

        // Committing the SAME title the session already has — no edit — must
        // not rename the file, even though title != filename.
        let outcome = store.commitTitleChange(for: session, to: noteTitle)
        XCTAssertEqual(outcome, .success, "an unedited commit must be a no-op, not a refusal either")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the original file must not have been moved")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(before, after, "an unedited commit must not rewrite the file")
        let referrerAfter = try String(
            contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)
        XCTAssertEqual(referrerBefore, referrerAfter, "an unedited commit must not rewrite any links")
    }

    // MARK: - Fix round 2, Critical A / Important B: an autosave landing
    // BEFORE the commit must not defeat the no-op guard in either direction.
    //
    // The dominant real gesture is "type a new title, pause a beat, click
    // away" — which lets the 500ms-debounced autosave (`markChanged()` →
    // `saveNow()`) land BEFORE the commit. These tests drive that exact
    // sequence by calling `session.saveNow()` directly after mutating
    // `engine.note.title` — the same terminal call the debounce timer itself
    // makes — rather than sleeping 500ms in a test.

    /// A GENUINE retitle must still rename the file and rewrite links even
    /// though an autosave already landed the new text into `cachedTitle`
    /// before the commit runs. Before the Critical A fix, this failed: the
    /// guard compared against `session.title` (which the autosave had
    /// already updated to match), saw no difference, and silently no-opped —
    /// no rename, no link rewrite, no alert — while the OLD filename kept
    /// the NEW title in its frontmatter, a divergence no later commit of the
    /// same text could ever repair.
    func test_genuineRetitleStillRenamesEvenAfterAnAutosaveLandsFirst() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let noteURL = try write(root, "Old Name.md", "---\nid: n\ntitle: Old Name\n---\nbody")
        try write(root, "Referrer.md", "---\nid: r\ntitle: Referrer\n---\nSee [[Old Name]].")
        try store.rebuild()

        store.open(url: noteURL)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)

        // Simulate typing, then a pause long enough for the debounced
        // autosave to fire, BEFORE the click-away commit.
        markdown.note.title = "New Name"
        session.markChanged()
        try session.saveNow()
        XCTAssertEqual(session.title, "New Name", "the autosave must have landed for this test to be meaningful")

        // The commit now runs, still with "New Name" — the same text the
        // autosave already wrote into the OLD file.
        let outcome = store.commitTitleChange(for: session, to: "New Name")
        XCTAssertEqual(outcome, .success, "a genuine retitle must succeed even after an autosave landed first")

        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path), "old file must be gone")
        let newURL = root.appendingPathComponent("New Name.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path), "file must be renamed")
        let referrerText = try String(contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)
        XCTAssertTrue(referrerText.contains("[[New Name]]"), "inbound link must be rewritten: \(referrerText)")
    }

    /// The mirror case: an UNEDITED note (title already equals what the
    /// session loaded) whose session nonetheless goes through a save cycle
    /// (e.g. a body edit's autosave) before the title field is blurred. This
    /// must still be a no-op — `cachedTitle` moving is irrelevant, since it
    /// never actually changed value here.
    func test_unchangedTitleStillNoOpsAfterAnUnrelatedAutosave() async throws {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()
        let url = try write(root, "filename-one.md",
            "---\nid: n\ntitle: A Totally Different Title\n---\nbody")
        try write(root, "Referrer.md",
            "---\nid: r\ntitle: Referrer\n---\nSee [[A Totally Different Title]].")
        try store.rebuild()

        store.open(url: url)
        let session = try XCTUnwrap(store.selectedTab)
        let markdown = try XCTUnwrap(session.engine as? MarkdownEngine)
        let noteTitle = markdown.note.title

        // An unrelated body edit triggers a real save cycle — the title
        // itself is untouched, but this exercises `write()`'s refresh of
        // `cachedTitle` from the current (unchanged) `note.title`.
        markdown.note.body = "edited body"
        session.markChanged()
        try session.saveNow()

        let before = try String(contentsOf: url, encoding: .utf8)
        let referrerBefore = try String(
            contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)

        let outcome = store.commitTitleChange(for: session, to: noteTitle)
        XCTAssertEqual(outcome, .success, "still a no-op: the title itself was never edited")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the file must not have been moved")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("edited body"), "the unrelated body edit must still have been saved")
        XCTAssertEqual(before, after, "the title-commit itself must not have written anything further")
        let referrerAfter = try String(
            contentsOf: root.appendingPathComponent("Referrer.md"), encoding: .utf8)
        XCTAssertEqual(referrerBefore, referrerAfter, "no link rewrite must have happened")
    }
}
