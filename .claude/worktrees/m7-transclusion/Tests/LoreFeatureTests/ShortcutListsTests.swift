import XCTest
@testable import LoreFeature

/// Pinned documents.
///
/// The "Recent" section this file also covered was removed: the sidebar shows
/// the vault, the history chevrons answer "back to what I was just on", and
/// ⌘P reaches anything by name, so recents was a fourth route to documents
/// already one of the other three away. Its tests went with it rather than
/// being left asserting a list nothing renders.
@MainActor
final class ShortcutListsTests: XCTestCase {

    private func vault(_ label: String = "shortcuts") throws -> (URL, LoreStore, FakeDocs) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store, docs)
    }

    @discardableResult
    private func note(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "---\nid: \(name)\ntitle: \(name)\n---\nbody".write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_pinningIsAToggleAndSurvivesARelaunch() async throws {
        let (root, store, docs) = try vault("pin")
        let a = try note(root, "a.md")
        await store.settleForTesting(); try store.rebuild()

        XCTAssertFalse(store.isPinned(a))
        store.togglePinned(a)
        XCTAssertTrue(store.isPinned(a))
        XCTAssertEqual(store.pinnedRows.map(\.path.lastPathComponent), ["a.md"])

        // A relaunch CLOSES the first store before the second opens. Without
        // this the two hold `DatabaseQueue`s on one SQLite file and the second
        // one's first write fails with "database is locked" — intermittently,
        // depending on whether the first store's background rescan is still
        // writing. Production never has two stores on one index; the test
        // should not either.
        store.shutdown()
        let reopened = LoreStore(documents: docs,
                                 indexPath: root.appendingPathComponent(".idx.sqlite"))
        try reopened.setVaultRootForTesting(root)
        await reopened.settleForTesting(); try reopened.rebuild()
        XCTAssertTrue(reopened.isPinned(a), "a pin must survive a relaunch")

        reopened.togglePinned(a)
        XCTAssertFalse(reopened.isPinned(a))
    }

    func test_pinnedRowsDropADeletedDocument() async throws {
        let (root, store, _) = try vault("pin-ghost")
        let a = try note(root, "a.md")
        await store.settleForTesting(); try store.rebuild()
        store.togglePinned(a)
        XCTAssertEqual(store.pinnedRows.count, 1)

        let row = try XCTUnwrap(store.rows.first { $0.path.lastPathComponent == "a.md" })
        _ = try store.trash(row)
        XCTAssertTrue(store.pinnedRows.isEmpty)
    }
}
