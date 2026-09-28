import XCTest
@testable import LoreFeature

final class ImportPreviewSelectionTests: XCTestCase {
    private func item(_ id: String, _ title: String, fidelity: [FidelityWarning] = []) -> ImportItem {
        ImportItem(sourceID: id, title: title, body: .markdown("x"), attachments: [],
                   folderPath: [], created: Date(), modified: Date(), fidelity: fidelity)
    }
    private var vault: URL { URL(fileURLWithPath: "/vault") }

    @MainActor
    func testDeselectingAnItemRemovesItFromThePlan() {
        let selection = ImportSelection(items: [item("a", "One"), item("b", "Two")],
                                        vaultRoot: vault, existingImportIDs: [])
        selection.toggle("a")
        XCTAssertEqual(selection.plan.items.map(\.item.sourceID), ["b"])
    }

    @MainActor
    func testDeselectingACollidingItemFreesTheNameForTheOther() {
        let selection = ImportSelection(items: [item("a", "Plan"), item("b", "Plan")],
                                        vaultRoot: vault, existingImportIDs: [])
        XCTAssertEqual(selection.plan.items[1].disposition,
                       .renamedToAvoidCollision(original: "Plan.md"))
        selection.toggle("a")
        // The surviving item must now take the clean name — the plan you approve is
        // the plan that executes, not an approximation of it.
        XCTAssertEqual(selection.plan.items[0].targetURL.lastPathComponent, "Plan.md")
        XCTAssertEqual(selection.plan.items[0].disposition, .create)
    }

    @MainActor
    func testReselectingRestoresTheItem() {
        let selection = ImportSelection(items: [item("a", "One")], vaultRoot: vault,
                                        existingImportIDs: [])
        selection.toggle("a")
        selection.toggle("a")
        XCTAssertEqual(selection.plan.items.count, 1)
    }

    @MainActor
    func testDeselectingEveryItemLeavesAnEmptyPlan() {
        let selection = ImportSelection(items: [item("a", "One"), item("b", "Two")],
                                        vaultRoot: vault, existingImportIDs: [])
        selection.toggle("a")
        selection.toggle("b")
        XCTAssertTrue(selection.plan.items.isEmpty)
        XCTAssertTrue(selection.plan.creating.isEmpty)
    }

    @MainActor
    func testAlreadyImportedItemsCannotBeToggledAndDoNotCountAsCreating() {
        let selection = ImportSelection(items: [item("a", "One"), item("b", "Two")],
                                        vaultRoot: vault, existingImportIDs: ["a"])
        XCTAssertFalse(selection.isSelected("a"))
        selection.toggle("a")
        // Toggling an already-imported item is a no-op: it can never be created,
        // selected or not, so offering to deselect it would be dishonest.
        XCTAssertFalse(selection.isSelected("a"))
        XCTAssertEqual(selection.plan.creating.map(\.item.sourceID), ["b"])
    }

    @MainActor
    func testTogglingInvalidatesTheCachedPlan() {
        let selection = ImportSelection(items: [item("a", "One"), item("b", "Two")],
                                        vaultRoot: vault, existingImportIDs: [])
        let before = selection.plan
        XCTAssertEqual(before.items.map(\.item.sourceID), ["a", "b"])
        selection.toggle("a")
        let after = selection.plan
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.items.map(\.item.sourceID), ["b"])
    }
}
