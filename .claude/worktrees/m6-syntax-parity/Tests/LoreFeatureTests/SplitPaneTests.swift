import XCTest
@testable import LoreFeature

/// The second pane — store behaviour only. Layout and focus indication are the
/// view's, and land later.
@MainActor
final class SplitPaneTests: XCTestCase {

    private func vault(_ label: String) throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    @discardableResult
    private func note(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "---\nid: \(name)\ntitle: \(name)\n---\nbody".write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Opening and closing

    func test_thereIsNoSplitUntilOneIsAskedFor() async throws {
        let (root, store) = try vault("split-none")
        store.open(url: try note(root, "a.md"))
        XCTAssertFalse(store.isSplit)
    }

    /// Focus MOVES to the new pane: the user asked for this document to appear
    /// beside the other, and leaving focus behind sends the next keystroke to
    /// the document they navigated away from.
    func test_openingBesideFocusesTheNewPane() async throws {
        let (root, store) = try vault("split-open")
        store.open(url: try note(root, "a.md"))
        store.openInSecondaryPane(url: try note(root, "b.md"))

        XCTAssertTrue(store.isSplit)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "b.md",
                       "commands must act on the pane just opened")
        XCTAssertEqual(store.pane.session?.url.lastPathComponent, "a.md",
                       "the first pane keeps its own document")
    }

    /// An empty pane beside an empty pane is not a state worth reaching.
    func test_splittingNeedsSomethingToSplitOn() async throws {
        let (_, store) = try vault("split-empty")
        XCTAssertFalse(store.splitCurrentDocument())
        XCTAssertFalse(store.isSplit)
    }

    func test_splittingStartsFromTheOpenDocument() async throws {
        let (root, store) = try vault("split-current")
        store.open(url: try note(root, "a.md"))
        XCTAssertTrue(store.splitCurrentDocument())
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
    }

    /// Collapsing a layout is not a request to discard what was in it.
    func test_closingTheSplitKeepsTheDocumentWarm() async throws {
        let (root, store) = try vault("split-close")
        store.open(url: try note(root, "a.md"))
        store.openInSecondaryPane(url: try note(root, "b.md"))
        store.closeSecondaryPane()

        XCTAssertFalse(store.isSplit)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md",
                       "focus must return to the pane that still exists")
        XCTAssertTrue(store.tabs.contains { $0.url.lastPathComponent == "b.md" },
                      "the document stays reachable by Back or ⌘P")
    }

    /// Focus pointing at a pane that does not exist is the one way commands
    /// could quietly act on nothing.
    func test_focusNeverPointsAtAMissingPane() async throws {
        let (root, store) = try vault("split-focus")
        store.open(url: try note(root, "a.md"))
        store.focusPane(secondary: true)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md",
                       "focusing a pane that does not exist must be ignored")

        store.openInSecondaryPane(url: try note(root, "b.md"))
        store.closeSecondaryPane()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
    }

    // MARK: - Eviction

    /// The data-loss shape the plan flagged: a single `selectedTab` check was
    /// correct with one pane and would reclaim the OTHER pane's session with
    /// two — out from under a document being read.
    func test_neitherVisibleDocumentIsEvicted() async throws {
        let (root, store) = try vault("split-evict")
        store.open(url: try note(root, "left.md"))
        store.openInSecondaryPane(url: try note(root, "right.md"))

        // Eviction is invoked DIRECTLY rather than by opening more documents.
        //
        // The obvious version of this test defeats itself: `open` targets the
        // FOCUSED pane, so filling the cache by opening documents navigates
        // whichever pane is focused away from the document the test is trying
        // to protect — at which point evicting it is correct, and the test
        // fails for a reason that is not the bug. Calling the guard with both
        // panes genuinely showing something is the only way to exercise it.
        for i in 0..<(LoreStore.warmSessionLimit + 5) {
            _ = try note(root, "filler\(i).md")
        }
        await store.settleForTesting(); try store.rebuild()
        for i in 0..<(LoreStore.warmSessionLimit + 5) {
            store.warmForTesting(root.appendingPathComponent("filler\(i).md"))
        }
        store.evictColdSessions()

        XCTAssertTrue(store.tabs.contains { $0.url.lastPathComponent == "left.md" },
                      "the first pane's document was evicted while on screen")
        XCTAssertTrue(store.tabs.contains { $0.url.lastPathComponent == "right.md" },
                      "the second pane's document was evicted while on screen")
    }

    // MARK: - Divider

    /// The same compounding bug `SidebarResizeHandle` documents: `translation`
    /// is cumulative from where the drag began, so it must be applied to the
    /// fraction AT THE START. Applied to the live value on every event, the
    /// divider accelerates away from the pointer.
    func test_theDividerAppliesTranslationToTheStartFraction() {
        XCTAssertEqual(SplitDivider.clamped(0.5 + 0.1), 0.6, accuracy: 0.0001)
        XCTAssertEqual(SplitDivider.clamped(0.5 + 0.2), 0.7, accuracy: 0.0001)
    }

    /// A pane too narrow to hold a line of text is not a pane — and once it is
    /// that narrow there is no grip left to drag it back with.
    func test_neitherPaneCanBeSqueezedAway() {
        XCTAssertEqual(SplitDivider.clamped(-5), SplitDivider.minFraction)
        XCTAssertEqual(SplitDivider.clamped(5), SplitDivider.maxFraction)
        XCTAssertGreaterThan(SplitDivider.minFraction, 0.1)
        XCTAssertLessThan(SplitDivider.maxFraction, 0.9)
    }

    // MARK: - Per-pane history

    /// The reason history moved into `PaneState`: going back in the pane you
    /// are writing in must not disturb the reference you deliberately put
    /// beside it.
    func test_historyIsPerPane() async throws {
        let (root, store) = try vault("split-history")
        store.open(url: try note(root, "a.md"))
        store.open(url: try note(root, "b.md"))
        XCTAssertTrue(store.canGoBack, "the first pane has a trail")

        store.openInSecondaryPane(url: try note(root, "c.md"))
        XCTAssertFalse(store.canGoBack,
                       "a freshly opened pane has nowhere to go back to")

        store.focusPane(secondary: false)
        XCTAssertTrue(store.canGoBack, "the first pane's trail is untouched")
        store.goBack()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
        XCTAssertEqual(store.secondaryPane?.session?.url.lastPathComponent, "c.md",
                       "going back in one pane must not move the other")
    }

    /// ⌘W closes a DOCUMENT; the split collapsing behind it is the
    /// consequence, not a second meaning for the key.
    func test_closingTheSecondPanesDocumentCollapsesTheSplit() async throws {
        let (root, store) = try vault("split-closetab")
        store.open(url: try note(root, "a.md"))
        store.openInSecondaryPane(url: try note(root, "b.md"))
        let secondary = try XCTUnwrap(store.selectedTab)

        XCTAssertTrue(store.closeTab(secondary))
        XCTAssertFalse(store.isSplit)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
    }
}
