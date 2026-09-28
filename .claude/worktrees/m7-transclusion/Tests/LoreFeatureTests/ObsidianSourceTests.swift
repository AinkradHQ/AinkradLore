import XCTest
@testable import LoreFeature

final class ObsidianSourceTests: XCTestCase {
    private func makeVault(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEmitsOneItemPerMarkdownFileWithItsFolderPath() async throws {
        let vault = try makeVault(["Ideas/Plan.md": "# Plan\n", "Top.md": "top\n"])
        let items = try await ObsidianSource(vaultURL: vault).scan()
        XCTAssertEqual(Set(items.map(\.title)), ["Plan", "Top"])
        let plan = try XCTUnwrap(items.first { $0.title == "Plan" })
        XCTAssertEqual(plan.folderPath, ["Ideas"])
        XCTAssertEqual(plan.sourceID, "obsidian:Ideas/Plan.md")
    }

    func testSkipsTheObsidianConfigDirectory() async throws {
        let vault = try makeVault([".obsidian/app.json": "{}", "Note.md": "x"])
        let items = try await ObsidianSource(vaultURL: vault).scan()
        XCTAssertEqual(items.map(\.title), ["Note"])
    }

    func testWarnsAboutPluginSyntaxRatherThanConvertingIt() async throws {
        let vault = try makeVault([
            "Q.md": "```dataview\nLIST\n```\n",
            "C.md": "> [!note] heads up\n",
        ])
        let items = try await ObsidianSource(vaultURL: vault).scan()
        for item in items {
            XCTAssertEqual(item.fidelity.first?.kind, .pluginSyntax)
        }
    }

    func testEmitsAttachmentsAsItemsSoTheyTravelWithTheirNotes() async throws {
        let vault = try makeVault(["Note.md": "![[pic.png]]"])
        try Data([0x89, 0x50]).write(to: vault.appendingPathComponent("pic.png"))
        let items = try await ObsidianSource(vaultURL: vault).scan()
        XCTAssertTrue(items.contains { $0.sourceID == "obsidian:pic.png" })
    }

    // MARK: - Symlinked root

    func testProducesCorrectRelativePathsWhenTheVaultRootIsASymlink() async throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let noteURL = real.appendingPathComponent("Sub/Note.md")
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hi".write(to: noteURL, atomically: true, encoding: .utf8)

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: link)
        }

        let items = try await ObsidianSource(vaultURL: link).scan()
        XCTAssertEqual(items.map(\.sourceID), ["obsidian:Sub/Note.md"])
        XCTAssertEqual(items.first?.folderPath, ["Sub"])
    }

    // MARK: - Nested dot-directories

    func testSkipsNestedDotDirectoriesNotJustRootLevelOnes() async throws {
        let vault = try makeVault([
            "Ideas/.trash/Deleted.md": "gone",
            "Ideas/Kept.md": "kept",
        ])
        let items = try await ObsidianSource(vaultURL: vault).scan()
        XCTAssertEqual(items.map(\.title), ["Kept"])
    }

    // MARK: - Unreadable / non-UTF8 markdown

    func testEmitsFidelityWarningForNonUTF8MarkdownInsteadOfSilentEmptyBody() async throws {
        let vault = try makeVault([:])
        let badURL = vault.appendingPathComponent("Bad.md")
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)
        // Invalid UTF-8 byte sequence.
        try Data([0xFF, 0xFE, 0x00, 0xFF]).write(to: badURL)

        let items = try await ObsidianSource(vaultURL: vault).scan()
        let item = try XCTUnwrap(items.first { $0.title == "Bad" })
        XCTAssertTrue(item.fidelity.contains { $0.kind == .unsupportedElement })
        if case .markdown(let text) = item.body {
            XCTAssertTrue(text.isEmpty)
        } else {
            XCTFail("expected markdown body")
        }
    }
}
