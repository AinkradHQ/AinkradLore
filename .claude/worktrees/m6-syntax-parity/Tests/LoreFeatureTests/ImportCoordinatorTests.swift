import XCTest
@testable import LoreFeature

/// End-to-end through the coordinator, because this is the task that makes the
/// pipeline reachable at all: until now `ImportPreviewSheet` had no call site,
/// so nothing exercised scan -> read ids -> plan -> apply as one motion.
@MainActor
final class ImportCoordinatorTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeObsidianVault(_ files: [String: String]) throws -> URL {
        let root = try makeDirectory()
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Both unwrappers FAIL on the wrong state; they must never skip. A skipped
    /// test reads as green, so a coordinator that silently stopped in `.failed`
    /// would report as a pass — the exact shape of "the suite answered a
    /// different question" that this milestone keeps hitting.
    private struct WrongState: Error, CustomStringConvertible {
        let expected: String
        let actual: String
        var description: String { "expected \(expected), got \(actual)" }
    }

    private func selection(of state: ImportEntryState) throws -> ImportSelection {
        guard case .previewing(let selection) = state else {
            throw WrongState(expected: ".previewing", actual: "\(state)")
        }
        return selection
    }

    private func report(of state: ImportEntryState) throws -> ImportReport {
        guard case .finished(let report) = state else {
            throw WrongState(expected: ".finished", actual: "\(state)")
        }
        return report
    }

    // MARK: - the idempotency hole this task closes

    /// THE test for this task. Import a vault, then import the same vault into
    /// the same target again: the second run must create nothing. Before the
    /// reader existed there was no producer of `existingImportIDs` anywhere, so
    /// this would have doubled every file.
    func testImportingTheSameVaultTwiceCreatesNothingTheSecondTime() async throws {
        let source = try makeObsidianVault(["A.md": "one", "Media/pic.png": "bytes"])
        let target = try makeDirectory()

        let first = ImportCoordinator(vaultRoot: target)
        await first.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        await first.apply(try selection(of: first.state).plan)
        let afterFirst = try report(of: first.state)
        XCTAssertEqual(afterFirst.failed.count, 0)
        XCTAssertEqual(afterFirst.imported.count, 2)
        let landed = try filesIn(target)

        let second = ImportCoordinator(vaultRoot: target)
        await second.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        let previewed = try selection(of: second.state)
        XCTAssertTrue(previewed.plan.creating.isEmpty,
                      "a re-import must offer nothing to create; got \(previewed.plan.creating)")

        await second.apply(previewed.plan)
        let afterSecond = try report(of: second.state)
        XCTAssertTrue(afterSecond.imported.isEmpty)
        XCTAssertEqual(afterSecond.skipped.count, 2)
        XCTAssertEqual(try filesIn(target), landed,
                       "the second run must not have touched the vault")
    }

    /// The attachment half specifically. Fixing the junk-empty-note bug removed
    /// the note that used to carry an attachment-only item's id, so a re-scan
    /// re-copied every binary as `pic 2.png`, `pic 3.png`, … unbounded. A
    /// markdown-only assertion would not have caught it.
    func testARepeatedImportDoesNotAccumulateCopiesOfBinaries() async throws {
        let source = try makeObsidianVault(["Media/pic.png": "bytes"])
        let target = try makeDirectory()

        for _ in 0..<3 {
            let coordinator = ImportCoordinator(vaultRoot: target)
            await coordinator.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
            await coordinator.apply(try selection(of: coordinator.state).plan)
        }

        let media = try FileManager.default.contentsOfDirectory(
            atPath: target.appendingPathComponent("Media").path)
        XCTAssertEqual(media, ["pic.png"], "expected exactly one copy; got \(media)")
    }

    /// The reader's liveness rule, through the coordinator: deleting an
    /// imported file must make it importable again, or "delete and re-import"
    /// silently does nothing.
    func testDeletingAnImportedFileMakesItImportableAgain() async throws {
        let source = try makeObsidianVault(["Media/pic.png": "bytes"])
        let target = try makeDirectory()

        let first = ImportCoordinator(vaultRoot: target)
        await first.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        await first.apply(try selection(of: first.state).plan)
        try FileManager.default.removeItem(at: target.appendingPathComponent("Media/pic.png"))

        let second = ImportCoordinator(vaultRoot: target)
        await second.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        XCTAssertEqual(try selection(of: second.state).plan.creating.count, 1)
    }

    // MARK: - states

    func testAScannedVaultLandsInPreviewWithEveryItem() async throws {
        let source = try makeObsidianVault(["A.md": "one", "B.md": "two"])
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        XCTAssertEqual(try selection(of: coordinator.state).items.count, 2)
    }

    func testAnEmptySourceIsExplainedRatherThanPreviewedAsNothing() async throws {
        let source = try makeDirectory()
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(ObsidianSource(vaultURL: source), sourceRoot: source)
        guard case .failed = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
    }

    func testResetReturnsToTheSourcePicker() async throws {
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(ObsidianSource(vaultURL: try makeDirectory()),
                               sourceRoot: nil)
        coordinator.reset()
        guard case .choosingSource = coordinator.state else {
            return XCTFail("expected .choosingSource, got \(coordinator.state)")
        }
    }

    // MARK: - the Apple Notes route

    /// Denies with the same error `OSAScriptRunner` raises on a -1743.
    private struct DenyingRunner: ScriptRunner {
        func run(_ source: String) throws -> String {
            throw ImportSourceError.permissionDenied("Allow Ainkrad to control Notes.")
        }
    }

    private struct StubRunner: ScriptRunner {
        let output: String
        func run(_ source: String) throws -> String { output }
    }

    /// A denial from Notes is FIXABLE, and its own state, so the view can put
    /// the Automation pane one button away instead of describing where it is.
    func testAnAutomationDenialBecomesItsOwnFixableState() async throws {
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(AppleNotesScriptSource(runner: DenyingRunner()),
                               sourceRoot: nil)
        guard case .needsAutomation(let detail) = coordinator.state else {
            throw WrongState(expected: ".needsAutomation", actual: "\(coordinator.state)")
        }
        XCTAssertTrue(detail.contains("Notes"))
    }

    /// The counterpart that stops the mapping being a blanket one. An
    /// unreadable Obsidian folder is ALSO `.permissionDenied`; routing it to
    /// the Automation pane would send the user to flip an unrelated switch.
    func testAnObsidianDenialIsNotReportedAsAnAutomationProblem() async throws {
        struct DeniedSource: ImportSource {
            static let identifier = "obsidian"
            func scan() async throws -> [ImportItem] {
                throw ImportSourceError.permissionDenied("no read access")
            }
        }
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(DeniedSource(), sourceRoot: nil)
        guard case .failed = coordinator.state else {
            throw WrongState(expected: ".failed", actual: "\(coordinator.state)")
        }
    }

    /// The Apple Notes route reaches the same preview as every other source —
    /// it is not a second pipeline, which is what keeps the dry-run promise,
    /// the id skipping and the link rewriting true for notes as well.
    func testScriptedNotesReachTheSamePreviewAsAnyOtherSource() async throws {
        let canned = """
        x-coredata://N1
        Groceries
        iCloud
        Shopping
        978307200
        978307300
        <p>milk</p>
        """
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(AppleNotesScriptSource(runner: StubRunner(output: canned)),
                               sourceRoot: nil)
        let selection = try selection(of: coordinator.state)
        XCTAssertEqual(selection.items.map(\.title), ["Groceries"])
        XCTAssertEqual(selection.plan.creating.count, 1)
    }

    /// An empty Notes library is not a folder, so it must not be explained as
    /// one. The old sentence said "in that folder" for every source.
    func testAnEmptyNotesLibraryIsNotExplainedAsAnEmptyFolder() async throws {
        let coordinator = ImportCoordinator(vaultRoot: try makeDirectory())
        await coordinator.scan(AppleNotesScriptSource(runner: StubRunner(output: "")),
                               sourceRoot: nil)
        guard case .failed(let message) = coordinator.state else {
            throw WrongState(expected: ".failed", actual: "\(coordinator.state)")
        }
        XCTAssertFalse(message.contains("folder"))
    }

    // MARK: - nesting

    func testImportingTheVaultIntoItselfIsRefusedBeforeAnythingIsRead() async throws {
        let vault = try makeObsidianVault(["A.md": "one"])
        let coordinator = ImportCoordinator(vaultRoot: vault)
        await coordinator.scan(ObsidianSource(vaultURL: vault), sourceRoot: vault)
        guard case .failed = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        // Nothing was scanned, so nothing was written.
        XCTAssertEqual(try filesIn(vault), ["A.md"])
    }

    func testImportingAFolderInsideTheVaultIsRefused() throws {
        let vault = try makeDirectory()
        let inner = vault.appendingPathComponent("Sub/Folder")
        XCTAssertNotNil(ImportCoordinator.nestingRefusal(source: inner, target: vault))
    }

    func testImportingAFolderThatCONTAINSTheVaultIsRefused() throws {
        let outer = try makeDirectory()
        let vault = outer.appendingPathComponent("Vault")
        XCTAssertNotNil(ImportCoordinator.nestingRefusal(source: outer, target: vault))
    }

    func testTwoUnrelatedFoldersAreNotRefused() throws {
        XCTAssertNil(ImportCoordinator.nestingRefusal(source: try makeDirectory(),
                                                      target: try makeDirectory()))
    }

    private func filesIn(_ root: URL) throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return (walker.allObjects as? [String] ?? []).sorted()
    }
}
