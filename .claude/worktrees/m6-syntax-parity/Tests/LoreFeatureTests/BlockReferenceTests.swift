import XCTest
@testable import LoreFeature

final class BlockReferenceTests: XCTestCase {

    func test_model_collectsBlockAnchorsWithOffsets() {
        let model = MarkdownDocumentModel(body: "First. ^one\n\nSecond. ^two")
        XCTAssertEqual(model.blockAnchors.map(\.id), ["one", "two"])
        XCTAssertEqual(model.blockAnchors.first?.offset, 7)
    }

    func test_index_storesAndReadsBackABlockOffset() throws {
        let idx = try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-blocks-\(UUID()).sqlite"))
        try idx.upsert(IndexEntry(
            url: URL(fileURLWithPath: "/tmp/v/a.md"),
            type: "markdown",
            payload: IndexPayload(title: "A", plaintext: "First. ^one",
                                  blocks: [BlockAnchor(id: "one", offset: 7)]),
            updated: Date()))
        XCTAssertEqual(try idx.blockOffset(inDocumentAt: "/tmp/v/a.md", id: "one"), 7)
    }

    func test_index_removingADocumentDropsItsBlocks() throws {
        let idx = try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-blocks-\(UUID()).sqlite"))
        let url = URL(fileURLWithPath: "/tmp/v/a.md")
        try idx.upsert(IndexEntry(url: url, type: "markdown",
                                  payload: IndexPayload(title: "A", plaintext: "x ^one",
                                                        blocks: [BlockAnchor(id: "one", offset: 2)]),
                                  updated: Date()))
        try idx.remove(path: url)
        XCTAssertNil(try idx.blockOffset(inDocumentAt: url.path, id: "one"))
    }

    func test_index_reupsertReplacesRatherThanAccumulates() throws {
        // Editing a note must not leave the OLD anchors behind, or a moved
        // block resolves to where it used to be.
        let idx = try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-blocks-\(UUID()).sqlite"))
        let url = URL(fileURLWithPath: "/tmp/v/a.md")
        func write(_ offset: Int) throws {
            try idx.upsert(IndexEntry(url: url, type: "markdown",
                                      payload: IndexPayload(title: "A", plaintext: "x ^one",
                                                            blocks: [BlockAnchor(id: "one", offset: offset)]),
                                      updated: Date()))
        }
        try write(2)
        try write(40)
        XCTAssertEqual(try idx.blockOffset(inDocumentAt: url.path, id: "one"), 40)
    }

    func test_linkResolver_parsesBlockFragment() {
        // `#^id` is a BLOCK fragment; `#Heading` is a heading fragment. The
        // resolver must tell them apart.
        XCTAssertEqual(LinkResolver.fragment(of: "Note#^abc"), .block("abc"))
        XCTAssertEqual(LinkResolver.fragment(of: "Note#Heading"), .heading("Heading"))
        XCTAssertNil(LinkResolver.fragment(of: "Note"))
    }
}
