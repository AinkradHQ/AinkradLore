import XCTest
@testable import LoreFeature

/// The document header's two decisions — what it SAYS about the save, and what
/// it shows as the document's place — asserted directly.
///
/// Both are pure functions for the reason this project keeps repeating: SwiftUI
/// views are only smoke-testable here, so anything that decides something is
/// pulled out of the view and tested on its own.
@MainActor
final class DocumentHeaderTests: XCTestCase {

    // MARK: - Save state precedence

    /// The precedence that matters most: a document with unsaved edits whose
    /// WRITE IS FAILING must not report the reassuring "Unsaved…". `isDirty`
    /// is true in both situations, so testing it first would tell the user
    /// their work is merely waiting when it is actually not going to disk.
    func test_afailedSaveOutranksMerelyBeingDirty() {
        let state = DocumentSaveState.of(readOnly: false, hasSaveError: true,
                                         isDirty: true, lastSavedAt: Date())
        XCTAssertEqual(state, .failed)
        XCTAssertTrue(state.isAlarming)
    }

    /// Read-only outranks everything: nothing typed here will ever be saved,
    /// which is a more important thing to know than the state of any one write.
    func test_readOnlyOutranksEverything() {
        XCTAssertEqual(
            DocumentSaveState.of(readOnly: true, hasSaveError: true,
                                 isDirty: true, lastSavedAt: Date()),
            .readOnly)
    }

    /// A freshly opened, untouched document has NOT been saved, and must not
    /// claim to have been. `!isDirty` is true for it and for a document that
    /// genuinely just saved — collapsing the two is the small lie this case
    /// exists to prevent.
    func test_anUntouchedDocumentIsIdleNotSaved() {
        XCTAssertEqual(
            DocumentSaveState.of(readOnly: false, hasSaveError: false,
                                 isDirty: false, lastSavedAt: nil),
            .idle)
        XCTAssertEqual(
            DocumentSaveState.of(readOnly: false, hasSaveError: false,
                                 isDirty: false, lastSavedAt: nil).label(now: Date()),
            "", "an idle document must say nothing rather than claim a save")
    }

    func test_dirtyBeatsAPreviousSuccessfulSave() {
        XCTAssertEqual(
            DocumentSaveState.of(readOnly: false, hasSaveError: false,
                                 isDirty: true, lastSavedAt: Date()),
            .unsaved)
    }

    /// Only the failure is alarming — an ordinary save drawn in an
    /// attention-grabbing colour trains the user to ignore the indicator.
    func test_onlyFailureIsAlarming() {
        let now = Date()
        XCTAssertFalse(DocumentSaveState.saved(now).isAlarming)
        XCTAssertFalse(DocumentSaveState.unsaved.isAlarming)
        XCTAssertFalse(DocumentSaveState.readOnly.isAlarming)
        XCTAssertTrue(DocumentSaveState.failed.isAlarming)
    }

    /// The label settles rather than counting upward forever.
    func test_savedLabelSettlesAfterAMinute() {
        let at = Date()
        XCTAssertEqual(DocumentSaveState.saved(at).label(now: at), "Saved")
        XCTAssertEqual(DocumentSaveState.saved(at).label(now: at.addingTimeInterval(30)),
                       "Saved just now")
        XCTAssertEqual(DocumentSaveState.saved(at).label(now: at.addingTimeInterval(3600)),
                       "Saved")
    }

    // MARK: - Breadcrumb

    func test_breadcrumbShowsTheVaultRelativePlace() {
        let root = URL(fileURLWithPath: "/tmp/MyVault")
        let url = root.appendingPathComponent("Projects/Q1.md")
        XCTAssertEqual(DocumentHeaderBar.breadcrumb(for: url, root: root),
                       "MyVault ▸ Projects ▸ Q1.md")
    }

    func test_breadcrumbForADocumentAtTheVaultRoot() {
        let root = URL(fileURLWithPath: "/tmp/MyVault")
        XCTAssertEqual(
            DocumentHeaderBar.breadcrumb(for: root.appendingPathComponent("Inbox.md"),
                                         root: root),
            "MyVault ▸ Inbox.md")
    }

    /// A document outside the vault has no vault-relative path, so inventing
    /// one would be a fiction and showing its absolute path would not fit.
    func test_breadcrumbFallsBackToTheFilenameOutsideTheVault() {
        XCTAssertEqual(
            DocumentHeaderBar.breadcrumb(for: URL(fileURLWithPath: "/elsewhere/Stray.md"),
                                         root: URL(fileURLWithPath: "/tmp/MyVault")),
            "Stray.md")
    }

    func test_breadcrumbWithNoVaultIsJustTheFilename() {
        XCTAssertEqual(
            DocumentHeaderBar.breadcrumb(for: URL(fileURLWithPath: "/x/Note.md"), root: nil),
            "Note.md")
    }

    /// A sibling directory whose name merely STARTS with the vault's name is
    /// not inside it. Compared component-wise rather than by string prefix,
    /// which is what makes `/tmp/MyVaultArchive` fall back correctly instead
    /// of rendering as a child of `/tmp/MyVault`.
    func test_breadcrumbDoesNotTreatANamePrefixAsContainment() {
        XCTAssertEqual(
            DocumentHeaderBar.breadcrumb(
                for: URL(fileURLWithPath: "/tmp/MyVaultArchive/Old.md"),
                root: URL(fileURLWithPath: "/tmp/MyVault")),
            "Old.md")
    }
}
