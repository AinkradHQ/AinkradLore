import XCTest
@testable import LoreFeature

/// What VoiceOver reads for a sidebar row.
///
/// Asserted directly because the label is the ONLY channel a screen-reader user
/// has for facts the sighted UI carries in glyphs and tints: which icon a row
/// wears, and whether it is the open document.
@MainActor
final class AccessibilityLabelTests: XCTestCase {

    private func row(_ name: String, type: String = MarkdownEngine.identifier,
                     title: String = "") -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: "/v/\(name)"), id: name,
                 title: title, tags: [], aliases: [], updated: Date(),
                 type: type, properties: [])
    }

    func test_aDocumentReadsAsItsTitle() {
        XCTAssertEqual(
            LoreSidebarRow.accessibilityLabel(for: row("a.md", title: "Quarterly Plan"),
                                              subtitle: nil, emptyTitleFallback: nil),
            "Quarterly Plan")
    }

    /// An untitled note falls back to the same name the row DISPLAYS, so the
    /// spoken and visible names cannot disagree.
    func test_anUntitledDocumentUsesTheDisplayedFallback() {
        XCTAssertEqual(
            LoreSidebarRow.accessibilityLabel(for: row("draft.md"),
                                              subtitle: nil,
                                              emptyTitleFallback: "Untitled"),
            "Untitled")
        XCTAssertEqual(
            LoreSidebarRow.accessibilityLabel(for: row("draft.md"),
                                              subtitle: nil, emptyTitleFallback: nil),
            "draft.md")
    }

    /// The document-vs-attachment distinction is drawn as two different SF
    /// Symbols and nothing else. It matters — an attachment has no Delete in
    /// its context menu — so it has to be spoken.
    func test_anAttachmentSaysSo() {
        let label = LoreSidebarRow.accessibilityLabel(
            for: row("data.zip", type: AttachmentEngine.identifier, title: "data.zip"),
            subtitle: nil, emptyTitleFallback: nil)
        XCTAssertEqual(label, "data.zip, attachment")
    }

    /// The tag line is folded into the row's own label rather than left as a
    /// separate element — otherwise VoiceOver reads a row as two unrelated
    /// fragments.
    func test_tagsAreFoldedIntoTheLabel() {
        XCTAssertEqual(
            LoreSidebarRow.accessibilityLabel(for: row("a.md", title: "Plan"),
                                              subtitle: "#work #q1",
                                              emptyTitleFallback: nil),
            "Plan, #work #q1")
    }

    func test_anEmptySubtitleAddsNothing() {
        XCTAssertEqual(
            LoreSidebarRow.accessibilityLabel(for: row("a.md", title: "Plan"),
                                              subtitle: "", emptyTitleFallback: nil),
            "Plan")
    }
}
