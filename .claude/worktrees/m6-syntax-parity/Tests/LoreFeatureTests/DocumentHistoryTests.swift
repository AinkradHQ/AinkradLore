import XCTest
@testable import LoreFeature

/// Back/forward navigation and the warm-session cache — the two mechanisms
/// that replaced the tab bar.
@MainActor
final class DocumentHistoryTests: XCTestCase {

    private func vault(_ label: String = "history") throws -> (URL, LoreStore) {
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

    // MARK: - History

    func test_backAndForwardWalkTheTrail() throws {
        let (root, store) = try vault()
        let a = try note(root, "a.md"), b = try note(root, "b.md"), c = try note(root, "c.md")
        store.open(url: a); store.open(url: b); store.open(url: c)

        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)

        store.goBack()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "b.md")
        store.goBack()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
        XCTAssertFalse(store.canGoBack, "there is nothing before the first visit")

        store.goForward()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "b.md")
        XCTAssertTrue(store.canGoForward)
        _ = c
    }

    /// The rule that makes Forward mean anything: opening something new after
    /// going Back abandons the forward trail. Without truncation, Forward
    /// leads to places the user has no memory of choosing.
    func test_openingSomethingNewTruncatesTheForwardTrail() throws {
        let (root, store) = try vault("truncate")
        let a = try note(root, "a.md"), b = try note(root, "b.md"), c = try note(root, "c.md")
        store.open(url: a); store.open(url: b)
        store.goBack()
        XCTAssertTrue(store.canGoForward)

        store.open(url: c)
        XCTAssertFalse(store.canGoForward, "the abandoned trail must not remain reachable")
        store.goBack()
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "a.md")
    }

    /// Navigating through history must not itself record visits — otherwise
    /// Back pushes an entry Forward has to step over, and the stack grows
    /// every time it is used.
    func test_navigatingDoesNotRecordNewVisits() throws {
        let (root, store) = try vault("norecord")
        let a = try note(root, "a.md"), b = try note(root, "b.md")
        store.open(url: a); store.open(url: b)
        let depth = store.history.count

        store.goBack(); store.goForward(); store.goBack()

        XCTAssertEqual(store.history.count, depth, "history grew while merely walking it")
    }

    /// Re-opening the document already on screen is not navigation. Treating
    /// it as such fills the stack with duplicates and makes Back look broken —
    /// the user presses it and nothing appears to happen.
    func test_reopeningTheCurrentDocumentRecordsNothing() throws {
        let (root, store) = try vault("dupe")
        let a = try note(root, "a.md")
        store.open(url: a)
        store.open(url: a)
        store.open(url: a)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertFalse(store.canGoBack)
    }

    /// Back re-selects a document that is still WARM, rather than reloading
    /// it — this is what the session cache buys, and what keeps a scroll
    /// position and undo stack across a round trip.
    func test_backReusesTheWarmSessionRatherThanReopening() throws {
        let (root, store) = try vault("warm")
        let a = try note(root, "a.md"), b = try note(root, "b.md")
        store.open(url: a)
        let firstSession = store.selectedTab
        store.open(url: b)
        store.goBack()
        XCTAssertTrue(store.selectedTab === firstSession,
                      "Back rebuilt the session instead of reusing the warm one")
    }

    func test_historyIsClearedWhenTheVaultChanges() throws {
        let (root, store) = try vault("vaultswap")
        store.open(url: try note(root, "a.md"))
        XCTAssertFalse(store.history.isEmpty)

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-other-\(UUID())")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try store.setVaultRootForTesting(other)

        XCTAssertTrue(store.history.isEmpty, "history pointed into the vault that just closed")
        XCTAssertFalse(store.canGoBack)
    }

    // MARK: - Warm-session eviction

    /// The cache is bounded, so a long session cannot accumulate sessions
    /// without limit.
    func test_coldSessionsAreEvictedPastTheLimit() throws {
        let (root, store) = try vault("evict")
        for i in 0..<(LoreStore.warmSessionLimit + 4) {
            store.open(url: try note(root, "n\(i).md"))
        }
        XCTAssertLessThanOrEqual(store.tabs.count, LoreStore.warmSessionLimit)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent,
                       "n\(LoreStore.warmSessionLimit + 3).md",
                       "the open document must never be evicted")
    }

    /// The refusal that makes the cache safe: a document with unsaved edits is
    /// never evicted to honour the size bound. A cache that discards unsaved
    /// work to stay small is the exact bug this codebase spends its comments
    /// preventing — so the limit is a target, not a guarantee.
    func test_dirtySessionsSurviveEvictionEvenPastTheLimit() throws {
        let (root, store) = try vault("evict-dirty")
        store.open(url: try note(root, "precious.md"))
        let precious = try XCTUnwrap(store.selectedTab)
        precious.markChanged()
        XCTAssertTrue(precious.isDirty)

        for i in 0..<(LoreStore.warmSessionLimit + 4) {
            store.open(url: try note(root, "filler\(i).md"))
        }

        XCTAssertTrue(store.tabs.contains { $0 === precious },
                      "a document with unsaved edits was evicted to honour the cache bound")
    }

    /// Eviction takes the COLDEST first, so the documents a user is moving
    /// between stay loaded.
    func test_evictionTakesTheLeastRecentlyUsedFirst() throws {
        let (root, store) = try vault("evict-lru")
        let first = try note(root, "first.md")
        store.open(url: first)
        for i in 0..<(LoreStore.warmSessionLimit - 1) {
            store.open(url: try note(root, "mid\(i).md"))
        }
        // Re-touch the oldest so it is no longer the coldest.
        store.open(url: first)
        store.open(url: try note(root, "newest.md"))

        XCTAssertTrue(store.tabs.contains { $0.url.lastPathComponent == "first.md" },
                      "a recently revisited document was evicted as though it were cold")
    }
}
