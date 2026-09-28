import XCTest
@testable import LoreFeature

/// The reader is the half of idempotency that did not exist until now: the
/// applier had always written `lore_import_id`, and the planner had always
/// accepted `existingImportIDs`, but nothing produced that set — so every
/// retry would have duplicated the library.
final class ImportIDReaderTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - frontmatter

    func testReadsImportIDsFromNotesAtAnyDepth() throws {
        let root = try makeVault()
        try write("---\nlore_import_id: obsidian:A.md\n---\n\nbody", to: "A.md", in: root)
        try write("---\nlore_import_id: obsidian:Deep/B.md\n---\n\nbody",
                  to: "Deep/Nested/B.md", in: root)
        try write("no frontmatter here", to: "C.md", in: root)

        XCTAssertEqual(ImportIDReader.read(vaultRoot: root),
                       ["obsidian:A.md", "obsidian:Deep/B.md"])
    }

    /// `ObsidianSource` builds `sourceID` from a filesystem path, and a path may
    /// legally contain a `#` or a newline on APFS. Those force `yamlScalar` to
    /// quote the value — so a reader that did not unquote would fail to match
    /// exactly the notes most at risk of being duplicated.
    func testReadsAnIDThatFrontmatterHadToQuote() throws {
        let root = try makeVault()
        let awkward = "obsidian:Notes/plan #1\nwith a newline.md"
        let text = ImportApplier.frontmatterBody("body", item: ImportItem(
            sourceID: awkward, title: "Plan", body: .markdown("body"), attachments: [],
            folderPath: [], created: Date(), modified: Date(), fidelity: []))
        try write(text, to: "Plan.md", in: root)

        XCTAssertTrue(ImportIDReader.read(vaultRoot: root).contains(awkward))
    }

    func testIgnoresHiddenDirectoriesButNotAHiddenAncestor() throws {
        let root = try makeVault().appendingPathComponent(".hidden-parent/vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("---\nlore_import_id: obsidian:A.md\n---\n", to: "A.md", in: root)
        try write("---\nlore_import_id: obsidian:trashed.md\n---\n",
                  to: ".trash/trashed.md", in: root)

        // The vault itself living under a dot-directory must not make every
        // file in it read as hidden — only components BELOW the root are judged.
        XCTAssertEqual(ImportIDReader.read(vaultRoot: root), ["obsidian:A.md"])
    }

    // MARK: - ledger

    func testTheLedgerRecordsIDsForFilesThatCannotCarryFrontmatter() throws {
        let root = try makeVault()
        try write("png bytes", to: "Media/pic.png", in: root)
        try ImportLedger.record(id: "obsidian:Media/pic.png",
                                landedAt: root.appendingPathComponent("Media/pic.png"),
                                vaultRoot: root)

        XCTAssertEqual(ImportIDReader.read(vaultRoot: root), ["obsidian:Media/pic.png"])
    }

    /// The reason the ledger stores the landed PATH and not just the id: an
    /// id-only ledger would make deletion permanent, so a user who deleted an
    /// imported image could never get it back by re-importing.
    func testALedgerEntryStopsCountingOnceItsFileIsDeleted() throws {
        let root = try makeVault()
        let landed = root.appendingPathComponent("pic.png")
        try write("png bytes", to: "pic.png", in: root)
        try ImportLedger.record(id: "obsidian:pic.png", landedAt: landed, vaultRoot: root)
        XCTAssertEqual(ImportIDReader.read(vaultRoot: root), ["obsidian:pic.png"])

        try FileManager.default.removeItem(at: landed)
        XCTAssertTrue(ImportIDReader.read(vaultRoot: root).isEmpty)
    }

    /// A tab or a newline is legal in an APFS filename, and both fields of a
    /// TSV row are user-derived. Unescaped, one entry would split into two
    /// unreadable ones and the id would silently stop matching.
    func testRoundTripsIDsContainingTabsAndNewlines() throws {
        let root = try makeVault()
        let id = "obsidian:odd\tname\nsecond line\\.png"
        try write("bytes", to: "odd.png", in: root)
        try ImportLedger.record(id: id, landedAt: root.appendingPathComponent("odd.png"),
                                vaultRoot: root)

        XCTAssertEqual(ImportLedger.entries(vaultRoot: root).map(\.id), [id])
        XCTAssertTrue(ImportIDReader.read(vaultRoot: root).contains(id))
    }

    func testAppendingKeepsEveryEarlierEntry() throws {
        let root = try makeVault()
        for name in ["a.png", "b.png", "c.png"] {
            try write("bytes", to: name, in: root)
            try ImportLedger.record(id: "obsidian:\(name)",
                                    landedAt: root.appendingPathComponent(name),
                                    vaultRoot: root)
        }
        XCTAssertEqual(ImportIDReader.read(vaultRoot: root),
                       ["obsidian:a.png", "obsidian:b.png", "obsidian:c.png"])
    }

    func testRefusesToRecordAFileOutsideTheVault() throws {
        let root = try makeVault()
        let elsewhere = try makeVault().appendingPathComponent("stray.png")
        try "bytes".write(to: elsewhere, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ImportLedger.record(id: "x", landedAt: elsewhere,
                                                     vaultRoot: root))
    }

    func testAVaultWithNoLedgerAndNoNotesReadsAsEmpty() throws {
        XCTAssertTrue(ImportIDReader.read(vaultRoot: try makeVault()).isEmpty)
    }
}
