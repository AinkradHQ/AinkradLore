import XCTest
import GRDB
@testable import LoreFeature

final class LoreIndexTests: XCTestCase {
    private func makeIndex() throws -> LoreIndex {
        try LoreIndex(path: URL(fileURLWithPath: "/tmp/lore-index-\(UUID()).sqlite"))
    }
    private func entry(_ name: String, title: String, body: String) -> IndexEntry {
        IndexEntry(url: URL(fileURLWithPath: "/tmp/v/\(name).md"),
                   type: "markdown",
                   payload: IndexPayload(title: title, plaintext: body, tags: ["t"], id: name),
                   updated: Date())
    }

    func test_upsert_thenAll_returnsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "hello world"))
        XCTAssertEqual(try idx.all().map(\.title), ["Alpha"])
    }

    func test_search_matchesBody() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "the quick brown fox"))
        try idx.upsert(entry("b", title: "Beta", body: "lazy dog sleeps"))
        XCTAssertEqual(try idx.search("brown").map(\.id), ["a"])
        XCTAssertEqual(try idx.search("Beta").map(\.id), ["b"])   // title is indexed too
    }

    func test_remove_dropsRow() throws {
        let idx = try makeIndex()
        try idx.upsert(entry("a", title: "Alpha", body: "x"))
        try idx.remove(path: URL(fileURLWithPath: "/tmp/v/a.md"))
        XCTAssertTrue(try idx.all().isEmpty)
    }

    func test_indexesEntriesOfAnyType() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let index = try LoreIndex(path: dbURL)
        let entry = IndexEntry(
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            type: "plaintext",
            payload: IndexPayload(title: "A", plaintext: "needle in here"),
            updated: Date())
        try index.replaceAll(with: [entry])
        XCTAssertEqual(try index.all().map(\.type), ["plaintext"])
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["A"])
    }

    func test_storesProperties() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let index = try LoreIndex(path: dbURL)
        let entry = IndexEntry(
            url: URL(fileURLWithPath: "/tmp/a.md"),
            type: "markdown",
            payload: IndexPayload(title: "A", plaintext: "b",
                                  properties: [FrontmatterPair(key: "status", rawValue: "active")]),
            updated: Date())
        try index.replaceAll(with: [entry])
        XCTAssertEqual(try index.all().first?.properties.first?.key, "status")
    }

    /// A corrupt index must cost a rescan, never the vault: if `init` threw,
    /// `activate` would fail and the user's notes would never open again.
    func test_corruptIndexFileSelfHeals() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        try Data(repeating: 0xAB, count: 4096).write(to: dbURL)

        let index = try LoreIndex(path: dbURL)
        try index.upsert(entry("a", title: "Alpha", body: "recovered needle"))
        XCTAssertEqual(index.searchOrEmpty("needle").map(\.title), ["Alpha"])
    }

    func test_staleSchemaIsRebuiltNotRead() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        // Create a v1-shaped database by hand.
        let legacy = try DatabaseQueue(path: dbURL.path)
        try legacy.write { db in
            try db.execute(sql: "PRAGMA user_version = 1;")
            try db.execute(sql: "CREATE TABLE notes(path TEXT PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO notes(path) VALUES('/tmp/old.md');")
        }
        _ = legacy   // release before reopening

        let index = try LoreIndex(path: dbURL)
        XCTAssertTrue(try index.all().isEmpty, "stale index should be discarded, not read")
    }

    // MARK: - Links

    private func linkedEntry(_ path: String, title: String,
                              links: [ResolvedLink] = []) -> IndexEntry {
        IndexEntry(url: URL(fileURLWithPath: path), type: "markdown",
                   payload: IndexPayload(title: title, plaintext: "x"),
                   updated: Date(), resolvedLinks: links)
    }

    func test_backlinksListDocumentsPointingAtATarget() throws {
        let index = try makeIndex()
        let target = URL(fileURLWithPath: "/v/Design.md")
        try index.replaceAll(with: [
            linkedEntry("/v/A.md", title: "A",
                        links: [ResolvedLink(rawTarget: "Design", targetPath: target, isEmbed: false)]),
            linkedEntry("/v/B.md", title: "B",
                        links: [ResolvedLink(rawTarget: "Design#Overview", targetPath: target, isEmbed: false)]),
            linkedEntry("/v/C.md", title: "C"),
            linkedEntry("/v/Design.md", title: "Design"),
        ])
        XCTAssertEqual(Set(try index.backlinks(to: target).map(\.title)), ["A", "B"])
    }

    func test_unresolvedLinksAreListedPerDocument() throws {
        let index = try makeIndex()
        try index.replaceAll(with: [
            linkedEntry("/v/A.md", title: "A", links: [
                ResolvedLink(rawTarget: "Missing", targetPath: nil, isEmbed: false),
                ResolvedLink(rawTarget: "Design", targetPath: URL(fileURLWithPath: "/v/Design.md"),
                             isEmbed: false),
            ]),
            linkedEntry("/v/Design.md", title: "Design"),
        ])
        XCTAssertEqual(try index.unresolvedLinks(from: URL(fileURLWithPath: "/v/A.md")),
                       [UnresolvedLink(rawTarget: "Missing", syntax: .wikilink)])
    }

    func test_outgoingLinksPreserveRawTargets() throws {
        let index = try makeIndex()
        let target = URL(fileURLWithPath: "/v/Design.md")
        try index.replaceAll(with: [
            linkedEntry("/v/A.md", title: "A",
                        links: [ResolvedLink(rawTarget: "design", targetPath: target, isEmbed: false)]),
        ])
        let out = try index.outgoingLinks(from: URL(fileURLWithPath: "/v/A.md"))
        XCTAssertEqual(out.map(\.rawTarget), ["design"])
        XCTAssertEqual(out.first?.targetPath, target)
    }

    func test_replaceAllPrunesLinksOfRemovedDocuments() throws {
        let index = try makeIndex()
        let target = URL(fileURLWithPath: "/v/Design.md")
        try index.replaceAll(with: [
            linkedEntry("/v/A.md", title: "A",
                        links: [ResolvedLink(rawTarget: "Design", targetPath: target, isEmbed: false)]),
            linkedEntry("/v/Design.md", title: "Design"),
        ])
        try index.replaceAll(with: [linkedEntry("/v/Design.md", title: "Design")])
        XCTAssertTrue(try index.backlinks(to: target).isEmpty)
    }

    func test_schemaVersionTwoIndexIsRebuiltNotRead() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID()).sqlite")
        let legacy = try DatabaseQueue(path: path.path)
        try legacy.write { db in
            try db.execute(sql: "PRAGMA user_version = 2;")
            try db.execute(sql: "CREATE TABLE documents(path TEXT PRIMARY KEY);")
            try db.execute(sql: "INSERT INTO documents(path) VALUES('/v/old.md');")
        }
        try legacy.close()
        let index = try LoreIndex(path: path)
        XCTAssertTrue(try index.all().isEmpty)
    }

    func test_isEditableAndByteSize_roundTrip() throws {
        let index = try makeIndex()
        let url = URL(fileURLWithPath: "/tmp/lore-test/Contract.pdf")
        try index.upsert(IndexEntry(
            url: url, type: PDFEngine.identifier,
            payload: IndexPayload(title: "Contract", plaintext: "revenue"),
            updated: Date(), resolvedLinks: [], isEditable: false, byteSize: 4096))
        let row = try XCTUnwrap(try index.all().first { $0.path.lastPathComponent == "Contract.pdf" })
        XCTAssertFalse(row.isEditable)
        XCTAssertEqual(row.byteSize, 4096)
    }

    // A bare pin, deliberately: it exists to fail the moment anyone bumps
    // `schemaVersion`, so a bump is always a deliberate, acknowledged act —
    // changing this assertion means accepting a full index rebuild on next
    // launch for every existing vault, not an incidental edit.
    func test_schemaVersion_isEight() {
        XCTAssertEqual(LoreIndex.schemaVersion, 8)
    }

    func test_isTruncated_roundTrips() throws {
        let index = try makeIndex()
        let url = URL(fileURLWithPath: "/tmp/lore-test/Huge.pdf")
        try index.upsert(IndexEntry(
            url: url, type: PDFEngine.identifier,
            payload: IndexPayload(title: "Huge", plaintext: "start"),
            updated: Date(), resolvedLinks: [], isEditable: false,
            byteSize: 90_000_000, isTruncated: true))
        let row = try XCTUnwrap(try index.all().first { $0.path.lastPathComponent == "Huge.pdf" })
        XCTAssertTrue(row.isTruncated)
    }
}
