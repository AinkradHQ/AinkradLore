import XCTest
@testable import LoreFeature

/// Guards against state that is DECLARED but never rendered.
///
/// ## Why this test exists
///
/// Twice in one session, an overlay was added to `DocumentPane` by a scripted
/// text edit that silently failed to match. Both times the result compiled
/// cleanly and all 1199 tests passed, because:
///
///  - the `@State`/`@Binding` was still declared and still bound, so the type
///    checker was satisfied;
///  - the smoke tests CONSTRUCT the pane, and construction was never the
///    broken part;
///  - nothing else reads presentation state.
///
/// So `showingMentions` toggled a flag no view observed, and ⇧⌘B did nothing —
/// shipped, and merged. The defect was invisible to every existing test and
/// visible immediately to anyone clicking the button.
///
/// This asserts the crude thing the compiler cannot: that each presentation
/// flag is actually READ somewhere in the file that declares it. It is a
/// source-text check, which is unusual and deliberate — the alternative is a
/// UI test harness this project does not have, and the failure mode it catches
/// has now occurred twice.
final class PaneWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        // Resolved from this file's location so it works wherever the checkout
        // lives, rather than an absolute path baked into the test.
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // LoreFeatureTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // package root
        let url = root.appendingPathComponent("Sources/LoreFeature/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A flag that is declared once and never read again is a control wired to
    /// nothing.
    func test_presentationFlagsAreActuallyRendered() throws {
        let pane = try source("DocumentPane.swift")
        for flag in ["showingActions", "showingMentions"] {
            let uses = pane.components(separatedBy: flag).count - 1
            XCTAssertGreaterThan(uses, 1,
                                 "`\(flag)` is declared but never read — the control that "
                                 + "toggles it is wired to nothing")
        }
    }

    /// The two views those flags present must actually be referenced.
    func test_thePresentedViewsAreReferenced() throws {
        let pane = try source("DocumentPane.swift")
        XCTAssertTrue(pane.contains("DocumentActionsMenu("),
                      "the ⋯ menu is never constructed, so the button opens nothing")
        XCTAssertTrue(pane.contains("DocumentSlideover("),
                      "linked mentions are never constructed, so ⇧⌘B does nothing")
    }

    /// Split view added a second place the same defect can live: the column
    /// owns the header and the pane, so a request that reaches neither is
    /// invisible in exactly the same way.
    func test_theColumnRendersItsHeaderAndPane() throws {
        let column = try source("DocumentPaneColumn.swift")
        XCTAssertTrue(column.contains("DocumentHeaderBar("),
                      "the column renders no header, so a split pane has no breadcrumb "
                      + "or actions menu")
        XCTAssertTrue(column.contains("DocumentPane("),
                      "the column renders no pane, so a split shows nothing")
    }

    /// ⇧⌘B sets a shared flag; only the FOCUSED column may consume it, or both
    /// panes open their mentions at once.
    func test_theColumnGatesTheMentionsRequestOnFocus() throws {
        let column = try source("DocumentPaneColumn.swift")
        XCTAssertTrue(column.contains("isFocused ? $mentionsRequest"),
                      "an unfocused column consuming the request would open both panes' "
                      + "mentions from one keystroke")
    }

    /// The request channel from the command/menu must be consumed, or ⇧⌘B sets
    /// a flag that is never acted on.
    func test_theMentionsRequestIsConsumed() throws {
        let pane = try source("DocumentPane.swift")
        XCTAssertTrue(pane.contains("onChange(of: mentionsRequest)"),
                      "nothing consumes `mentionsRequest`, so ⇧⌘B is inert")
    }
}
