import XCTest
import PDFKit
@testable import LoreFeature

final class PDFEngineTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A one-page PDF containing `text`, built with Core Graphics so the test
    /// owns no binary fixture.
    private func makePDF(_ text: String, named name: String = "doc.pdf") throws -> URL {
        let url = try tempDir().appendingPathComponent(name)
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
        return url
    }

    func test_claimsPDFOnly() throws {
        XCTAssertTrue(PDFEngine.canOpen(URL(fileURLWithPath: "/x/a.pdf")))
        XCTAssertTrue(PDFEngine.canOpen(URL(fileURLWithPath: "/x/a.PDF")))
        XCTAssertFalse(PDFEngine.canOpen(URL(fileURLWithPath: "/x/a.md")))
    }

    func test_extractsTextIntoTheIndexPayload() throws {
        let url = try makePDF("Ainkrad quarterly report")
        let engine = try PDFEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.contains("Ainkrad"))
        XCTAssertFalse(engine.isEditable)
    }

    func test_titleFallsBackToFilename() throws {
        let url = try makePDF("body text", named: "Contract.pdf")
        let engine = try PDFEngine.load(url)
        XCTAssertEqual(engine.indexTitle, "Contract")
    }

    func test_corruptPDF_loadsWithAFailureMessageAndNoText() throws {
        let url = try tempDir().appendingPathComponent("broken.pdf")
        try Data("not a pdf at all".utf8).write(to: url)
        let engine = try PDFEngine.load(url)
        XCTAssertNotNil(engine.loadFailure)
        XCTAssertEqual(engine.indexPayload.plaintext, "")
        XCTAssertEqual(engine.indexTitle, "broken")
    }

    func test_save_throwsReadOnly() throws {
        let url = try makePDF("x")
        let engine = try PDFEngine.load(url)
        XCTAssertThrowsError(try engine.save(to: url)) { error in
            XCTAssertEqual(error as? EngineError, .readOnly(url))
        }
    }
}
