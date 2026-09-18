import XCTest
import PDFKit
@testable import LoreFeature
import AinkradAppKit

/// The automated half of Task 11 (M3 acceptance). Covers criteria 1, 2, 3 and
/// 7 — the ones testable without a GUI host. Criteria 4, 5, 6 and 8 need a
/// running Dev Host and a human eye; see `task-11-report.md`.
@MainActor
final class M3AcceptanceTests: XCTestCase {
    /// Every temp vault this test creates, so `tearDown` can remove them.
    /// Without this, each run leaked its four fixture vaults into
    /// `/var/folders` — harmless individually, but unbounded over many runs.
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lore-m3-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        createdDirs.append(u)
        return u
    }

    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    /// A one-page PDF containing `text`, built with Core Graphics — same
    /// approach as `PDFEngineTests.makePDF`, so the test owns no binary fixture.
    private func makePDF(_ text: String, at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("could not create a PDF context")
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func makeRTF(_ text: String, at url: URL) throws {
        let attributed = NSAttributedString(string: text)
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtf.write(to: url)
    }

    /// A one-pixel, valid PNG — same helper as `EmbedRenderingTests.onePixelPNG`.
    private func onePixelPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("failed to synthesize a test PNG")
            return Data()
        }
        return png
    }

    /// Builds the acceptance vault: a note linking to the PDF, plus the PDF,
    /// RTF, PNG and XLSX fixtures. Returns the store, already rebuilt.
    ///
    /// `sheet.xlsx` is plain text wearing an `.xlsx` name, not a real
    /// spreadsheet — building an actual `.xlsx` (a zipped OOXML package) is
    /// out of scope for a fixture helper. It proves `EngineRegistry` has SOME
    /// fallback engine for an extension no dedicated engine claims (criterion
    /// 1's "no dead ends"), not that a real spreadsheet's content is parsed.
    private func makeAcceptanceVault() async throws -> (root: URL, store: LoreStore) {
        let root = tempDir()
        let store = try makeStore(root)
        await store.settleForTesting()

        try "---\nid: note\ntitle: Note\n---\nSee the [[Contract.pdf]] for terms."
            .write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try makePDF("This PDF mentions xylophone-quartz uniquely.",
                    at: root.appendingPathComponent("Contract.pdf"))
        try makeRTF("This RTF mentions marmoset-cobalt uniquely.",
                    at: root.appendingPathComponent("report.rtf"))
        try onePixelPNG().write(to: root.appendingPathComponent("diagram.png"))
        try "sheet data".write(
            to: root.appendingPathComponent("sheet.xlsx"), atomically: true, encoding: .utf8)

        try store.rebuild()
        return (root, store)
    }

    // MARK: - Criterion 1: every file has an index row and a non-nil engine (no dead ends)

    func test_criterion1_everyFixtureFileHasAnIndexRowAndAResolvingEngine() async throws {
        let (root, store) = try await makeAcceptanceVault()
        let expectedNames = ["note.md", "Contract.pdf", "report.rtf", "diagram.png", "sheet.xlsx"]

        XCTAssertEqual(Set(store.rows.map(\.path.lastPathComponent)), Set(expectedNames),
                       "every fixture must have an index row")

        for name in expectedNames {
            let url = root.appendingPathComponent(name)
            let engine = try? EngineRegistry.load(url)
            XCTAssertNotNil(engine, "\(name) must resolve to a non-nil engine")
        }
    }

    // MARK: - Criterion 2: FTS finds text unique to a PDF, and unique to an RTF

    func test_criterion2_searchFindsAPhraseThatExistsOnlyInsideThePDF() async throws {
        let (_, store) = try await makeAcceptanceVault()
        let hits = store.search("xylophone-quartz")
        XCTAssertEqual(hits.map(\.path.lastPathComponent), ["Contract.pdf"])
    }

    func test_criterion2_searchFindsAPhraseThatExistsOnlyInsideTheRTF() async throws {
        let (_, store) = try await makeAcceptanceVault()
        let hits = store.search("marmoset-cobalt")
        XCTAssertEqual(hits.map(\.path.lastPathComponent), ["report.rtf"])
    }

    // MARK: - Criterion 3: [[Contract.pdf]] resolves and backlinks list the referring note

    func test_criterion3_wikilinkToThePDFResolvesAndBacklinksListTheReferringNote() async throws {
        let (root, store) = try await makeAcceptanceVault()
        let pdfURL = root.appendingPathComponent("Contract.pdf")

        XCTAssertTrue(store.openLink("Contract.pdf"), "[[Contract.pdf]] must resolve")
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "Contract.pdf")

        let backlinks = store.backlinks(to: pdfURL)
        XCTAssertEqual(backlinks.map(\.row.title), ["Note"],
                       "the PDF's backlinks must list the referring note")
    }

    // MARK: - Criterion 7: renaming an attachment rewrites the referring link

    func test_criterion7_renamingThePDFRewritesTheLinkInTheReferringNote() async throws {
        let (root, store) = try await makeAcceptanceVault()
        let pdfURL = root.appendingPathComponent("Contract.pdf")

        let plan = store.plan(rename: pdfURL, to: "Agreement")
        XCTAssertNil(plan.refusal)
        let report = store.apply(plan)
        XCTAssertTrue(report.failed.isEmpty, "rename must not fail: \(report.failed)")

        let noteText = try String(
            contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertTrue(noteText.contains("[[Agreement.pdf]]"),
                     "the referring note must be rewritten to point at the new name")
        XCTAssertFalse(noteText.contains("[[Contract.pdf]]"),
                       "the old link text must not remain")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Agreement.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))
    }
}
