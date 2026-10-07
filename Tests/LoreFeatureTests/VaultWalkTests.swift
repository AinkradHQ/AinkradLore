import XCTest

@testable import LoreFeature

final class VaultWalkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Created before resolving: `/var` → `/private/var` only resolves for a
        // path that exists, and the walk yields the resolved spelling.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = VaultIndexCoordinator.canonical(url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func walkedFiles() -> Set<String> {
        let depth = root.pathComponents.count
        return Set(
            VaultWalk.walk(root).files.map {
                $0.pathComponents.dropFirst(depth).joined(separator: "/")
            })
    }

    func testIndexesDocumentsAndMediaOnly() throws {
        for path in [
            "a.md", "b.pdf", "c.doc", "d.docx", "e.rtf", "f.odt", "g.txt", "photo.png",
            "main.swift", "data.json", "page.html", "archive.zip",
        ] {
            try touch("notes/" + path)
        }
        XCTAssertEqual(
            walkedFiles(),
            Set(
                [
                    "a.md", "b.pdf", "c.doc", "d.docx", "e.rtf", "f.odt",
                    "g.txt", "photo.png",
                ].map { "notes/" + $0 }))
    }

    func testPrunesIgnoredAndDotFolders() throws {
        try touch("keep.md")
        for folder in [
            "node_modules/pkg", ".git", "build", "dist", "vendor/x", "Pods",
            "app/storage/framework/cache", ".obsidian",
        ] {
            try touch(folder + "/readme.md")
        }
        XCTAssertEqual(walkedFiles(), ["keep.md"])
        XCTAssertEqual(Set(VaultWalk.walk(root).directories), ["app", "app/storage"])
    }

    func testHonoursGitignore() throws {
        try touch(".gitignore", "# comment\n*.log.md\ngenerated/\n/root-only.md\n!keep.log.md\n")
        try touch("project/.gitignore", "docs/drafts/\n")
        try touch("note.md")
        try touch("x.log.md")
        try touch("keep.log.md")
        try touch("root-only.md")
        try touch("sub/root-only.md")
        try touch("generated/out.md")
        try touch("project/docs/drafts/wip.md")
        try touch("project/docs/final.md")
        XCTAssertEqual(
            walkedFiles(),
            [
                "note.md", "keep.log.md", "sub/root-only.md",
                "project/docs/final.md",
            ])
    }
}
