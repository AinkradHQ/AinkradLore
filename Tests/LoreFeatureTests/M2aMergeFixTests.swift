import AppKit
import GRDB
import XCTest

@testable import LoreFeature

/// Covering tests for the M2a whole-branch merge review. Each one pins a
/// finding's fix rather than the code that happens to implement it.
final class M2aSchemaVersionTests: XCTestCase {

    /// Link EXTRACTION changed this milestone — two accepted ADDs and four
    /// accepted Group D regressions — so a persisted graph built by M1 answers
    /// a different question than the code does, and `LinkRewriter` reads that
    /// graph when renaming. The version bump is the discard-and-rebuild the
    /// constant exists for.
    func test_theSchemaVersionWasBumpedForTheNewLinkExtractor() {
        XCTAssertGreaterThanOrEqual(
            LoreIndex.schemaVersion, 6,
            "M2a changed link extraction; a version-5 index holds an M1 graph")
    }

    /// The bump is only worth anything if a version-5 file is actually thrown
    /// away. Written as version FIVE specifically — the one an owner upgrading
    /// into this branch will have on disk.
    func test_aVersionFiveIndexIsDiscardedNotRead() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let legacy = try DatabaseQueue(path: path.path)
        try legacy.write { db in
            try db.execute(sql: "PRAGMA user_version = 5;")
            try db.execute(sql: "CREATE TABLE documents(path TEXT PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO documents(path) VALUES('/v/m1-graph.md');")
        }
        try legacy.close()
        XCTAssertTrue(try LoreIndex(path: path).all().isEmpty)
    }
}

/// Finding 2: `indexPayload` parsed the document TWICE — once for the outline
/// and once inside `LinkParser.links(in:)`, which built its own model to answer
/// "inside code?" — and the save path then computed `indexPayload` twice more.
final class M2aIndexPayloadParseCountTests: XCTestCase {

    private let body = "# H\n\nSome **bold** with [[A]] and `code`.\n\n```\n[[NotALink]]\n```\n"

    private func engine() throws -> MarkdownEngine {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-\(UUID()).md")
        try "---\nid: a\ntitle: T\n---\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        return try MarkdownEngine.load(url)
    }

    func test_indexPayloadCostsExactlyOneParse() throws {
        let engine = try engine()
        resetParseCounter()
        _ = engine.indexPayload
        XCTAssertEqual(
            MarkdownParseCounter.count, 1,
            "the outline and the link scan must share one parse")
    }

    /// The saved parse must not have cost an answer. Both halves are compared
    /// against the un-injected path they replaced.
    func test_theSharedParseAnswersIdenticallyToTwoSeparateOnes() throws {
        let payload = try engine().indexPayload
        XCTAssertEqual(payload.links.map(\.rawTarget), LinkParser.links(in: body).map(\.rawTarget))
        XCTAssertEqual(payload.outline, MarkdownDocumentModel(body: body).outline)
        XCTAssertEqual(
            payload.links.map(\.rawTarget), ["A"],
            "the fenced [[NotALink]] is still suppressed")
    }

    /// A CRLF body deliberately still parses twice: the model withholds its
    /// suppression index because `LinkParser` normalises before scanning, and
    /// pre-normalisation UTF-16 offsets would misplace suppression. Pinned so
    /// nobody "optimises" the guard away for the sake of this test's sibling.
    func test_aCRLFBodyKeepsTheSecondParseAndTheRightAnswer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crlf-\(UUID()).md")
        try "---\r\nid: a\r\n---\r\n[[A]]\r\n\r\n```\r\n[[NotALink]]\r\n```\r\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.links.map(\.rawTarget), ["A"])
    }

    /// `indexTitle` is the whole point of finding 2's second half: four call
    /// sites in `DocumentSession` wanted a `String` and were paying for a parse
    /// plus a link scan to get one.
    func test_indexTitleCostsNoParseAndAgreesWithThePayload() throws {
        let engine = try engine()
        resetParseCounter()
        let title = engine.indexTitle
        XCTAssertEqual(MarkdownParseCounter.count, 0)
        XCTAssertEqual(title, engine.indexPayload.title)
    }
}

@MainActor
final class M2aSavePathParseCountTests: XCTestCase {

    /// THE regression this branch introduced. `saveNow()` refreshed
    /// `cachedTitle` from `indexPayload` (2 parses) and then indexed the
    /// document, reading `indexPayload` again (2 more) — four full AST parses
    /// on the main actor, 500 ms after the user stops typing. It is now one.
    func test_saveNowCostsExactlyOneParse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = VaultIndexCoordinator(
            indexPath: root.appendingPathComponent(".idx.sqlite"))
        try coordinator.activate(root: root)

        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: T\n---\n# H\n\n[[A]] and **bold**\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let session = try DocumentSession.open(url: url, coordinator: coordinator)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body += "more text\n"

        resetParseCounter()
        try session.saveNow()
        XCTAssertEqual(
            MarkdownParseCounter.count, 1,
            "one save, one parse — it used to be four")
        XCTAssertEqual(session.title, "T")
    }

    /// Opening a session must not parse either: the constructor cached the
    /// title through `indexPayload`.
    func test_openingASessionCostsNoParse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-open-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = VaultIndexCoordinator(
            indexPath: root.appendingPathComponent(".idx.sqlite"))
        try coordinator.activate(root: root)
        let url = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: T\n---\n# H\n".write(to: url, atomically: true, encoding: .utf8)

        resetParseCounter()
        let session = try DocumentSession.open(url: url, coordinator: coordinator)
        XCTAssertEqual(MarkdownParseCounter.count, 0)
        XCTAssertEqual(session.title, "T")
    }
}

/// Finding 4: child spans are appended AFTER their parent and `apply` walks the
/// array in order, so a child's `.font` REPLACED its parent's instead of
/// composing with it. Asserted on the resulting attributes, never by eye.
@MainActor
final class M2aFontCompositionTests: XCTestCase {

    private static let theme = MarkdownTheme(tokens: TestTokens.make())

    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownStyleRenderer.apply(
            MarkdownStyleCache.derive(text).spans,
            to: storage, tokens: TestTokens.make(),
            theme: Self.theme, limitedTo: nil)
        return storage
    }

    private func font(_ storage: NSTextStorage, at index: Int) -> NSFont {
        storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont
    }

    private func traits(_ font: NSFont) -> NSFontTraitMask {
        NSFontManager.shared.traits(of: font)
    }

    /// `# A **B** C` — the bold run must stay at the HEADING's size.
    func test_boldInsideAHeadingKeepsTheHeadingSize() {
        let text = "# A **B** C\n"
        let storage = styled(text)
        let headingSize = font(storage, at: 2).pointSize  // the "A"
        let boldSize = font(storage, at: 7).pointSize  // the "B"
        XCTAssertEqual(
            headingSize, Self.theme.headingSize(1), accuracy: 0.01,
            "level-1 heading size now comes from MarkdownTheme")
        XCTAssertEqual(
            boldSize, headingSize,
            "the child span overwrote the heading's font")
        XCTAssertTrue(traits(font(storage, at: 7)).contains(.boldFontMask))
    }

    /// `**bold _and_ italic**` — the inner run must be bold AND italic.
    func test_emphasisInsideStrongIsBothBoldAndItalic() {
        let text = "**bold _and_ italic**\n"
        let storage = styled(text)
        let inner = font(storage, at: 9)  // inside "and"
        XCTAssertTrue(traits(inner).contains(.italicFontMask))
        XCTAssertTrue(
            traits(inner).contains(.boldFontMask),
            "emphasis replaced the surrounding strong instead of adding to it")
        XCTAssertTrue(
            traits(font(storage, at: 3)).contains(.boldFontMask),
            "and the outer run is still bold")
    }

    /// Inline code in a heading must be monospaced AT THE HEADING'S SIZE, not
    /// dropped to the base size.
    func test_inlineCodeInsideAHeadingKeepsTheHeadingSize() {
        let text = "# A `code` C\n"
        let storage = styled(text)
        let headingSize = font(storage, at: 2).pointSize
        let code = font(storage, at: 6)  // inside "code"
        XCTAssertEqual(headingSize, Self.theme.headingSize(1), accuracy: 0.01)
        // Scaled to the HEADING, not snapped back to body-code size — the
        // point M2a fixed. The mono ratio applies either way, so the code in a
        // 27 pt heading is 27 × 0.92 rather than 27 exactly.
        XCTAssertEqual(
            code.pointSize, headingSize * MarkdownTheme.monoRatio,
            accuracy: 0.01)
        XCTAssertTrue(code.isFixedPitch, "inline code must still be monospaced")
    }

    /// Top-level runs take the THEME's font, and composition adds traits to it
    /// rather than replacing it.
    ///
    /// This test used to assert the opposite of two of these things —
    /// `font(storage, at: 0).isFixedPitch` and `pointSize ==
    /// MarkdownStyleRenderer.baseSize` — and it passed, because both were
    /// true: the editor set every paragraph of prose in a monospaced 14 pt
    /// constant. That is the M9.1 defect, written down as an assertion, which
    /// is why this is REWRITTEN rather than relaxed. Body text is now
    /// proportional and sized by `EditorSettings`, and the old assertions
    /// would have to be deleted to make that possible — so they are replaced
    /// by the ones that say what should have been true all along.
    func test_topLevelRunsUseTheThemeFontAndComposeTraits() {
        let storage = styled("plain **b** _i_ `c`\n")
        let body = font(storage, at: 0)

        XCTAssertEqual(body.pointSize, Self.theme.bodyFont.pointSize, accuracy: 0.01)
        XCTAssertFalse(body.isFixedPitch, "prose is set in a PROPORTIONAL face")

        // Bold and italic COMPOSE onto the body face: same family, extra
        // trait. Re-basing onto a fresh `.systemFont` kept the size and lost
        // the family, which is what made a bold run inside monospaced text
        // change typeface mid-sentence.
        let bold = font(storage, at: 8)
        let italic = font(storage, at: 13)
        XCTAssertTrue(traits(bold).contains(.boldFontMask))
        XCTAssertTrue(traits(italic).contains(.italicFontMask))
        XCTAssertEqual(
            bold.familyName, body.familyName,
            "bold must be the body FAMILY with a trait added")
        XCTAssertEqual(italic.familyName, body.familyName)

        // Inline code is the one run that changes family, which is now the
        // whole of what marks it as code — and it is set below the body size,
        // since a monospaced face reads larger at equal points.
        let code = font(storage, at: 17)
        XCTAssertTrue(code.isFixedPitch, "inline code is monospaced")
        XCTAssertEqual(code.pointSize, Self.theme.monoFont.pointSize, accuracy: 0.01)
        XCTAssertLessThan(code.pointSize, body.pointSize)
    }
}

/// Finding 6: the bracket guard accepted `[x](url)`, so a stale `.checkbox`
/// span landing exactly there flipped a markdown link's display text.
final class M2aCheckboxBracketGuardTests: XCTestCase {

    func test_aMarkdownLinkIsNotAToggleableCheckbox() {
        let text = "[x](url) and more\n" as NSString
        XCTAssertNil(
            TaskCheckbox.markerRange(forBracketSpan: 0..<3, in: text),
            "`(` after `]` is not a task item; toggling would rewrite the link text")
    }

    /// The guard must still admit every real shape: a space follows the `]` in
    /// GFM, and the document may simply end there.
    func test_realCheckboxesStillPass() {
        XCTAssertNotNil(
            TaskCheckbox.markerRange(
                forBracketSpan: 2..<5,
                in: "- [ ] a\n" as NSString))
        XCTAssertNotNil(
            TaskCheckbox.markerRange(
                forBracketSpan: 2..<5,
                in: "- [x]" as NSString))
        XCTAssertNotNil(
            TaskCheckbox.markerRange(
                forBracketSpan: 2..<5,
                in: "- [x]\n" as NSString))
    }
}
