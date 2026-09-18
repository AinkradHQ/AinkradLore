import XCTest
@testable import LoreFeature

/// Task 8b: **every path that enters the index is canonical.**
///
/// macOS exposes the same file as both `/tmp/x` and `/private/tmp/x`, and
/// `URL.resolvingSymlinksInPath()` deliberately leaves `/tmp`, `/var` and
/// `/etc` alone (Apple's documented exception). Storing one spelling and
/// comparing against the other makes an exact-match SQL predicate return
/// nothing — and in M1 that produced three separate SILENT failures: an empty
/// backlinks pane, a rename whose edits were all dropped, and a folder rename
/// that moved a file while quietly breaking its inbound links.
///
/// Every test here that needs a genuinely non-canonical temp root SKIPS with a
/// message when the machine's temp root is already canonical, rather than
/// passing vacuously. This bug class's signature is silence, so a test that
/// cannot bite has to say so out loud.
@MainActor
final class CanonicalPathTests: XCTestCase {

    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-canon-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func store(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    @discardableResult
    private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func requireNonCanonicalTemp(_ url: URL) throws {
        try XCTSkipIf(
            VaultIndexCoordinator.canonical(url).path == url.path,
            "this machine's temporary directory is already canonical, so there are no two "
            + "spellings to desynchronize — this test cannot exercise the bug here")
    }

    // MARK: - The invariant, at the index boundary

    /// A vault rooted at a NON-canonical path (`FileManager.temporaryDirectory`,
    /// i.e. `/var/folders/...`) still produces canonical `documents.path` and
    /// canonical `links.target_path` rows. Exercised through `scanVault` +
    /// `replaceAll` directly, so the assertion is about the STORE boundary and
    /// not about anything a caller happened to canonicalize first.
    func test_scanOfANonCanonicalRootStoresCanonicalDocumentAndLinkPaths() throws {
        let root = try tempRoot("scan")
        try requireNonCanonicalTemp(root)
        let canonicalRoot = VaultIndexCoordinator.canonical(root)

        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Design]]")
        try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")

        let index = try LoreIndex(path: root.appendingPathComponent(".probe.sqlite"))
        try index.replaceAll(with: VaultIndexCoordinator.scanVault(at: root))

        let paths = try index.all().map(\.path.path).sorted()
        XCTAssertEqual(paths, [canonicalRoot.appendingPathComponent("Design.md").path,
                               canonicalRoot.appendingPathComponent("a.md").path],
                       "documents.path is not canonical")
        for path in paths {
            XCTAssertFalse(path.hasPrefix("/var/"),
                           "a non-canonical documents.path reached the index: \(path)")
        }

        // `links.target_path` — the column that drives backlinks,
        // `inboundLinkCount` and every rename's edit list.
        let outgoing = try index.outgoingLinks(from: a)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.targetPath?.path,
                       canonicalRoot.appendingPathComponent("Design.md").path,
                       "links.target_path is not canonical")

        // And the read side finds it under the canonical spelling AND under the
        // raw one the caller still holds — because reads canonicalize too.
        XCTAssertEqual(try index.backlinks(
            to: canonicalRoot.appendingPathComponent("Design.md")).count, 1)
        XCTAssertEqual(try index.backlinks(
            to: root.appendingPathComponent("Design.md")).count, 1)
    }

    /// The assertions above are a REGRESSION GUARD rather than a reproducer:
    /// `FileManager`'s enumerator already hands back `realpath`-resolved URLs on
    /// this platform, which is why full rescans mostly worked and only
    /// `indexDocument` was the live hole. So the store boundary is also pinned
    /// DIRECTLY here — an `IndexEntry` built by hand with a raw URL and a raw
    /// link target, upserted, and required to come back canonical. This is the
    /// assertion that fails the moment `LoreIndex.write` stops canonicalizing.
    func test_upsertingARawlySpelledEntryStoresItCanonically() throws {
        let root = try tempRoot("upsert")
        try requireNonCanonicalTemp(root)
        let canonicalRoot = VaultIndexCoordinator.canonical(root)

        // The files must EXIST: `canonical` is `realpath(3)`, which fails on a
        // path that does not exist and then returns the URL untouched. That
        // fallback is deliberate (a rename destination never exists yet), but it
        // means an index entry for a nonexistent file cannot be canonicalized —
        // worth knowing, and the reason this test writes both files.
        let source = try write(root, "source.md", "x")
        let target = try write(root, "target.md", "y")
        let index = try LoreIndex(path: root.appendingPathComponent(".probe.sqlite"))
        try index.upsert(IndexEntry(
            url: source, type: "md",
            payload: IndexPayload(title: "Source", plaintext: "x"),
            updated: Date(),
            resolvedLinks: [ResolvedLink(rawTarget: "target", targetPath: target,
                                         isEmbed: false)]))

        XCTAssertEqual(try index.all().map(\.path.path),
                       [canonicalRoot.appendingPathComponent("source.md").path],
                       "documents.path kept the caller's raw spelling")
        // Read under the RAW source spelling — reads canonicalize too, so the
        // row is reachable either way.
        XCTAssertEqual(try index.outgoingLinks(from: source).first?.targetPath?.path,
                       canonicalRoot.appendingPathComponent("target.md").path,
                       "links.target_path kept the caller's raw spelling")
        XCTAssertEqual(try index.inboundLinks(to: target).count, 1)
        XCTAssertEqual(try index.inboundLinks(
            to: canonicalRoot.appendingPathComponent("target.md")).count, 1)
        XCTAssertEqual(try index.inboundLinks(to: target).first?.sourceFile.path,
                       canonicalRoot.appendingPathComponent("source.md").path,
                       "links.source_path kept the caller's raw spelling")
    }

    /// `inboundLinkCount` is what `trash` warns the user with ("N notes link
    /// here"). Before Task 8b, a document indexed through `indexDocument` with a
    /// non-canonical URL wrote a non-canonical `target_path`, every canonical
    /// read missed it, and the warning under-reported — untruthfully, and with
    /// no way for the user to tell.
    func test_inboundLinkCountIsTruthfulForADocumentIndexedNonCanonically() async throws {
        let root = try tempRoot("inbound")
        try requireNonCanonicalTemp(root)
        let s = try store(root)

        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\n[[Design]]")
        let design = try write(root, "Design.md", "---\nid: d\ntitle: Design\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        // Re-index the LINKING document through the raw spelling: this is the
        // call that writes `links.target_path`, so it is the one that used to
        // poison the count.
        try s.coordinator.indexDocument(MarkdownEngine.load(a), at: a)

        XCTAssertEqual(s.inboundLinkCount(to: design), 1,
                       "the count trash warns with under-reported")
        XCTAssertEqual(s.inboundLinkCount(to: VaultIndexCoordinator.canonical(design)), 1,
                       "both spellings of the target must give the same count")
        XCTAssertEqual(s.backlinks(to: design).count, 1,
                       "the backlinks pane was empty for a linked document")
    }

    // MARK: - `transferOpenMTime`

    /// A rename must NOT disarm `save`'s external-change guard.
    ///
    /// `openMTimes` used to be keyed by whatever raw `note.path` the legacy note
    /// API was handed, while both `apply` paths call `transferOpenMTime` with
    /// CANONICAL URLs. On a mismatch the transfer silently no-opped, so
    /// `externalChangeDetected(for:)` found no baseline for the renamed note and
    /// returned `false` — which is exactly "overwrite the other writer's edits
    /// without asking", for precisely the note that was just renamed.
    ///
    /// The baseline here is deliberately established through a RAW-path `Note`,
    /// because that is the only way to reproduce the two-spelling condition.
    func test_renameKeepsTheExternalChangeGuardArmed() async throws {
        let root = try tempRoot("mtime")
        try requireNonCanonicalTemp(root)
        let s = try store(root)

        let raw = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nbody\n")
        await s.settleForTesting()
        try s.rebuild()

        // Baseline stored via a note whose `path` is the RAW spelling.
        let note = Frontmatter.parse(try String(contentsOf: raw, encoding: .utf8), path: raw)
        try s.save(note)

        let report = s.apply(s.plan(rename: raw, to: "b"))
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        let moved = try XCTUnwrap(report.movedTo)
        XCTAssertEqual(moved.lastPathComponent, "b.md")

        // Someone else edits the renamed file. The timestamp is set explicitly:
        // a write inside the filesystem's mtime granularity is exactly the hole
        // this guard is documented as not covering, and a test must not depend
        // on losing that race.
        try "---\nid: a\ntitle: A\n---\nsomeone else's work\n"
            .write(to: moved, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: moved.path)

        let renamed = Frontmatter.parse(try String(contentsOf: moved, encoding: .utf8),
                                        path: moved)
        XCTAssertTrue(s.externalChangeDetected(for: renamed),
                      "the rename lost the mtime baseline, so the guard is disarmed")
        XCTAssertThrowsError(try s.save(renamed)) { error in
            XCTAssertEqual(error as? LoreError, .externalChange(moved))
        }
        XCTAssertTrue(try String(contentsOf: moved, encoding: .utf8)
            .contains("someone else's work"), "the refused save wrote anyway")
    }

    // MARK: - `open(url:)`

    /// Opening an already-open document under its other spelling must SELECT the
    /// existing tab. Two sessions on one file means two mtime baselines and two
    /// debounced autosaves racing each other over the same bytes.
    func test_openWithANonCanonicalSpellingSelectsTheExistingTab() async throws {
        let root = try tempRoot("open")
        try requireNonCanonicalTemp(root)
        let s = try store(root)

        let raw = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nx")
        await s.settleForTesting()
        try s.rebuild()

        let canonical = VaultIndexCoordinator.canonical(raw)
        XCTAssertNotEqual(canonical.path, raw.path)

        s.open(url: canonical)
        XCTAssertEqual(s.tabs.count, 1)
        let first = try XCTUnwrap(s.selectedTab)

        s.open(url: raw)
        XCTAssertEqual(s.tabs.count, 1, "a second tab was opened on the same file")
        XCTAssertTrue(s.selectedTab === first, "the existing tab was not selected")

        // And the reverse direction — a raw-first open followed by the canonical
        // spelling the sidebar's `row.path` always carries.
        s.closeTab(first, force: true)
        s.open(url: raw)
        s.open(url: canonical)
        XCTAssertEqual(s.tabs.count, 1, "a second tab was opened on the same file")
    }
}
