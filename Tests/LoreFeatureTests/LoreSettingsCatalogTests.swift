import AinkradAppKit
import XCTest

@testable import LoreFeature

@MainActor
final class LoreSettingsCatalogTests: XCTestCase {
    private func page() throws -> (SettingsPage, LoreStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-set-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(), indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        return (LoreSettingsCatalog.page(store: store, theme: HostTheme(TestTokens.make())), store)
    }

    /// Every row the old view had, in declared tabs — no custom rows at all.
    func test_pageIsDeclared() throws {
        let (page, _) = try page()
        XCTAssertEqual(page.groups.map(\.title), ["Vault", "Editor", "Display", "Index", "Shortcuts"])
        XCTAssertEqual(
            page.groups[1].fields.map(\.label),
            [
                "Text size", "Line width", "Focus mode", "Typewriter scrolling",
                "Experimental CodeMirror editor",
            ])
        let customs = page.groups.flatMap(\.fields).filter { if case .custom = $0.kind { true } else { false } }
        XCTAssertTrue(customs.isEmpty)
        // One shortcut row per command, plus the three written by hand.
        XCTAssertEqual(page.groups[4].fields.count, LoreCommands.all.count + 3)
    }

    func test_editorToggleWritesThroughAndResets() throws {
        let (page, store) = try page()
        let focus = try XCTUnwrap(page.groups[1].fields.first { $0.label == "Focus mode" })
        guard case .toggle(let binding) = focus.kind else { return XCTFail("not a toggle") }
        binding.wrappedValue = true
        XCTAssertTrue(store.editorSettings.focusMode)
        XCTAssertTrue(focus.isModified())
        focus.reset?()
        XCTAssertFalse(store.editorSettings.focusMode)
    }
}
