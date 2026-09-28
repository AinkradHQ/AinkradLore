import XCTest
@testable import LoreFeature

final class ImportItemTests: XCTestCase {
    func testItemCarriesStableSourceIDAndBody() {
        let item = ImportItem(sourceID: "apple-notes:ABC-123",
                              title: "Groceries",
                              body: .html("<p>milk</p>"),
                              attachments: [],
                              folderPath: ["Shopping"],
                              created: Date(timeIntervalSince1970: 0),
                              modified: Date(timeIntervalSince1970: 100),
                              fidelity: [])
        XCTAssertEqual(item.sourceID, "apple-notes:ABC-123")
        XCTAssertEqual(item.folderPath, ["Shopping"])
        guard case .html(let raw) = item.body else { return XCTFail("expected html body") }
        XCTAssertEqual(raw, "<p>milk</p>")
    }

    func testFidelityWarningDescribesWhatWasLost() {
        let warning = FidelityWarning(kind: .unsupportedElement,
                                      detail: "table with merged cells")
        XCTAssertEqual(warning.kind, .unsupportedElement)
        XCTAssertTrue(warning.detail.contains("merged"))
    }
}
