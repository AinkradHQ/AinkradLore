import XCTest
@testable import LoreFeature

/// `PaneState` — one pane's document and its history.
///
/// These rules were previously reachable only through `LoreStore`, which meant
/// a vault on disk and an index to exercise them. Extracting the value ahead
/// of split view makes them assertable on their own, which is worth having
/// before a second pane doubles every one of them.
final class PaneStateTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/v/\(name)") }
    /// The store canonicalises; a plain path is enough here.
    private let key: (URL) -> String = { $0.path }

    func test_anewPaneHasNowhereToGo() {
        let pane = PaneState()
        XCTAssertFalse(pane.canGoBack)
        XCTAssertFalse(pane.canGoForward)
        XCTAssertNil(pane.historyIndex)
    }

    func test_visitsAccumulateAndBackBecomesAvailable() {
        var pane = PaneState()
        pane.recordVisit(url("a.md"), key: key)
        XCTAssertFalse(pane.canGoBack, "one visit is not a trail")
        pane.recordVisit(url("b.md"), key: key)
        XCTAssertTrue(pane.canGoBack)
        XCTAssertFalse(pane.canGoForward)
        XCTAssertEqual(pane.history.map(\.lastPathComponent), ["a.md", "b.md"])
    }

    /// Re-visiting the CURRENT document is not navigation. Treating it as such
    /// fills the stack with duplicates and makes Back appear broken — you
    /// press it and nothing moves.
    func test_revisitingTheCurrentDocumentRecordsNothing() {
        var pane = PaneState()
        pane.recordVisit(url("a.md"), key: key)
        pane.recordVisit(url("a.md"), key: key)
        pane.recordVisit(url("a.md"), key: key)
        XCTAssertEqual(pane.history.count, 1)
        XCTAssertFalse(pane.canGoBack)
    }

    /// The rule that makes Forward mean something: opening something new after
    /// going back abandons the forward trail.
    func test_anewVisitTruncatesTheForwardTrail() {
        var pane = PaneState()
        pane.recordVisit(url("a.md"), key: key)
        pane.recordVisit(url("b.md"), key: key)
        pane.historyIndex = 0                       // as if Back had been pressed
        pane.recordVisit(url("c.md"), key: key)

        XCTAssertEqual(pane.history.map(\.lastPathComponent), ["a.md", "c.md"])
        XCTAssertFalse(pane.canGoForward, "the abandoned trail must not remain reachable")
    }

    /// Going back to a document already in the trail is still not a new visit
    /// once the index points at it.
    func test_backThenRevisitingThatSameDocumentRecordsNothing() {
        var pane = PaneState()
        pane.recordVisit(url("a.md"), key: key)
        pane.recordVisit(url("b.md"), key: key)
        pane.historyIndex = 0
        pane.recordVisit(url("a.md"), key: key)
        XCTAssertEqual(pane.history.count, 2, "a.md is already where the index points")
    }

    /// A pane belongs to a vault: both its session and its history point into
    /// the one being closed.
    func test_resetForgetsEverything() {
        var pane = PaneState()
        pane.recordVisit(url("a.md"), key: key)
        pane.recordVisit(url("b.md"), key: key)
        pane.reset()
        XCTAssertTrue(pane.history.isEmpty)
        XCTAssertNil(pane.historyIndex)
        XCTAssertNil(pane.session)
        XCTAssertFalse(pane.canGoBack)
    }

    /// The key function is INJECTED so the value stays free of the store's
    /// canonicalisation — but it must actually be used, or `/tmp` and
    /// `/private/tmp` spellings of one document would read as two visits.
    func test_theKeyFunctionDecidesWhatCountsAsTheSameDocument() {
        var pane = PaneState()
        let collapsing: (URL) -> String = { _ in "same" }
        pane.recordVisit(url("a.md"), key: collapsing)
        pane.recordVisit(url("b.md"), key: collapsing)
        XCTAssertEqual(pane.history.count, 1,
                       "the key function is consulted, not the URL directly")
    }
}
