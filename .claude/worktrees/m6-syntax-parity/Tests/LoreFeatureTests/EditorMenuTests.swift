import AppKit
import XCTest
@testable import LoreFeature

@MainActor
final class EditorMenuTests: XCTestCase {

    // MARK: - Word lookup

    func test_findsTheWordUnderAnInteriorOffset() {
        let text = "the quikc brown fox"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: 6))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    /// A click at the very start of a word belongs to that word, not the space
    /// before it — otherwise right-clicking a misspelling you just double
    /// clicked offers suggestions for nothing.
    func test_anOffsetAtAWordStartBelongsToThatWord() {
        let text = "the quikc brown"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: 4))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    /// A GENUINE gap — two spaces, so the offset sits squarely between two
    /// non-word characters and does not fall back to either neighbouring
    /// word. (A SINGLE space right after a word is the caret-after-typing
    /// case, and DOES resolve — see
    /// `test_caretDirectlyAfterAWordMidDocumentBelongsToThatWord` below.)
    func test_whitespaceHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "the  quikc", atUTF16: 4))
    }

    /// The start of a line is the other genuine gap: nothing precedes it to
    /// fall back to.
    func test_startOfLineHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "\nquikc", atUTF16: 0))
    }

    /// The actual shape of "type a word, then right-click it": the caret
    /// sits on the space right AFTER the word, not inside it, because typing
    /// advances the caret past the last character typed. Without falling
    /// back to the preceding character here, the editor's context menu would
    /// offer no spelling suggestions for the ordinary case of a
    /// mid-document typo, and only ever work at the very end of a document —
    /// which was this project's actual defect until this test was added.
    func test_caretDirectlyAfterAWordMidDocumentBelongsToThatWord() {
        let text = "the quikc mistake"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: 9))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    /// The same caret-after-typing case, but for the last word on the page —
    /// there is no character AT the offset at all here, only one before it.
    func test_caretAtEndOfDocumentBelongsToTheLastWord() {
        let text = "the quikc"
        let range = try? XCTUnwrap(WordAtPoint.range(in: text, atUTF16: (text as NSString).length))
        XCTAssertEqual((text as NSString).substring(with: range ?? NSRange()), "quikc")
    }

    func test_anEmptyDocumentHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "", atUTF16: 0))
    }

    /// An offset past the end must return nil rather than trap. This is the
    /// recorded hazard: a test that TRAPS takes the runner down, xcodebuild
    /// restarts it, and the summary then sums across launches — so a crash can
    /// read as a larger passing run.
    func test_anOffsetPastTheEndHasNoWord() {
        XCTAssertNil(WordAtPoint.range(in: "abc", atUTF16: 99))
    }

    // MARK: - Menu construction

    /// With no selection, Cut and Copy are absent rather than present and
    /// dead. A menu that offers what it cannot do teaches the wrong thing.
    func test_withoutASelectionThereIsNoCutOrCopy() {
        let items = EditorMenuItems.build(selection: NSRange(location: 3, length: 0),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertFalse(titles.contains("Cut"))
        XCTAssertFalse(titles.contains("Copy"))
        XCTAssertTrue(titles.contains("Paste"))
        XCTAssertTrue(titles.contains("Select All"))
    }

    func test_withASelectionCutAndCopyAppear() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 4),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Cut"))
        XCTAssertTrue(titles.contains("Copy"))
    }

    /// The markdown actions are the reason this menu exists at all.
    func test_theMarkdownActionsAreAlwaysOffered() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 4),
                                          suggestions: [],
                                          actions: .noop)
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Link"))
        XCTAssertTrue(titles.contains("Code"))
        XCTAssertTrue(titles.contains("Heading"))
    }

    func test_spellingSuggestionsAppearAboveEverythingElse() {
        let items = EditorMenuItems.build(selection: NSRange(location: 4, length: 5),
                                          suggestions: ["quick", "quick-fire"],
                                          actions: .noop)
        XCTAssertEqual(items.first?.title, "quick")
        XCTAssertTrue(items.map(\.title).contains("Ignore Spelling"))
        XCTAssertTrue(items.map(\.title).contains("Learn Spelling"))
    }

    /// A correctly spelled word yields no suggestions and must not leave an
    /// empty spelling group behind.
    func test_noSuggestionsMeansNoSpellingGroup() {
        let items = EditorMenuItems.build(selection: NSRange(location: 0, length: 3),
                                          suggestions: [],
                                          actions: .noop)
        XCTAssertFalse(items.map(\.title).contains("Ignore Spelling"))
    }

    // MARK: - toggleHeading's marker strip (whole-branch review, MINOR 4)
    //
    // `toggleHeading` used to test only `line.hasPrefix("## ")`, so a line
    // already carrying a DIFFERENT heading level got a second `## ` prefixed
    // onto it instead of toggled: `# Title` became `## # Title`. These assert
    // `stripHeadingMarker` directly — the piece that decides what counts as
    // an existing heading to strip.

    func test_stripHeadingMarker_noHeadingReturnsNil() {
        XCTAssertNil(MarkdownEditorMenuActions.stripHeadingMarker(from: "plain text"))
    }

    func test_stripHeadingMarker_singleHash() {
        let stripped = try? XCTUnwrap(
            MarkdownEditorMenuActions.stripHeadingMarker(from: "# Title"))
        XCTAssertEqual(stripped, "Title")
    }

    /// `## x` must toggle OFF, not double to `## ## x`.
    func test_stripHeadingMarker_doubleHashStripsCleanly() {
        let stripped = try? XCTUnwrap(
            MarkdownEditorMenuActions.stripHeadingMarker(from: "## x"))
        XCTAssertEqual(stripped, "x")
    }

    func test_stripHeadingMarker_sixHashesIsTheMax() {
        let stripped = try? XCTUnwrap(
            MarkdownEditorMenuActions.stripHeadingMarker(from: "###### deepest"))
        XCTAssertEqual(stripped, "deepest")
    }

    /// A line that merely STARTS with `#` but has no space after the run of
    /// hashes — a tag, not a heading — must be left alone.
    func test_stripHeadingMarker_hashWithNoSpaceIsNotAHeading() {
        XCTAssertNil(MarkdownEditorMenuActions.stripHeadingMarker(from: "#tag"))
    }

    // MARK: - toggleHeading end to end, through the real edit path

    private func makeTextView(_ text: String) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.isRichText = false
        tv.string = text
        return tv
    }

    func test_toggleHeading_promotesAPlainLineToLevelTwo() throws {
        let tv = makeTextView("Title")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        MarkdownEditorMenuActions.toggleHeading(in: tv)
        XCTAssertEqual(tv.string, "## Title")
    }

    /// `# Title` retoggles to `## Title`, never `## # Title`.
    func test_toggleHeading_reprefixesALevelOneHeadingRatherThanDoubling() throws {
        let tv = makeTextView("# Title")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        MarkdownEditorMenuActions.toggleHeading(in: tv)
        XCTAssertEqual(tv.string, "## Title")
    }

    func test_toggleHeading_levelTwoTogglesOff() throws {
        let tv = makeTextView("## Title")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        MarkdownEditorMenuActions.toggleHeading(in: tv)
        XCTAssertEqual(tv.string, "Title")
    }

    func test_toggleHeading_levelSixReprefixesToLevelTwo() throws {
        let tv = makeTextView("###### Title")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        MarkdownEditorMenuActions.toggleHeading(in: tv)
        XCTAssertEqual(tv.string, "## Title")
    }

    /// `#tag` is not a heading, so toggling prefixes it rather than stripping.
    func test_toggleHeading_aHashTagLineGetsPrefixedNotStripped() throws {
        let tv = makeTextView("#tag")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        MarkdownEditorMenuActions.toggleHeading(in: tv)
        XCTAssertEqual(tv.string, "## #tag")
    }
}
