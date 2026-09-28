import XCTest
@testable import LoreFeature

/// Line-level formatting: lists, checkboxes, quotes and headings.
///
/// Every case here is one a running app makes awkward to reach by hand — an
/// empty line, a ragged multi-line selection, a line already carrying the
/// marker — and each is one line to state as a test.
final class MarkdownLineFormattingTests: XCTestCase {

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: - Line prefixes

    func test_addsAPrefixToTheCaretsLine() {
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: "one\ntwo", selection: caret(0), prefix: "- ")
        XCTAssertEqual(result.text, "- one\ntwo")
    }

    /// Pressing the same key again takes it off.
    func test_removesThePrefixWhenItIsAlreadyThere() {
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: "- one\ntwo", selection: caret(2), prefix: "- ")
        XCTAssertEqual(result.text, "one\ntwo")
    }

    /// A RAGGED selection becomes uniformly prefixed rather than inverted
    /// line-by-line. Toggling each line independently would leave the block
    /// exactly as ragged as it started, which is never what someone selecting
    /// a block and pressing the list key wants.
    func test_amixedSelectionBecomesUniformlyPrefixed() {
        let text = "- one\ntwo\n- three"
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: text, selection: NSRange(location: 0, length: (text as NSString).length),
            prefix: "- ")
        XCTAssertEqual(result.text, "- one\n- two\n- three",
                       "an already-prefixed line must not be double-prefixed either")
    }

    /// Only when EVERY line has it does the toggle remove.
    func test_afullyPrefixedSelectionIsCleared() {
        let text = "- one\n- two"
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: text, selection: NSRange(location: 0, length: (text as NSString).length),
            prefix: "- ")
        XCTAssertEqual(result.text, "one\ntwo")
    }

    /// A blank line inside a selection stays blank — a bullet on an empty line
    /// is a bullet with nothing after it.
    func test_blankLinesAreLeftAlone() {
        let text = "one\n\ntwo"
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: text, selection: NSRange(location: 0, length: (text as NSString).length),
            prefix: "- ")
        XCTAssertEqual(result.text, "- one\n\n- two")
    }

    /// The trailing newline of a selected block is not a line. Prefixing it
    /// would drop a stray marker onto the line AFTER the selection.
    func test_atrailingNewlineDoesNotGainAMarker() {
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: "one\ntwo", selection: NSRange(location: 0, length: 4), prefix: "- ")
        XCTAssertEqual(result.text, "- one\ntwo")
    }

    func test_checkboxesUseTheirOwnPrefix() {
        let result = MarkdownLineFormatting.toggleLinePrefix(
            text: "buy milk", selection: caret(0), prefix: "- [ ] ")
        XCTAssertEqual(result.text, "- [ ] buy milk")
    }

    // MARK: - Headings

    func test_setsAHeadingLevel() {
        let result = MarkdownLineFormatting.setHeading(text: "Title", selection: caret(0),
                                                       level: 2)
        XCTAssertEqual(result.text, "## Title")
    }

    /// Existing markers are REPLACED, never appended to — otherwise ⌘2 on an
    /// h1 produces `# ## Title`.
    func test_changingLevelReplacesTheExistingMarker() {
        let result = MarkdownLineFormatting.setHeading(text: "# Title", selection: caret(0),
                                                       level: 3)
        XCTAssertEqual(result.text, "### Title")
    }

    /// The same key twice returns the line to body text, which is what every
    /// editor with heading shortcuts does.
    func test_settingTheLevelItAlreadyHasTogglesItOff() {
        let result = MarkdownLineFormatting.setHeading(text: "## Title", selection: caret(0),
                                                       level: 2)
        XCTAssertEqual(result.text, "Title")
    }

    func test_levelZeroClearsAHeading() {
        let result = MarkdownLineFormatting.setHeading(text: "#### Deep", selection: caret(0),
                                                       level: 0)
        XCTAssertEqual(result.text, "Deep")
    }

    func test_headingLevelIsClamped() {
        let result = MarkdownLineFormatting.setHeading(text: "Title", selection: caret(0),
                                                       level: 99)
        XCTAssertEqual(result.text, "###### Title")
    }

    // MARK: - Heading detection

    /// `#hashtag` is NOT a heading: ATX requires a space after the run. Without
    /// this, a tag at the start of a line reads as an h1 and ⌘1 "toggles" it
    /// into nonsense — and a notes vault is full of leading tags.
    func test_ahashtagIsNotAHeading() {
        XCTAssertEqual(MarkdownLineFormatting.headingLevel(of: "#project note"), 0)
        XCTAssertEqual(MarkdownLineFormatting.headingLevel(of: "# real heading"), 1)
    }

    func test_sevenHashesIsNotAHeading() {
        XCTAssertEqual(MarkdownLineFormatting.headingLevel(of: "####### too deep"), 0)
    }

    func test_abareHashRunIsAHeadingWithNoText() {
        XCTAssertEqual(MarkdownLineFormatting.headingLevel(of: "##"), 2)
    }

    func test_strippingLeavesBodyTextUntouched() {
        XCTAssertEqual(MarkdownLineFormatting.strippingHeading("plain"), "plain")
        XCTAssertEqual(MarkdownLineFormatting.strippingHeading("### spaced"), "spaced")
    }
}
