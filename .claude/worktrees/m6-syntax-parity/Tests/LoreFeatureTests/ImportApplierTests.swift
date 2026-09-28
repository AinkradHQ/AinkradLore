import XCTest
@testable import LoreFeature

@MainActor
final class ImportApplierTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item(_ id: String, _ title: String,
                      body: ImportBody = .markdown("hello"),
                      attachments: [ImportAttachment] = []) -> ImportItem {
        ImportItem(sourceID: id, title: title, body: body, attachments: attachments,
                   folderPath: [], created: Date(), modified: Date(), fidelity: [])
    }

    private func importID(_ note: Note) -> String? {
        note.extra.first { $0.key == "lore_import_id" }?.rawValue
    }

    func testWritesTheNoteWithItsImportIDInFrontmatter() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 1)
        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        XCTAssertTrue(text.contains("hello"))
        let note = Frontmatter.parse(text, path: report.imported[0])
        XCTAssertEqual(importID(note), "apple-notes:N1")
    }

    func testConvertsHTMLBodiesAndKeepsTheOriginalBeside() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N2", "Bold", body: .html("<p>a <b>b</b></p>"))],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        XCTAssertTrue(text.contains("a **b**"))
        let original = vault.appendingPathComponent("Bold.original.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "<p>a <b>b</b></p>")
    }

    func testSkipsAlreadyImportedItemsWithoutWriting() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault,
                                      existingImportIDs: ["apple-notes:N1"])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Plan.md").path))
    }

    func testASecondApplyOfTheSameSourceCreatesNothing() async throws {
        let vault = try makeVault()
        let items = [item("apple-notes:N1", "Plan")]
        let applier = ImportApplier(vaultRoot: vault)
        _ = await applier.apply(ImportPlanner.plan(items: items, vaultRoot: vault,
                                                   existingImportIDs: []))
        let before = try FileManager.default.contentsOfDirectory(atPath: vault.path).count
        // The second run is planned with the IDs the first run wrote — exactly what
        // the UI does by reading them back off disk.
        let second = await applier.apply(ImportPlanner.plan(
            items: items, vaultRoot: vault, existingImportIDs: ["apple-notes:N1"]))
        XCTAssertTrue(second.imported.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path).count,
                       before)
    }

    func testOneFailedItemDoesNotAbortTheRun() async throws {
        let vault = try makeVault()
        let good = item("apple-notes:N1", "Good")
        let bad = ImportItem(sourceID: "apple-notes:N2", title: "Bad",
                             body: .markdown("x"),
                             attachments: [ImportAttachment(
                                sourceID: "a", preferredName: "missing.png",
                                sourceURL: URL(fileURLWithPath: "/nope/missing.png"))],
                             folderPath: [], created: Date(), modified: Date(),
                             fidelity: [])
        let plan = ImportPlanner.plan(items: [bad, good], vaultRoot: vault,
                                      existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 2)   // the note still lands
        XCTAssertEqual(report.failed.count, 1)     // its attachment is reported
        // The counts alone don't prove the good item actually landed on
        // disk — assert the files themselves exist, and with the right body.
        for url in report.imported {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        let badText = try String(
            contentsOf: report.imported.first { $0.lastPathComponent == "Bad.md" }!,
            encoding: .utf8)
        XCTAssertTrue(badText.contains("x"))
    }

    /// Beyond the brief: an on-disk file the user already owns — never
    /// produced by this selection, so the planner (which only dedups WITHIN
    /// a selection) cannot know about it — must never be overwritten.
    func testOnDiskCollisionWithAUserOwnedFileIsRenamedNotOverwritten() async throws {
        let vault = try makeVault()
        let existing = vault.appendingPathComponent("Plan.md")
        try "user's own note".write(to: existing, atomically: true, encoding: .utf8)

        let plan = ImportPlanner.plan(items: [item("apple-notes:N1", "Plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertNotEqual(report.imported[0], existing)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "user's own note")
        let importedText = try String(contentsOf: report.imported[0], encoding: .utf8)
        let note = Frontmatter.parse(importedText, path: report.imported[0])
        XCTAssertEqual(importID(note), "apple-notes:N1")
    }

    /// Finding 1 (critical, review round 1): the `.original.html` sidecar
    /// must go through the same on-disk collision check as the note. Before
    /// the fix it was written with no check at all, silently truncating a
    /// pre-existing file of that name.
    func testOnDiskCollisionWithAUserOwnedOriginalHTMLSidecarIsRenamedNotOverwritten() async throws {
        let vault = try makeVault()
        let existingSidecar = vault.appendingPathComponent("Bold.original.html")
        try "the user's own html, not ours".write(to: existingSidecar, atomically: true, encoding: .utf8)

        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N2", "Bold", body: .html("<p>a <b>b</b></p>"))],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(try String(contentsOf: existingSidecar, encoding: .utf8),
                       "the user's own html, not ours")
        // The real sidecar must exist somewhere else, under a different name
        // (`LoreStore.nonCollidingURL` splits on the LAST dot, so a
        // double-extension name like `Bold.original.html` gets its
        // disambiguating " 2" inserted before `.html`, not before
        // `.original.html` — still unique and non-overwriting, just not the
        // prettiest possible name).
        let htmlFiles = try FileManager.default.contentsOfDirectory(atPath: vault.path)
            .filter { $0.hasSuffix(".html") }
        XCTAssertEqual(htmlFiles.count, 2)
        let contents = try htmlFiles.map {
            try String(contentsOf: vault.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertTrue(contents.contains("the user's own html, not ours"))
        XCTAssertTrue(contents.contains("<p>a <b>b</b></p>"))
    }

    /// Finding 2 (critical, review round 1): an attachment whose sanitized
    /// name collides with the NOTE's own filename must not be allowed to
    /// land at that path and then be silently overwritten when the note
    /// itself is written. Both names are now reserved before the attachment
    /// loop runs.
    func testAttachmentCollidingWithTheNotesOwnFilenameIsNotOverwritten() async throws {
        let vault = try makeVault()
        let attachmentSource = vault.appendingPathComponent("source-Plan.md")
        try "attachment bytes, not the note".write(to: attachmentSource, atomically: true,
                                                    encoding: .utf8)

        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N1", "Plan",
                        attachments: [ImportAttachment(sourceID: "att-1",
                                                       preferredName: "Plan.md",
                                                       sourceURL: attachmentSource)])],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(report.failed.count, 0)
        // The note itself must be readable as a note (frontmatter parses),
        // never overwritten by the attachment's raw bytes.
        let noteText = try String(contentsOf: report.imported[0], encoding: .utf8)
        let note = Frontmatter.parse(noteText, path: report.imported[0])
        XCTAssertEqual(importID(note), "apple-notes:N1")
        // The attachment must have landed intact under a different name.
        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        let attachmentCopy = entries.first { $0 != "source-Plan.md" && $0 != report.imported[0].lastPathComponent }
        XCTAssertNotNil(attachmentCopy)
        if let attachmentCopy {
            let copyText = try String(
                contentsOf: vault.appendingPathComponent(attachmentCopy), encoding: .utf8)
            XCTAssertEqual(copyText, "attachment bytes, not the note")
        }
    }

    /// Finding 6 (minor, review round 1): an item that fails before writing
    /// anything real must not remove a folder the user already had, even
    /// though it is left empty by the failure.
    func testAnItemThatFailsLeavesAPreexistingFolderAlone() async throws {
        let vault = try makeVault()
        let bad = ImportItem(sourceID: "obsidian:bad", title: "Bad", body: .markdown("x"),
                             attachments: [], folderPath: ["Sub"], created: Date(),
                             modified: Date(), fidelity: [])
        // `Sub` does not exist yet — this run alone would create it. Force
        // the note reservation itself to fail (permission denied) so
        // NOTHING real ever gets written, by pointing the vault root
        // read-only right before the call. mkdir on an existing parent is a
        // no-op, but `createFile` for the reservation needs to actually
        // write into `Sub`, which needs write access on `Sub`'s parent
        // directory entry — i.e. on `vault` itself.
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: vault.appendingPathComponent("Sub").path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: vault.appendingPathComponent("Sub").path)
        }

        let plan = ImportPlanner.plan(items: [bad], vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(report.failed.count, 1)
        // `Sub` pre-existed this call (created above), so it must survive
        // regardless of being empty — the applier only ever removes a
        // directory IT created for a totally-failed item, never one that was
        // already there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Sub").path))
    }

    /// Finding 6 (minor, review round 1), the branch the test above never
    /// covered: when THIS call is the one that creates the target
    /// directory, and the item then fails before writing anything real,
    /// that freshly-created directory must be removed again rather than
    /// left behind as a fresh empty folder in the user's vault.
    func testAnItemThatFailsBeforeWritingAnythingLeavesNoFreshEmptyFolder() async throws {
        let vault = try makeVault()
        // `Sub` does not exist yet, and `vault` stays fully writable, so
        // `createDirectory(at: vault/Sub, withIntermediateDirectories: true)`
        // succeeds — this call alone creates `Sub`. The note reservation
        // that follows must then fail WITHOUT that permission change also
        // blocking the `mkdir` above it (that would throw before the `do`
        // block that owns `rollback()` even runs, which is the trap the
        // renamed test above already covers and this one must not repeat).
        // `umask` gets there cleanly: dropping the write bit from the
        // process umask before the call means `Sub` itself is CREATED with
        // no write permission (mkdir only needs write access on `vault`,
        // its parent, to succeed) while writing a file INTO `Sub` right
        // after — the note's placeholder reservation — needs write access
        // on `Sub` and fails.
        let originalUmask = umask(0o222)
        addTeardownBlock { _ = umask(originalUmask) }

        let bad = ImportItem(sourceID: "obsidian:bad", title: "Bad", body: .markdown("x"),
                             attachments: [], folderPath: ["Sub"], created: Date(),
                             modified: Date(), fidelity: [])
        let plan = ImportPlanner.plan(items: [bad], vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        _ = umask(originalUmask)
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(report.failed.count, 1)
        // `Sub` was created fresh by this call and ends up with nothing in
        // it — the applier must remove it again rather than leave a fresh
        // empty folder behind.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vault.appendingPathComponent("Sub").path))
    }

    /// Findings 3 & 4 (important, review round 1): timestamps must survive
    /// with time-of-day (ISO-8601, not day-only), and BOTH the title and
    /// `lore_import_id` must round-trip through `Frontmatter.parse` for
    /// values containing every YAML-hostile character this milestone's own
    /// scanners can legally produce: colon, `#`, a leading `-`, a quote, a
    /// newline, and non-ASCII text.
    func testHostileTitleAndImportIDRoundTripThroughFrontmatterParse() async throws {
        let vault = try makeVault()
        let hostileTitle = "-Meeting: Q3 \"notes\" #standup\nfollow-up — café"
        let hostileSourceID = "obsidian:notes/2026-08-09 #standup \"weird\"\npath.md"
        let created = Date(timeIntervalSince1970: 1_700_000_123)
        let modified = Date(timeIntervalSince1970: 1_700_000_456)

        let plannedItem = ImportItem(sourceID: hostileSourceID, title: hostileTitle,
                                     body: .markdown("hello"), attachments: [],
                                     folderPath: [], created: created, modified: modified,
                                     fidelity: [])
        let plan = ImportPlanner.plan(items: [plannedItem], vaultRoot: vault,
                                      existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)
        XCTAssertEqual(report.imported.count, 1)

        let text = try String(contentsOf: report.imported[0], encoding: .utf8)
        let note = Frontmatter.parse(text, path: report.imported[0])
        XCTAssertEqual(note.title, hostileTitle)
        XCTAssertEqual(importID(note), hostileSourceID)
        // Time-of-day must survive, not just the day — a day-only formatter
        // truncates both of these to the same UTC midnight.
        XCTAssertEqual(note.created.timeIntervalSince1970.rounded(),
                       created.timeIntervalSince1970.rounded())
        XCTAssertEqual(note.updated.timeIntervalSince1970.rounded(),
                       modified.timeIntervalSince1970.rounded())
    }

    /// Finding 1 (important, whole-branch review): `ObsidianSource` emits
    /// every non-`.md` file (images, PDFs, ...) as an item with an empty
    /// markdown body and itself as the sole attachment. Before the fix,
    /// `apply` wrote a note file for that too — a 500-image vault imported
    /// as 500 real images PLUS 500 junk empty `pic.png.md` notes. An
    /// attachment-only item — one the SOURCE declared as `kind: .file` — must
    /// write the attachment(s) only, no note file, and `report.imported`
    /// must point at the attachment that actually landed on disk, not a
    /// note URL that was never written.
    ///
    /// `kind` is now declared rather than inferred from an empty body; see
    /// `testAnEmptyBodiedNoteIsStillWrittenWhenTheSourceCallsItANote` for the
    /// case that inference got wrong.
    func testAttachmentOnlyItemWritesTheAttachmentAndNoNoteFile() async throws {
        let vault = try makeVault()
        let sourceDir = try makeVault()
        let source = sourceDir.appendingPathComponent("pic.png")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: source)

        let bad = ImportItem(sourceID: "obsidian:pic.png", title: "pic.png",
                             body: .markdown(""),
                             attachments: [ImportAttachment(sourceID: "obsidian:pic.png",
                                                            preferredName: "pic.png",
                                                            sourceURL: source)],
                             folderPath: [], created: Date(), modified: Date(), fidelity: [],
                             kind: .file)
        let plan = ImportPlanner.plan(items: [bad], vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.failed.count, 0)
        XCTAssertEqual(report.imported.count, 1)
        // No `pic.png.md` (or any `.md` at all) was written.
        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertFalse(entries.contains { $0.hasSuffix(".md") })
        // The attachment itself landed intact, and `imported` points at it.
        XCTAssertEqual(report.imported[0].lastPathComponent, "pic.png")
        XCTAssertEqual(try Data(contentsOf: report.imported[0]), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    /// THE CASE THE OLD SHAPE TEST GOT WRONG. An Apple note that is just a
    /// photo with a title is completely ordinary: empty body, one attachment.
    /// Inferring "attachment-only" from that shape imported it as a bare
    /// image, throwing away the title, both dates and any fidelity warnings —
    /// silent data loss on an entirely normal note.
    ///
    /// Now the SOURCE declares what the item is, so a `.note` gets its note
    /// file no matter how empty its body is.
    func testAnEmptyBodiedNoteIsStillWrittenWhenTheSourceCallsItANote() async throws {
        let vault = try makeVault()
        let sourceDir = try makeVault()
        let source = sourceDir.appendingPathComponent("photo.jpg")
        try Data([0x01, 0x02]).write(to: source)

        let photoNote = ImportItem(
            sourceID: "apple-notes:N1", title: "Sunset",
            body: .markdown(""),
            attachments: [ImportAttachment(sourceID: "apple-notes:N1/1",
                                           preferredName: "photo.jpg",
                                           sourceURL: source)],
            folderPath: [], created: Date(timeIntervalSince1970: 1),
            modified: Date(timeIntervalSince1970: 2), fidelity: [],
            kind: .note)
        let plan = ImportPlanner.plan(items: [photoNote], vaultRoot: vault,
                                      existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.failed.count, 0)
        let note = vault.appendingPathComponent("Sunset.md")
        let landed = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path),
                      "the note must survive; got \(landed)")
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("title: Sunset"), "got \(text)")
        XCTAssertTrue(text.contains("lore_import_id: apple-notes:N1")
                      || text.contains("lore_import_id: \"apple-notes:N1\""), "got \(text)")
        // And the photo landed beside it.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("photo.jpg").path))
    }

    /// A `.file` with no attachments would write nothing at all. It is
    /// malformed, so it falls through to the note path and produces a visible
    /// empty note rather than silently vanishing from the import.
    func testAFileItemWithNoAttachmentsStillProducesSomethingVisible() async throws {
        let vault = try makeVault()
        let broken = ImportItem(sourceID: "obsidian:gone.png", title: "gone.png",
                                body: .markdown(""), attachments: [], folderPath: [],
                                created: Date(), modified: Date(), fidelity: [],
                                kind: .file)
        let plan = ImportPlanner.plan(items: [broken], vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertTrue(report.imported[0].lastPathComponent.hasSuffix(".md"))
    }

    /// Finding 1 counterpart: an item with a real body AND an attachment is
    /// NOT attachment-only — both the note and the attachment must still
    /// land, exactly as before this fix.
    func testItemWithBodyAndAttachmentWritesBoth() async throws {
        let vault = try makeVault()
        let sourceDir = try makeVault()
        let source = sourceDir.appendingPathComponent("diagram.png")
        try Data([0x01, 0x02]).write(to: source)

        let plan = ImportPlanner.plan(
            items: [item("apple-notes:N1", "Plan", body: .markdown("hello"),
                        attachments: [ImportAttachment(sourceID: "att-1",
                                                       preferredName: "diagram.png",
                                                       sourceURL: source)])],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.failed.count, 0)
        // One note plus one attachment landed on disk.
        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertTrue(entries.contains("Plan.md"))
        XCTAssertTrue(entries.contains("diagram.png"))
        let noteText = try String(contentsOf: vault.appendingPathComponent("Plan.md"),
                                  encoding: .utf8)
        XCTAssertTrue(noteText.contains("hello"))
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("diagram.png")),
                       Data([0x01, 0x02]))
    }

    /// Finding 1, the deliberate pin for the case the attachment-only guard
    /// must NOT swallow: an empty body with NO attachments is a genuinely
    /// empty note (the user wrote nothing, or `ObsidianSource` flagged an
    /// unreadable file via a fidelity warning and imported it empty) — it
    /// still gets written as a note, same as before this fix.
    func testEmptyBodyWithNoAttachmentsStillWritesAnEmptyNote() async throws {
        let vault = try makeVault()
        let plan = ImportPlanner.plan(
            items: [item("obsidian:empty", "Empty", body: .markdown(""))],
            vaultRoot: vault, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: vault).apply(plan)

        XCTAssertEqual(report.imported.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent("Empty.md").path))
    }
}
