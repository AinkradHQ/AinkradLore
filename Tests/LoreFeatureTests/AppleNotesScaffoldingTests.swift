import XCTest

@testable import LoreFeature

/// The AppleScript source, driven through an injected runner — the shipping
/// Apple Notes importer, and the part of it that needs no Automation grant.
///
/// A test must never launch Notes.app: it would depend on the contents of one
/// particular note library and prompt for a TCC grant in the middle of a suite
/// run.
final class AppleNotesScriptSourceTests: XCTestCase {
    private struct StubRunner: ScriptRunner {
        let output: String
        func run(_ source: String) throws -> String { output }
    }

    private struct DenyingRunner: ScriptRunner {
        func run(_ source: String) throws -> String {
            throw ImportSourceError.permissionDenied("Automation not allowed")
        }
    }

    /// Two records in the SEVEN-field shape the script emits: id, title,
    /// account, folder, created, modified, body. Account and folder are
    /// separate fields because a Notes library routinely holds several folders
    /// all named "Notes" — one per account — and a single container field
    /// would silently merge them into one vault directory.
    ///
    /// Dates are seconds since the Unix epoch, deliberately not a localised
    /// date string.
    private let canned = """
        x-coredata://N1
        Groceries
        iCloud
        Shopping
        978307200
        978307300
        <p>milk</p>
        \u{1E}
        x-coredata://N2
        Ideas
        iCloud
        Notes
        978307200
        978307300
        <p>a <b>bold</b> plan</p>
        """

    func testParsesEveryRecord() {
        let items = AppleNotesScriptSource.parse(canned)
        XCTAssertEqual(items.map(\.title), ["Groceries", "Ideas"])
        XCTAssertEqual(items[0].sourceID, "apple-notes:x-coredata://N1")
        XCTAssertEqual(items[0].created, Date(timeIntervalSince1970: 978_307_200))
        guard case .html(let raw) = items[1].body else { return XCTFail("expected .html") }
        XCTAssertTrue(raw.contains("<b>bold</b>"))
    }

    /// Real libraries hold one "Notes" folder PER ACCOUNT. Keying the vault
    /// path on the folder name alone merges an Exchange note into the iCloud
    /// tree; the account has to be a path component of its own.
    func testTheAccountIsAPathComponentAboveTheFolder() {
        let items = AppleNotesScriptSource.parse(canned)
        XCTAssertEqual(items[0].folderPath, ["iCloud", "Shopping"])
        XCTAssertEqual(items[1].folderPath, ["iCloud", "Notes"])
    }

    /// AppleScript renders a nine-digit seconds difference in SCIENTIFIC
    /// NOTATION (`1.660637018E+9`), not as a plain integer — observed against
    /// the real Notes.app, and the reason the previous doc comment here was
    /// wrong. Swift's `Double` parses that form exactly, but a fixture written
    /// only with plain integers never proved it.
    func testParsesTheScientificNotationRealAppleScriptActuallyEmits() {
        let items = AppleNotesScriptSource.parse(
            """
            x-coredata://N1
            Exponent
            iCloud
            Notes
            1.660637018E+9
            1.695563356E+9
            <p>x</p>
            """)
        XCTAssertEqual(items.first?.created, Date(timeIntervalSince1970: 1_660_637_018))
        XCTAssertEqual(items.first?.modified, Date(timeIntervalSince1970: 1_695_563_356))
    }

    /// The folder name is dropped from the path when empty, but the account is
    /// still a real location — an unfoldered note must not land at the root.
    func testANoteWithNoFolderStillLandsUnderItsAccount() {
        let items = AppleNotesScriptSource.parse(
            """
            x-coredata://N1
            Loose
            iCloud

            0
            0
            <p>x</p>
            """)
        XCTAssertEqual(items.first?.folderPath, ["iCloud"])
    }

    /// A note from this source is always a `.note`, never a `.file` — an Apple
    /// note that is just a photo with a title is ordinary, and must keep its
    /// title and dates. See `ImportItemKind`.
    func testEveryScriptedNoteIsANoteNotAFile() {
        XCTAssertTrue(AppleNotesScriptSource.parse(canned).allSatisfy { $0.kind == .note })
    }

    func testAMultiLineBodyIsKeptWhole() {
        let items = AppleNotesScriptSource.parse(
            """
            x-coredata://N1
            Long
            iCloud
            Notes
            0
            0
            <p>one</p>
            <p>two</p>
            """)
        guard case .html(let raw) = items[0].body else { return XCTFail("expected .html") }
        XCTAssertEqual(raw, "<p>one</p>\n<p>two</p>")
    }

    func testIgnoresATrailingRecordSeparator() {
        XCTAssertEqual(AppleNotesScriptSource.parse(canned + "\n\u{1E}\n").count, 2)
    }

    /// Padding a truncated record would import a note with a fabricated title
    /// or date. Dropping it loses one note from a run the user can repeat.
    func testDropsATruncatedRecordRatherThanGuessingAtItsFields() {
        XCTAssertTrue(AppleNotesScriptSource.parse("x-coredata://N1\nJust a title").isEmpty)
        // Six fields was the OLD complete record and is now a truncated one.
        // Accepting it would read the created date as a folder name.
        XCTAssertTrue(
            AppleNotesScriptSource.parse(
                """
                x-coredata://N1
                Groceries
                Shopping
                978307200
                978307300
                <p>milk</p>
                """
            ).isEmpty)
    }

    /// An Automation denial is a DIFFERENT grant from Full Disk Access, and
    /// must surface as its own actionable state rather than a generic failure.
    func testScanSurfacesAutomationDenialAsPermissionDenied() async {
        do {
            _ = try await AppleNotesScriptSource(runner: DenyingRunner()).scan()
            XCTFail("expected .permissionDenied")
        } catch let error as ImportSourceError {
            guard case .permissionDenied = error else {
                return XCTFail("expected .permissionDenied, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// `name of container of n` errors with -1700 against the real Notes.app —
    /// AppleScript will not coerce the `«class cntr»` reference to text, and
    /// the script dies before emitting a single record. It shipped that way
    /// because every test here parses canned output and none run the script.
    ///
    /// This assertion cannot prove the script works; only executing it can, and
    /// that is what the Dev Host walkthrough is for. What it CAN do is stop the
    /// one construction already known to be fatal from coming back.
    func testTheScriptNeverAsksANoteForItsContainer() {
        let script = AppleNotesScriptSource.script(stagingRoot: "/tmp/x")
        XCTAssertFalse(script.contains("container of"))
        XCTAssertTrue(script.contains("notes of f"))
    }

    /// The staging root has to reach the script, or `save` writes nowhere the
    /// caller can find and every attachment silently becomes unavailable.
    func testTheStagingRootReachesTheScript() {
        XCTAssertTrue(
            AppleNotesScriptSource.script(stagingRoot: "/tmp/stage-me")
                .contains("\"/tmp/stage-me\""))
    }

    /// Importing the trash would resurrect deleted notes into the vault, where
    /// nothing distinguishes them from what the user meant to keep.
    func testTheScriptSkipsRecentlyDeleted() {
        XCTAssertTrue(
            AppleNotesScriptSource.script(stagingRoot: "/tmp/x")
                .contains("if fname is not \"Recently Deleted\""))
    }

    // MARK: - attachments

    private let US = "\u{1F}"

    private func withAttachments(_ block: String) -> String {
        """
        x-coredata://N1
        Holiday
        iCloud
        Notes
        0
        0
        <p>see photo</p>
        \(US)
        \(block)
        """
    }

    /// Every accessor here is unwrapped rather than subscripted. A test that
    /// indexes an empty array TRAPS, which takes the whole runner down and
    /// makes xcodebuild restart it — and the summary then sums totals across
    /// launches, so a crash reads as a larger passing run. Found the hard way:
    /// a mutation check crashed here instead of failing.
    func testAnAttachmentCarriesItsRealNameAndStagedBytes() throws {
        let items = AppleNotesScriptSource.parse(
            withAttachments("x-coredata://A1\(US)Pasted Graphic.png\(US)/tmp/stage/1-1.png"))
        let attachment = try XCTUnwrap(items.first?.attachments.first)
        XCTAssertEqual(items.first?.attachments.count, 1)
        XCTAssertEqual(attachment.preferredName, "Pasted Graphic.png")
        XCTAssertEqual(attachment.sourceURL?.path, "/tmp/stage/1-1.png")
        XCTAssertEqual(attachment.sourceID, "apple-notes:x-coredata://A1")
    }

    /// The body must stop at the marker. If the attachment block leaked into
    /// the body, every note with a photo would render its own manifest.
    func testTheAttachmentBlockIsNotPartOfTheBody() throws {
        let items = AppleNotesScriptSource.parse(
            withAttachments("x-coredata://A1\(US)pic.png\(US)/tmp/stage/1-1.png"))
        guard case .html(let raw) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected .html")
        }
        XCTAssertEqual(raw, "<p>see photo</p>")
    }

    /// A link preview has `name == missing value` and cannot be saved. It is
    /// KEPT with a warning rather than dropped — a body referring to an image
    /// that is silently absent is the half-import this milestone exists to stop.
    func testAnUnexportableAttachmentIsWarnedAboutRatherThanDropped() throws {
        let items = AppleNotesScriptSource.parse(
            withAttachments("x-coredata://A1\(US)\(US)"))
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.attachments.count, 1)
        XCTAssertNil(item.attachments.first?.sourceURL)
        XCTAssertEqual(item.fidelity.map(\.kind), [.attachmentUnavailable])
    }

    /// A named attachment that failed to save says WHICH one. "An attachment"
    /// is not actionable when the note has four.
    func testAFailedNamedAttachmentIsNamedInItsWarning() throws {
        let items = AppleNotesScriptSource.parse(
            withAttachments("x-coredata://A1\(US)invoice.pdf\(US)"))
        let warning = try XCTUnwrap(items.first?.fidelity.first)
        XCTAssertTrue(warning.detail.contains("invoice.pdf"))
    }

    func testEveryAttachmentOfANoteIsCarried() {
        let items = AppleNotesScriptSource.parse(
            withAttachments(
                """
                x-coredata://A1\(US)a.png\(US)/tmp/stage/1-1.png
                x-coredata://A2\(US)b.png\(US)/tmp/stage/1-2.png
                x-coredata://A3\(US)c.png\(US)/tmp/stage/1-3.png
                """))
        XCTAssertEqual(items.first?.attachments.map(\.preferredName), ["a.png", "b.png", "c.png"])
        XCTAssertEqual(items.first?.fidelity.isEmpty, true)
    }

    /// A note that is nothing but a photo is ORDINARY in Apple Notes. Inferring
    /// `.file` from that shape is what loses its title and dates.
    func testAPhotoOnlyNoteIsStillANote() {
        let items = AppleNotesScriptSource.parse(
            """
            x-coredata://N1
            Beach

            Notes
            0
            0

            \(US)
            x-coredata://A1\(US)beach.png\(US)/tmp/stage/1-1.png
            """)
        XCTAssertEqual(items.first?.kind, .note)
        XCTAssertEqual(items.first?.title, "Beach")
        XCTAssertEqual(items.first?.attachments.count, 1)
    }

    /// Every fixture written before attachments existed has no marker, and must
    /// keep parsing as a note with no attachments rather than becoming invalid.
    func testARecordWithNoAttachmentMarkerStillParses() {
        let items = AppleNotesScriptSource.parse(canned)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.attachments.isEmpty })
    }

    func testScanRunsTheScriptThroughTheInjectedRunner() async throws {
        let items = try await AppleNotesScriptSource(runner: StubRunner(output: canned)).scan()
        XCTAssertEqual(items.count, 2)
    }
}
