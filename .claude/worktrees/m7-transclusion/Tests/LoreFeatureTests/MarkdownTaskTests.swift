import XCTest
@testable import LoreFeature

final class MarkdownTaskTests: XCTestCase {

    /// The production locator, called exactly as `MarkdownEditor.toggleTask`
    /// calls it: the style spans the editor caches, validated against a string.
    private func items(_ model: MarkdownDocumentModel) -> [TaskItem] {
        TaskCheckbox.items(in: model.styleSpans, text: model.fullText as NSString)
    }

    /// The toggle, with the same split the editor has: `TaskCheckbox` decides
    /// WHETHER and WHAT (that is the guard under test), and the caller splices.
    /// The editor splices via `NSTextStorage.replaceCharacters` so the edit
    /// rides its undo and autosave path; here a plain string splice stands in.
    private func toggle(_ item: TaskItem, in text: String) -> String {
        let ns = text as NSString
        guard let (range, string) = TaskCheckbox.replacement(for: item, in: ns) else {
            return text
        }
        return ns.replacingCharacters(in: range, with: string)
    }

    func test_findsCheckedAndUncheckedItems() {
        let items = items(MarkdownDocumentModel(fullText: "- [ ] a\n- [x] b\n"))
        XCTAssertEqual(items.map(\.isChecked), [false, true])
    }

    func test_markerRangeCoversExactlyOneCharacter() {
        let text = "- [ ] a\n"
        let item = items(MarkdownDocumentModel(fullText: text))[0]
        XCTAssertEqual(item.markerRangeUTF16.length, 1)
        XCTAssertEqual((text as NSString).substring(with: item.markerRangeUTF16), " ")
    }

    func test_togglingChangesExactlyOneCharacter() {
        let text = "- [ ] a\n- [x] b\n"
        let model = MarkdownDocumentModel(fullText: text)
        let toggled = toggle(items(model)[0], in: text)
        XCTAssertEqual(toggled, "- [x] a\n- [x] b\n")
        XCTAssertEqual(toggled.count, text.count)
    }

    func test_togglingBackRestoresTheOriginal() {
        let text = "- [x] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(toggle(items(model)[0], in: text), "- [ ] a\n")
    }

    func test_ignoresCheckboxLookalikesInsideAFence() {
        let items = items(MarkdownDocumentModel(fullText: "```\n- [ ] not a task\n```\n"))
        XCTAssertTrue(items.isEmpty)
    }

    func test_worksWithFrontmatterPresent() {
        let text = "---\nid: a\n---\n- [ ] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(toggle(items(model)[0], in: text), "---\nid: a\n---\n- [x] a\n")
    }

    // MARK: - The offset guard

    /// The editor's spans lag the live text by up to one debounce, so a
    /// `TaskItem` may point at a character that is no longer a marker. Toggling
    /// it then would edit an arbitrary character of the user's note.
    func test_toggleIsRefusedWhenTheOffsetNoLongerHoldsAMarker() {
        let text = "- [ ] a\n"
        let item = items(MarkdownDocumentModel(fullText: text))[0]
        // The user typed at the head of the line; the cached offset now points
        // into prose.
        let moved = "XXXX- [ ] a\n"
        XCTAssertEqual(toggle(item, in: moved), moved)
        // Offset 3 now holds a literal `X` — a legal marker CHARACTER, sitting
        // in prose. Only the surrounding brackets tell the two apart.
        XCTAssertEqual((moved as NSString).substring(with: item.markerRangeUTF16), "X")
    }

    func test_toggleIsRefusedWhenTheOffsetIsPastTheEndOfTheText() {
        let text = "- [ ] a\n"
        let item = items(MarkdownDocumentModel(fullText: text))[0]
        XCTAssertEqual(toggle(item, in: "-"), "-")
    }

    func test_upperCaseXTogglesOff() {
        let text = "- [X] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(items(model).map(\.isChecked), [true])
        XCTAssertEqual(toggle(items(model)[0], in: text), "- [ ] a\n")
    }

    /// A malformed item — a list item with no checkbox at all — styles as a
    /// list item and offers no toggle.
    func test_malformedItemOffersNoToggle() {
        XCTAssertTrue(items(MarkdownDocumentModel(fullText: "- [] a\n")).isEmpty)
        XCTAssertTrue(items(MarkdownDocumentModel(fullText: "- a\n")).isEmpty)
        XCTAssertTrue(items(MarkdownDocumentModel(fullText: "- [y] a\n")).isEmpty)
    }

    /// Offsets are UTF-16, and the editor indexes UTF-16. An emoji before the
    /// item must not shift the marker.
    func test_offsetsAreUTF16AndSurviveAnEmoji() {
        let text = "🎉\n\n- [ ] a\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(toggle(items(model)[0], in: text), "🎉\n\n- [x] a\n")
    }

    /// Multi-line task items: the marker is on the item's FIRST line, and a
    /// later `[ ]` in the item's prose is not it.
    func test_markerIsTheEarliestSpellingOnTheFirstLine() {
        let text = "- [x] see [ ] later\n"
        let model = MarkdownDocumentModel(fullText: text)
        XCTAssertEqual(items(model).count, 1)
        XCTAssertEqual(toggle(items(model)[0], in: text), "- [ ] see [ ] later\n")
    }

    /// The locator is derived from the SAME `.checkbox` style spans the editor
    /// renders — one parse, one source of truth, no parallel scanner.
    func test_taskItemsAgreeWithTheCheckboxStyleSpans() {
        let model = MarkdownDocumentModel(fullText: "- [ ] a\n- [x] b\n")
        let checkboxSpans = model.astStyleSpans.filter {
            if case .checkbox = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(checkboxSpans.count, items(model).count)
        for (span, item) in zip(checkboxSpans, items(model)) {
            XCTAssertEqual(item.markerRangeUTF16.location, span.range.lowerBound + 1)
        }
    }
}

/// The toggle must reach disk the way a keystroke does: mutate the engine's
/// body, `markChanged()`, and let the session's debounced autosave write it.
@MainActor
final class MarkdownTaskSessionTests: XCTestCase {

    private func vault() throws -> (URL, VaultIndexCoordinator) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-task-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = VaultIndexCoordinator(indexPath: root.appendingPathComponent(".idx.sqlite"))
        try c.activate(root: root)
        return (root, c)
    }

    func test_toggleThroughTheEditPathAutosaves() async throws {
        let (root, c) = try vault()
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: T\n---\n- [ ] a\n".write(to: url, atomically: true, encoding: .utf8)

        let session = try DocumentSession.open(url: url, coordinator: c)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)

        // Exactly what the editor does: the model is built from the BODY (what
        // the editor binds to), the one marker character is replaced, and the
        // result is assigned back through the ordinary text path.
        let body = engine.note.body
        let model = MarkdownDocumentModel(body: body)
        let ns = body as NSString
        let item = try XCTUnwrap(TaskCheckbox.items(in: model.styleSpans, text: ns).first)
        let edit = try XCTUnwrap(TaskCheckbox.replacement(for: item, in: ns))
        engine.note.body = ns.replacingCharacters(in: edit.range, with: edit.string)
        session.markChanged()

        XCTAssertTrue(session.isDirty)
        // Well past the 500 ms autosave debounce.
        try await Task.sleep(for: .milliseconds(1200))

        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("- [x] a"))
    }

    /// A read-only session never toggles: `markChanged()` is a no-op for it, so
    /// offering the affordance would be a promise the session cannot keep.
    /// `MarkdownEditor` refuses the click up front — see `allowsTaskToggle`.
    func test_readOnlySessionStaysCleanAndUnwritten() async throws {
        let (root, c) = try vault()
        let url = root.appendingPathComponent("a.txt")
        try Data([0x2D, 0x20, 0x5B, 0x20, 0x5D, 0x20, 0x61, 0xFF, 0xFE]).write(to: url)

        let session = try DocumentSession.open(url: url, coordinator: c)
        XCTAssertTrue(session.isReadOnly)
        session.markChanged()
        XCTAssertFalse(session.isDirty)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try Data(contentsOf: url).count, 9)
    }
}
