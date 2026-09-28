import XCTest
@testable import LoreFeature

final class DocumentVisibilityTests: XCTestCase {
    private func row(_ path: String, type: String) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: path), id: path, title: path, tags: [],
                 aliases: [], updated: Date(), type: type, properties: [])
    }

    /// Derives the engine identity the same way PRODUCTION does — through
    /// `EngineRegistry.engine(for:)` — rather than hand-picking a `type`
    /// string. Fix round 1's Critical 2: the previous version of this file
    /// hand-constructed `IndexRow(type: AttachmentEngine.identifier, ext:
    /// "json")`, a row shape `EngineRegistry` can never actually produce
    /// (`.json` always resolves to `PlainTextEngine`), so the test asserted
    /// the OPPOSITE of real behaviour while appearing to pin it — exactly
    /// what let Critical 1 (the credentials file staying visible) ship. Every
    /// test below that cares about a specific extension goes through this
    /// helper instead.
    private func isHidden(_ filename: String) -> Bool {
        let url = URL(fileURLWithPath: "/vault/\(filename)")
        let type = EngineRegistry.engine(for: url).identifier
        return DocumentVisibility.isHiddenByDefault(type: type, pathExtension: url.pathExtension)
    }

    func test_imageIsShown() {
        XCTAssertFalse(isHidden("photo.png"))
        XCTAssertFalse(isHidden("photo.PNG"))
    }

    func test_pdfIsShown() {
        XCTAssertFalse(isHidden("report.pdf"))
    }

    func test_markdownIsShown() {
        XCTAssertFalse(isHidden("note.md"))
    }

    func test_plainProseTextIsShown() {
        XCTAssertFalse(isHidden("notes.txt"))
        XCTAssertFalse(isHidden("notes.text"))
    }

    func test_richTextAndOfficeDocumentsAreShown() {
        for name in ["contract.docx", "letter.rtf", "page.html", "spreadsheet.xlsx",
                     "deck.pptx", "doc.pages", "slides.key", "sheet.numbers"] {
            XCTAssertFalse(isHidden(name), name)
        }
    }

    func test_zipIsHidden() {
        XCTAssertTrue(isHidden("archive.zip"))
    }

    /// The exact file the owner named: a Google OAuth credentials JSON file.
    /// This is the regression Critical 1 caught — `.json` resolves to
    /// `PlainTextEngine`, not `AttachmentEngine`, so an engine-identity-only
    /// predicate never hid it.
    func test_credentialsJSONIsHidden() {
        XCTAssertTrue(isHidden("client_secret_123.apps.googleusercontent.com.json"))
    }

    func test_developerTextExtensionsAreHidden() {
        for ext in ["json", "yaml", "yml", "toml", "log", "csv", "sh",
                    "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp"] {
            XCTAssertTrue(isHidden("file.\(ext)"), ext)
        }
    }

    func test_nonDocumentAttachmentsAreHidden() {
        for ext in ["zip", "bin", "exe", "dmg"] {
            XCTAssertTrue(isHidden("file.\(ext)"), ext)
        }
    }

    /// Pins the relationship `nonProseTextExtensions`' doc comment claims:
    /// every curated "not prose" extension really is one `PlainTextEngine`
    /// claims. If `PlainTextEngine.extensions` ever drops one of these, this
    /// fails loudly instead of `DocumentVisibility` silently keeping a
    /// now-nonexistent case alive.
    func test_nonProseTextExtensions_isASubsetOfPlainTextEngineExtensions() {
        XCTAssertTrue(DocumentVisibility.nonProseTextExtensions.isSubset(of: PlainTextEngine.extensions))
    }

    func test_visibleRows_hidesJunkByDefault() {
        let rows = [
            row("/v/note.md", type: MarkdownEngine.identifier),
            row("/v/photo.png", type: AttachmentEngine.identifier),
            row("/v/secret.json", type: PlainTextEngine.identifier),
            row("/v/archive.zip", type: AttachmentEngine.identifier),
        ]
        let visible = DocumentVisibility.visibleRows(rows, showAllFiles: false)
        XCTAssertEqual(Set(visible.map(\.id)), ["/v/note.md", "/v/photo.png"])
    }

    func test_visibleRows_showAllFilesRevealsEverythingWithoutFiltering() {
        let rows = [
            row("/v/note.md", type: MarkdownEngine.identifier),
            row("/v/archive.zip", type: AttachmentEngine.identifier),
        ]
        let visible = DocumentVisibility.visibleRows(rows, showAllFiles: true)
        XCTAssertEqual(visible.count, rows.count)
    }

    // MARK: - The setting flips the predicate

    func test_settingFlips_hiddenAttachmentBecomesVisible() {
        let rows = [row("/v/archive.zip", type: AttachmentEngine.identifier)]
        XCTAssertTrue(DocumentVisibility.visibleRows(rows, showAllFiles: false).isEmpty)
        XCTAssertEqual(DocumentVisibility.visibleRows(rows, showAllFiles: true).count, 1)
    }

    // MARK: - The invariant most likely to be broken: link resolution

    /// A REAL vault, a REAL `LoreStore`, a hidden `.zip` linked from markdown
    /// — exercising the actual resolver (`LoreStore.resolveLink` /
    /// `openLink`), not a hand-built array. Fix round 1's Important 3: the
    /// previous version of this test built `let allRows = [hidden]` and
    /// asserted `allRows.contains(hidden)` — a fact about `Array`, true even
    /// if `store.rows` itself had been filtered at the source, so it could
    /// never have caught that bug. This one actually would: if a future
    /// change filtered `LoreStore.rows`/`resolveLink` instead of only the two
    /// sidebar views, `openLink` below would return `false` and this fails.
    @MainActor
    func test_hiddenAttachment_stillResolvesAndOpensAsALinkTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-visibility-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("PK\u{03}\u{04}fake zip bytes".utf8)
            .write(to: root.appendingPathComponent("archive.zip"))
        try "---\nid: a\ntitle: Alpha\n---\nsee [[archive.zip]]"
            .write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)

        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        await store.settleForTesting()
        try store.rebuild()

        // Precondition: the row this test cares about is actually hidden by
        // default, or the assertions below would pass for the wrong reason.
        let zipRow = try XCTUnwrap(store.rows.first { $0.path.lastPathComponent == "archive.zip" })
        XCTAssertTrue(DocumentVisibility.isHiddenByDefault(zipRow))
        XCTAssertFalse(DocumentVisibility.visibleRows(store.rows, showAllFiles: false)
            .contains { $0.path == zipRow.path })

        // The invariant: hidden from the browse list, but still a resolvable,
        // openable link target through the UNFILTERED path `LoreStore` itself
        // uses.
        XCTAssertEqual(store.resolveLink("archive.zip")?.lastPathComponent, "archive.zip")
        XCTAssertTrue(store.openLink("archive.zip"))
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "archive.zip")
    }
}
