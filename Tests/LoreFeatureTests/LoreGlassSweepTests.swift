import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Glass Native E5: Lore's chrome under Neon (neonBlue) and Liquid Glass,
/// shot LIVE — off-screen `cacheDisplay` cannot draw Liquid Glass. Each shot is
/// a real window at desktop level (behind every window, no focus taken); a
/// request file `<window> <png>` in `<dir>/.requests` is answered by
/// `.build/capture-broker.sh`, because the test host has no Screen Recording
/// grant. SKIPPED unless `LORE_GLASS_SWEEP_DIR` and `LORE_GLASS_THEMES_DIR`
/// (the catalog's `themes/`) are set.
@MainActor
final class LoreGlassSweepTests: XCTestCase {
    private var directory: URL!
    private var runs: [(name: String, skin: AinkradSkin)] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LORE_GLASS_SWEEP_DIR"], let themes = env["LORE_GLASS_THEMES_DIR"] else {
            throw XCTSkip("set LORE_GLASS_SWEEP_DIR and LORE_GLASS_THEMES_DIR to shoot the Glass sweep")
        }
        directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let neon = try XCTUnwrap(parityPalettes().first { $0.id == "neonBlue" })
        runs = [("neon", neon.skin), ("glass", try glassSkin(themes: URL(fileURLWithPath: themes)))]
    }

    func test_chrome() throws {
        let store = LoreStore(
            documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("lore-glass-\(UUID().uuidString).sqlite"))
        let ops = SidebarOperations(store: store)
        let plan = IndexRow(
            path: URL(fileURLWithPath: "/Vault/Projects/Plan.md"), id: "plan", title: "Plan", tags: [],
            aliases: [], updated: Date(timeIntervalSince1970: 1_790_000_000), type: MarkdownEngine.identifier,
            properties: [])
        let design = IndexRow(
            path: URL(fileURLWithPath: "/Vault/Projects/Design.md"), id: "design", title: "Design Doc", tags: [],
            aliases: [], updated: Date(timeIntervalSince1970: 1_790_000_000), type: MarkdownEngine.identifier,
            properties: [])

        try snap("sidebar-rows", CGSize(width: 300, height: 170)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                LoreSidebarRow.folder(name: "Projects", depth: 0, isExpanded: true, onToggle: {})
                LoreSidebarRow.document(row: plan, depth: 1, isSelected: true, subtitle: "Goals", onTap: {})
                LoreSidebarRow.document(row: design, depth: 1, isSelected: false, onTap: {})
            }
            .padding(8)
        }
        try snap("actions-menu", CGSize(width: 300, height: 220)) { theme in
            DocumentActionsMenu(
                items: loreRowMenuItems(row: plan, ops: ops, store: store), theme: theme, onDismiss: {}
            )
            .padding(16)
        }
        try snap("name-sheet", CGSize(width: 460, height: 220)) { theme in
            NameSheet(title: "New Folder", text: .constant("Research"), theme: theme, onConfirm: {}, onCancel: {})
        }
        try snap("slideover", CGSize(width: 420, height: 320)) { theme in
            ZStack(alignment: .trailing) {
                Text("Editor text behind the slideover").frame(maxWidth: .infinity, maxHeight: .infinity)
                DocumentSlideover(title: "Mentions", theme: theme, onClose: {}) { Text("Backlinks") }
            }
        }
        try snap("shortcuts", CGSize(width: 560, height: 600)) { theme in
            LoreShortcutsReference(theme: theme).padding(16)
        }
    }

    // MARK: - plumbing

    private func snap<V: View>(_ slug: String, _ size: CGSize, _ make: (HostTheme) -> V) throws {
        for run in runs {
            let tokens = HostThemeTokens(skin: run.skin)
            let theme = HostTheme(tokens)
            let view = make(theme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(tokens.background)
                .environment(\.ainkradTheme, tokens)
                .ainkradSkin(run.skin)
                .environment(\.colorScheme, .dark)
            try liveShoot(view, size: size, to: directory.appendingPathComponent("\(slug)-\(run.name).png"))
        }
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`.
    private func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let loaded = ainkradLoadThemes([base, try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))])
        let variant = try XCTUnwrap(loaded.themes["glass.dark"])
        var scheme = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        let data = try JSONSerialization.data(withJSONObject: scheme)
        return try AinkradThemeFile(decoding: data, bases: ["glass.dark": variant]).skin
    }
}

private final class KeyAppearancePanel: NSPanel {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { false }
    @objc var hasKeyAppearance: Bool { true }
    @objc var hasMainAppearance: Bool { true }
    @objc var _hasActiveAppearance: Bool { true }
    @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
}

@MainActor
private func liveShoot(_ view: some View, size: CGSize, to url: URL) throws {
    let panel = KeyAppearancePanel(
        contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.hasShadow = false
    // No order-in fade: the first window of a run was captured mid-fade.
    panel.animationBehavior = .none
    panel.contentView = NSHostingView(
        rootView: view.environment(\.controlActiveState, .key).frame(width: size.width, height: size.height))
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    settle(0.5)
    let requests = url.deletingLastPathComponent().appendingPathComponent(".requests", isDirectory: true)
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    try "\(panel.windowNumber) \(url.path)".write(
        to: requests.appendingPathComponent(UUID().uuidString + ".req"), atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { settle(0.05) }
    settle(0.1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no capture broker answered for \(url.lastPathComponent)")
}
