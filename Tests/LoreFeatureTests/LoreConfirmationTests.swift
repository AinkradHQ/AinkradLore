import XCTest

@testable import LoreFeature

/// The two system alerts that became `AinkradConfirmDialog`s keep their text,
/// their labels, and the store paths their buttons took.
@MainActor
final class LoreConfirmationTests: XCTestCase {
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    private func makeStore() throws -> (LoreStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-confirm-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdDirs.append(root)
        let store = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        return (store, root)
    }

    /// "Create this note?": Create goes through `createAndOpenNote` (the file
    /// exists and is the open tab) and a failure is reported, not swallowed;
    /// Cancel only dismisses and writes nothing.
    func test_createNoteConfirmCreatesAndOpensAndCancelOnlyDismisses() async throws {
        let (store, root) = try makeStore()
        await store.settleForTesting()
        var failures: [String] = []
        var dismissals = 0

        let cancelled = LoreConfirmation.createNote(
            named: "Budget 2027", store: store, onFailure: { failures.append($0) },
            dismiss: { dismissals += 1 })
        XCTAssertEqual(cancelled.title, "Create this note?")
        XCTAssertEqual(cancelled.message, "\"Budget 2027\" doesn't exist in this vault yet.")
        XCTAssertEqual(cancelled.confirmTitle, "Create")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        cancelled.cancel()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), before, "Cancel must write nothing")
        XCTAssertNil(store.selectedTab)
        XCTAssertEqual(dismissals, 1)

        let confirmed = LoreConfirmation.createNote(
            named: "Budget 2027", store: store, onFailure: { failures.append($0) },
            dismiss: { dismissals += 1 })
        confirmed.confirm()
        confirmed.cancel()  // how the dialog closes after Create
        let opened = try XCTUnwrap(store.selectedTab?.url, "Create must open the note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path), "Create must write the note")
        XCTAssertEqual((store.selectedTab?.engine as? MarkdownEngine)?.note.title, "Budget 2027")
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(failures, [])

        LoreConfirmation.createNote(
            named: "", store: store, onFailure: { failures.append($0) }, dismiss: {}
        ).confirm()
        XCTAssertEqual(failures.count, 1, "a refused create must reach the user")
        XCTAssertTrue(failures[0].hasPrefix("Couldn't create \"\": "), failures[0])
    }

    /// The title refusal: its own title, the reason as the message, "OK" — and
    /// no store work on either button, exactly as the alert's lone OK.
    func test_titleRefusalBothButtonsOnlyDismiss() throws {
        let (store, root) = try makeStore()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var dismissals = 0
        let refusal = LoreConfirmation.titleRefusal(
            title: "Couldn't rename", reason: "“Plan.md” already exists."
        ) { dismissals += 1 }
        XCTAssertEqual(refusal.title, "Couldn't rename")
        XCTAssertEqual(refusal.message, "“Plan.md” already exists.")
        XCTAssertEqual(refusal.confirmTitle, "OK")

        refusal.confirm()
        XCTAssertEqual(dismissals, 0, "OK's work is nothing; the dialog closes through cancel")
        refusal.cancel()
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        XCTAssertNil(store.selectedTab)
    }
}
