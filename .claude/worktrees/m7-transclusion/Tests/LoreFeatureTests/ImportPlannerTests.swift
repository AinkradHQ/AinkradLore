import XCTest
@testable import LoreFeature

final class ImportPlannerTests: XCTestCase {
    private func item(_ id: String, _ title: String,
                      folders: [String] = []) -> ImportItem {
        ImportItem(sourceID: id, title: title, body: .markdown("x"), attachments: [],
                   folderPath: folders, created: Date(), modified: Date(), fidelity: [])
    }

    private var vault: URL { URL(fileURLWithPath: "/vault") }

    func testMapsFolderPathOntoTargetDirectories() {
        let plan = ImportPlanner.plan(items: [item("a", "Plan", folders: ["Ideas"])],
                                      vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(plan.items[0].targetURL.path, "/vault/Ideas/Plan.md")
        XCTAssertEqual(plan.items[0].disposition, .create)
    }

    func testRenamesTheSecondOfTwoCollidingTitles() {
        let plan = ImportPlanner.plan(items: [item("a", "Plan"), item("b", "Plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(plan.items[0].targetURL.lastPathComponent, "Plan.md")
        XCTAssertNotEqual(plan.items[1].targetURL.lastPathComponent, "Plan.md")
        guard case .renamedToAvoidCollision(let original) = plan.items[1].disposition else {
            return XCTFail("expected a collision disposition")
        }
        XCTAssertEqual(original, "Plan.md")
    }

    func testMarksAlreadyImportedItemsInsteadOfDuplicatingThem() {
        let plan = ImportPlanner.plan(items: [item("a", "Plan")],
                                      vaultRoot: vault, existingImportIDs: ["a"])
        XCTAssertEqual(plan.items[0].disposition, .alreadyImported)
    }

    func testSanitisesTitlesThatAreNotLegalFilenames() {
        let plan = ImportPlanner.plan(items: [item("a", "Q3/Q4: plan")],
                                      vaultRoot: vault, existingImportIDs: [])
        let name = plan.items[0].targetURL.lastPathComponent
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testDroppingACollidingItemFreesTheNameItWouldHaveTaken() {
        let all = [item("a", "Plan"), item("b", "Plan"), item("c", "Other")]
        let full = ImportPlanner.plan(items: all, vaultRoot: vault, existingImportIDs: [])
        // With both present, the second "Plan" is renamed out of the way.
        XCTAssertEqual(full.items[1].disposition,
                       .renamedToAvoidCollision(original: "Plan.md"))

        // Dropping it must give the survivor the clean name back — planning is
        // recomputed from the selection, never patched. This is the property the
        // dry-run promise rests on: what you approved is what executes.
        let subset = ImportPlanner.plan(items: [all[0], all[2]], vaultRoot: vault,
                                        existingImportIDs: [])
        XCTAssertEqual(subset.items.map(\.targetURL.lastPathComponent),
                       ["Plan.md", "Other.md"])
        XCTAssertEqual(subset.items.map(\.disposition), [.create, .create])
    }

    // MARK: - Additional cases beyond the brief

    /// Two DIFFERENT titles that sanitize to the SAME filename must still be
    /// treated as a collision — the `taken` set is keyed on the resolved
    /// path, not on title equality.
    func testDifferentTitlesThatSanitizeToTheSameNameStillCollide() {
        let plan = ImportPlanner.plan(items: [item("a", "A/B"), item("b", "A:B")],
                                      vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(plan.items[0].targetURL.lastPathComponent, "A-B.md")
        XCTAssertEqual(plan.items[0].disposition, .create)
        guard case .renamedToAvoidCollision(let original) = plan.items[1].disposition else {
            return XCTFail("expected a collision disposition")
        }
        XCTAssertEqual(original, "A-B.md")
        XCTAssertNotEqual(plan.items[1].targetURL.lastPathComponent, "A-B.md")
    }

    /// A title that sanitizes to empty text (all dots, or pure path-escape
    /// characters) must not produce a bare `.md` target — `sanitized`
    /// already falls back to a fixed placeholder for this case.
    func testTitleThatSanitizesToEmptyDoesNotProduceABareExtension() {
        let plan = ImportPlanner.plan(items: [item("a", "...")],
                                      vaultRoot: vault, existingImportIDs: [])
        let name = plan.items[0].targetURL.lastPathComponent
        XCTAssertNotEqual(name, ".md")
        XCTAssertFalse(name.hasPrefix("."))
    }

    /// Collision resolution must be stable and never skip or reuse a
    /// counter value across three colliding titles.
    func testCollisionCounterIsStableAndDoesNotSkipOrReuse() {
        let all = [item("a", "Plan"), item("b", "Plan"), item("c", "Plan")]
        let plan = ImportPlanner.plan(items: all, vaultRoot: vault, existingImportIDs: [])
        let names = plan.items.map(\.targetURL.lastPathComponent)
        XCTAssertEqual(names, ["Plan.md", "Plan 2.md", "Plan 3.md"])
        // Re-running with the identical input must yield the identical
        // assignment — determinism is the whole point of a pure planner.
        let rerun = ImportPlanner.plan(items: all, vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(rerun.items.map(\.targetURL.lastPathComponent), names)
    }

    /// `folderPath` components are sanitized too: a folder named "Q3/Q4"
    /// must not escape into a nested directory via the slash.
    func testFolderPathComponentsAreSanitized() {
        let plan = ImportPlanner.plan(items: [item("a", "Note", folders: ["Q3/Q4"])],
                                      vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(plan.items[0].targetURL.path, "/vault/Q3-Q4/Note.md")
    }

    /// A `folderPath` containing `..` must not be able to plan a target
    /// outside the vault root.
    func testFolderPathTraversalCannotEscapeTheVaultRoot() {
        let plan = ImportPlanner.plan(items: [item("a", "Note", folders: ["..", "..", "etc"])],
                                      vaultRoot: vault, existingImportIDs: [])
        let targetPath = plan.items[0].targetURL.standardizedFileURL.path
        XCTAssertTrue(targetPath.hasPrefix(vault.standardizedFileURL.path + "/"))
    }

    /// Pins the purity requirement itself: `plan(...)` must be callable with
    /// no main-actor hop, since the preview needs to re-run it cheaply from
    /// wherever a checkbox toggle happens. A test that only ever called
    /// `plan` from the (implicitly main-actor) test method would pass even
    /// if `ImportPlanner` were `@MainActor`-isolated — that isolation would
    /// just be silently satisfied by the test runner's own context. Running
    /// inside `Task.detached` proves the call compiles and succeeds with NO
    /// actor context at all.
    func testPlanIsCallableFromANonisolatedDetachedContext() async {
        let items = [item("a", "Plan"), item("b", "Plan")]
        let names: [String] = await Task.detached {
            let plan = ImportPlanner.plan(items: items, vaultRoot: URL(fileURLWithPath: "/vault"),
                                          existingImportIDs: [])
            return plan.items.map(\.targetURL.lastPathComponent)
        }.value
        XCTAssertEqual(names, ["Plan.md", "Plan 2.md"])
    }
}
