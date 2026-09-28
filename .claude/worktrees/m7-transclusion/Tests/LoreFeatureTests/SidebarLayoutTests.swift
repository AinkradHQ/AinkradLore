import XCTest
@testable import LoreFeature

/// Sidebar width, and the tag-chip counts beside it.
@MainActor
final class SidebarLayoutTests: XCTestCase {

    // MARK: - Resize arithmetic

    /// The bug the first version of the drag shipped with: `width` is the LIVE
    /// store value and updates as the drag proceeds, so applying `translation`
    /// to it on every event compounds and the divider accelerates away from
    /// the pointer. Stated here so it cannot come back quietly.
    func test_dragAppliesTranslationToTheStartWidthNotTheLiveOne() {
        let start: CGFloat = 280
        // Three events from one gesture: translations are cumulative from the
        // gesture's start, so the result must be start + latest, never a sum.
        XCTAssertEqual(SidebarResize.width(start: start, translation: 10), 290)
        XCTAssertEqual(SidebarResize.width(start: start, translation: 25), 305)
        XCTAssertEqual(SidebarResize.width(start: start, translation: 40), 320)
    }

    /// A sidebar dragged to 20pt is a sliver with no visible content and no
    /// grip wide enough to drag back.
    func test_widthIsClampedAtBothEnds() {
        XCTAssertEqual(SidebarResize.width(start: 200, translation: -9999),
                       LoreMetrics.minSidebarWidth)
        XCTAssertEqual(SidebarResize.width(start: 200, translation: 9999),
                       LoreMetrics.maxSidebarWidth)
    }

    /// Clamped on WRITE too, so every path through the store agrees — not just
    /// the drag.
    func test_theStoreClampsWhateverItIsHanded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-width-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))

        store.setSidebarWidth(4000)
        XCTAssertEqual(store.sidebarWidth, LoreMetrics.maxSidebarWidth)
        store.setSidebarWidth(1)
        XCTAssertEqual(store.sidebarWidth, LoreMetrics.minSidebarWidth)

        store.setSidebarWidth(340)
        // A relaunch must not lose it — and must not trust it blindly either:
        // the stored value comes from a file a user can edit.
        let reopened = LoreStore(documents: docs,
                                 indexPath: root.appendingPathComponent(".idx.sqlite"))
        XCTAssertEqual(reopened.sidebarWidth, 340)
    }

    func test_astoredWidthOutsideTheRangeIsClampedOnRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-width-bad-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        docs.setData("9999".data(using: .utf8), forKey: "sidebarWidth")

        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        XCTAssertEqual(store.sidebarWidth, LoreMetrics.maxSidebarWidth)
    }

    // MARK: - Tag counts

    func test_tagCountsCountNotesPerTag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-tags-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        try "---\nid: a\ntitle: A\ntags: [work, q1]\n---\nx".write(
            to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "---\nid: b\ntitle: B\ntags: [work]\n---\ny".write(
            to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        await_settle(store)
        try store.rebuild()

        XCTAssertEqual(store.tagCounts["work"], 2)
        XCTAssertEqual(store.tagCounts["q1"], 1)
        XCTAssertNil(store.tagCounts["absent"])
    }

    private func await_settle(_ store: LoreStore) {
        let expectation = XCTestExpectation(description: "settle")
        Task { await store.settleForTesting(); expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
    }
}
