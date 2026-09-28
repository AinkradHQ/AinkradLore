import XCTest
@testable import LoreFeature

/// The interaction tests. Each one covers a failure no single-unit test catches
/// — the whole-branch review of part 1 found a defect (every binary producing a
/// junk empty note) that lived entirely in the seam between two tasks whose own
/// suites were both green.
@MainActor
final class ImportAcceptanceTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeObsidianVault(_ files: [String: String]) throws -> URL {
        let root = try makeVault()
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// End to end: scan a real vault on disk, plan it, apply it, and read back
    /// what landed. Neither half alone proves the pipeline works.
    func testObsidianVaultRoundTripsIntoLore() async throws {
        let source = try makeObsidianVault(["Ideas/Plan.md": "# Plan\nbody\n"])
        let target = try makeVault()
        let items = try await ObsidianSource(vaultURL: source).scan()
        let plan = ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: target).apply(plan)

        XCTAssertEqual(report.failed.count, 0)
        let landed = target.appendingPathComponent("Ideas/Plan.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        XCTAssertTrue(try text(at: landed).contains("body"))
    }

    // MARK: - link rewriting

    /// Collision AND link rewrite together. Neither test alone catches the
    /// interaction: a renamed note whose inbound links still point at the old
    /// name is a silently broken vault — and worse than broken, because
    /// `[[Plan]]` now resolves to the user's OWN unrelated Plan.
    func testALinkFollowsANoteThatWasRenamedForACollision() async throws {
        let target = try makeVault()
        try "the user's own file".write(to: target.appendingPathComponent("Plan.md"),
                                        atomically: true, encoding: .utf8)
        let source = try makeObsidianVault([
            "Plan.md": "the imported plan",
            "Index.md": "see [[Plan]] for details",
        ])
        let items = try await ObsidianSource(vaultURL: source).scan()
        let report = await ImportApplier(vaultRoot: target).apply(
            ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: []))
        XCTAssertEqual(report.failed.count, 0)

        let index = try XCTUnwrap(report.imported.first {
            $0.lastPathComponent.hasPrefix("Index")
        })
        do {
            let body = try text(at: index)
            XCTAssertTrue(body.contains("[[Plan 2]]"),
                          "the link must follow the note; got: \(body)")
        }
        // And the user's own file is untouched — the whole reason the note had
        // to move in the first place.
        XCTAssertEqual(try text(at: target.appendingPathComponent("Plan.md")),
                       "the user's own file")
    }

    /// The attachment half, which is the one with no ambiguity at all: an embed
    /// pointing at a renamed image is orphaned outright, rendering as nothing.
    func testAnEmbedFollowsAnAttachmentThatWasRenamedForACollision() async throws {
        let target = try makeVault()
        try "the user's own picture".write(to: target.appendingPathComponent("pic.png"),
                                           atomically: true, encoding: .utf8)
        let source = try makeObsidianVault([
            "pic.png": "imported bytes",
            "Album.md": "here it is: ![[pic.png]]",
        ])
        let items = try await ObsidianSource(vaultURL: source).scan()
        let report = await ImportApplier(vaultRoot: target).apply(
            ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: []))

        let album = try XCTUnwrap(report.imported.first {
            $0.lastPathComponent.hasPrefix("Album")
        })
        do {
            let body = try text(at: album)
            XCTAssertTrue(body.contains("![[pic 2.png]]"),
                          "the embed must follow the image; got: \(body)")
        }
        XCTAssertEqual(try text(at: target.appendingPathComponent("pic.png")),
                       "the user's own picture")
    }

    /// The rewrite must not reach into places that only LOOK like links.
    /// `LinkRewriter.replacingLinkTargets` drives the real `LinkParser`, which
    /// is what earns this — a hand-rolled string replace would fail it.
    func testTheRewriteLeavesCodeBlocksAlone() async throws {
        let target = try makeVault()
        try "own".write(to: target.appendingPathComponent("Plan.md"),
                        atomically: true, encoding: .utf8)
        let source = try makeObsidianVault([
            "Plan.md": "imported",
            "Doc.md": "```\n[[Plan]]\n```\n\nand a real [[Plan]]",
        ])
        let items = try await ObsidianSource(vaultURL: source).scan()
        let report = await ImportApplier(vaultRoot: target).apply(
            ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: []))

        let doc = try text(at: try XCTUnwrap(report.imported.first {
            $0.lastPathComponent.hasPrefix("Doc")
        }))
        XCTAssertTrue(doc.contains("```\n[[Plan]]\n```"),
                      "the fenced sample must be untouched; got: \(doc)")
        XCTAssertTrue(doc.contains("a real [[Plan 2]]"), "got: \(doc)")
    }

    func testNothingIsRewrittenWhenNothingWasRenamed() async throws {
        let source = try makeObsidianVault([
            "Plan.md": "imported", "Index.md": "see [[Plan]]",
        ])
        let target = try makeVault()
        let items = try await ObsidianSource(vaultURL: source).scan()
        let report = await ImportApplier(vaultRoot: target).apply(
            ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: []))

        XCTAssertTrue(report.renamed.isEmpty)
        let index = try XCTUnwrap(report.imported.first { $0.lastPathComponent.hasPrefix("Index") })
        XCTAssertTrue(try text(at: index).contains("[[Plan]]"))
    }

    // MARK: - the previewed plan vs what landed

    /// THE CONTRACT, decided here rather than discovered later: with nothing
    /// already on disk to collide with, the plan the user approved IS the plan
    /// that executes, path for path. This is the dry-run promise.
    func testThePreviewedPlanEqualsThePlanThatExecutes() async throws {
        let source = try makeObsidianVault(["A.md": "one", "B.md": "two", "C.md": "three"])
        let target = try makeVault()
        let items = try await ObsidianSource(vaultURL: source).scan()
        let selection = ImportSelection(items: items, vaultRoot: target, existingImportIDs: [])
        selection.toggle(try XCTUnwrap(items.first { $0.title == "B" }).sourceID)
        let previewed = selection.plan

        let report = await ImportApplier(vaultRoot: target).apply(previewed)
        XCTAssertEqual(Set(report.imported), Set(previewed.creating.map(\.targetURL)))
        XCTAssertTrue(report.renamed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("B.md").path))
    }

    /// And the other half of that contract: when reality DOES diverge — the
    /// pure planner cannot see files already on disk — the divergence is
    /// reported, not silently absorbed. A report that claimed the previewed
    /// path would be a report that lied.
    func testADivergenceFromThePreviewedPathIsReported() async throws {
        let target = try makeVault()
        try "own".write(to: target.appendingPathComponent("Plan.md"),
                        atomically: true, encoding: .utf8)
        let source = try makeObsidianVault(["Plan.md": "imported"])
        let items = try await ObsidianSource(vaultURL: source).scan()
        let previewed = ImportPlanner.plan(items: items, vaultRoot: target,
                                           existingImportIDs: [])
        let report = await ImportApplier(vaultRoot: target).apply(previewed)

        XCTAssertNotEqual(Set(report.imported), Set(previewed.creating.map(\.targetURL)))
        XCTAssertEqual(report.renamed.map(\.from), ["Plan.md"])
        XCTAssertEqual(report.renamed.map(\.to), ["Plan 2.md"])
    }

    // MARK: - idempotency

    /// The single most likely real bug: a retried import doubling the notes.
    func testImportingTwiceCreatesNothingTheSecondTime() async throws {
        let source = try makeObsidianVault(["A.md": "one", "B.md": "two"])
        let target = try makeVault()
        let items = try await ObsidianSource(vaultURL: source).scan()
        let applier = ImportApplier(vaultRoot: target)
        _ = await applier.apply(ImportPlanner.plan(items: items, vaultRoot: target,
                                                   existingImportIDs: []))
        let after = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()

        // Read the ids back off disk rather than reusing the in-memory set —
        // that round trip through the vault is the thing being tested.
        let seen = ImportIDReader.read(vaultRoot: target)
        let second = await applier.apply(ImportPlanner.plan(items: items, vaultRoot: target,
                                                            existingImportIDs: seen))
        XCTAssertTrue(second.imported.isEmpty)
        XCTAssertEqual(second.skipped.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(),
                       after)
    }

    /// A vault of binaries must import as binaries — not as binaries PLUS a
    /// junk empty note each. This is the part-1 seam defect, kept as a
    /// standing test so the two-pass rewrite could not reintroduce it.
    func testBinariesImportWithoutProducingJunkNotes() async throws {
        let source = try makeObsidianVault([
            "Media/one.png": "a", "Media/two.pdf": "b", "Real.md": "text",
        ])
        let target = try makeVault()
        let items = try await ObsidianSource(vaultURL: source).scan()
        let report = await ImportApplier(vaultRoot: target).apply(
            ImportPlanner.plan(items: items, vaultRoot: target, existingImportIDs: []))

        XCTAssertEqual(report.failed.count, 0)
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: target.appendingPathComponent("Media").path).sorted(),
                       ["one.png", "two.pdf"])
    }
}
