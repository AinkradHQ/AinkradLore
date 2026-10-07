import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Tier A of the Epic 5B parity screenshots: the SwiftUI screens the harness
/// can render off-screen, each under all seven host palettes.
///
/// One test per screen of the inventory in the 5B plan (§5.2): S5, S6, S7 and
/// S9–S12 (S9 without the PDF and QuickLook viewers, which are Tier B).
/// S15/S16 (the two editor surfaces) are `CM6ParityShotTests`. Files are
/// `s<NN>-<slug>-<palette>.png` in `$LORE_PARITY_DIR`.
///
/// SKIPPED unless `LORE_PARITY_DIR` is set (`make parity`), so the normal suite
/// pays nothing. Every input is fixed — names, sizes, dates, text — so two
/// runs on the same commit compare at 0 px; a new screen must keep that true.
@MainActor
final class LoreScreenSnapshotTests: XCTestCase {
    private var directory: URL!
    private var palettes: [ParityPalette] = []

    override func setUp() async throws {
        guard let directory = try parityOutputDirectory() else {
            throw XCTSkip("set LORE_PARITY_DIR (make parity) to write the parity screens")
        }
        self.directory = directory
        palettes = try parityPalettes()
    }

    // MARK: - S5 sidebar operation sheets

    func test_s05_sidebarOperationSheets() throws {
        try snap("s05-new-folder", CGSize(width: 460, height: 220)) { palette in
            NameSheet(
                title: "New Folder", text: .constant("Research"), theme: palette.theme,
                onConfirm: {}, onCancel: {})
        }
        try snap("s05-rename", CGSize(width: 460, height: 220)) { palette in
            NameSheet(
                title: "Rename “Plan.md”", text: .constant("Roadmap"), theme: palette.theme,
                onConfirm: {}, onCancel: {})
        }
        let ops = SidebarOperations(store: makeStore())
        let message = ops.trashMessage(for: row("/Parity Vault/Projects/Plan.md", "Plan"))
        try snap("s05-trash-confirm", CGSize(width: 640, height: 420)) { _ in
            Color.clear.ainkradConfirmDialog(
                isPresented: .constant(true), title: "Move to Trash", message: message,
                confirmTitle: "Move to Trash", isDestructive: true
            ) {}
        }
    }

    // MARK: - S6 rename preview

    func test_s06_renamePreviewSheet() throws {
        let vault = URL(fileURLWithPath: "/Parity Vault")
        let plan = RenamePlan(
            source: vault.appendingPathComponent("Projects/Plan.md"),
            destination: vault.appendingPathComponent("Projects/Roadmap.md"),
            edits: [
                LinkEdit(file: vault.appendingPathComponent("Index.md"), oldTarget: "Plan", newTarget: "Roadmap"),
                LinkEdit(
                    file: vault.appendingPathComponent("Projects/Design Doc.md"), oldTarget: "Plan",
                    newTarget: "Roadmap"),
                LinkEdit(
                    file: vault.appendingPathComponent("Archive/Old Note.md"), oldTarget: "Plan#Goals",
                    newTarget: "Roadmap#Goals"),
            ])
        let preview = RenamePreview(document: plan, isMove: false)
        try snap("s06-rename-preview", CGSize(width: 460, height: 360)) { palette in
            RenamePreviewSheet(
                preview: preview, report: nil, theme: palette.theme, onConfirm: {}, onCancel: {})
        }
        let refused = RenamePreview(
            document: RenamePlan(
                source: plan.source, destination: plan.destination, edits: [],
                refusal: "“Roadmap.md” already exists in this folder."),
            isMove: false)
        try snap("s06-rename-refused", CGSize(width: 460, height: 200)) { palette in
            RenamePreviewSheet(
                preview: refused, report: nil, theme: palette.theme, onConfirm: {}, onCancel: {})
        }
    }

    // MARK: - S7 header bar, actions menu, mentions

    func test_s07_documentHeaderActionsAndMentions() throws {
        let vault = try makeVault()
        let store = makeStore()
        try store.setVaultRootForTesting(vault)
        let planURL = vault.appendingPathComponent("Projects/Plan.md")
        store.open(url: planURL)
        let session = try XCTUnwrap(store.selectedTab)
        let ops = SidebarOperations(store: store)
        let planRow = row(planURL.path, "Plan")

        try snap("s07-header-bar", CGSize(width: 900, height: 48)) { palette in
            DocumentHeaderBar(
                session: session, store: store, theme: palette.theme, row: planRow, ops: ops,
                showingActions: .constant(false))
        }
        try snap("s07-actions-menu", CGSize(width: 300, height: 220)) { palette in
            DocumentActionsMenu(
                items: loreRowMenuItems(row: planRow, ops: ops, store: store), theme: palette.theme,
                onDismiss: {}
            )
            .padding(AinkradSpacing.lg)
        }
        let design = row("/Parity Vault/Projects/Design Doc.md", "Design Doc")
        let index = row("/Parity Vault/Index.md", "Index")
        try snap("s07-mentions", CGSize(width: 380, height: 420)) { palette in
            DocumentMentionsList(
                backlinks: [
                    LoreStore.Backlink(id: design.path, row: design, context: "Scope follows [[Plan]] closely."),
                    LoreStore.Backlink(id: index.path, row: index, context: "- [[Plan]] — this quarter"),
                ],
                unresolved: [UnresolvedLink(rawTarget: "Budget 2027", syntax: .wikilink)],
                related: [row("/Parity Vault/Archive/Old Note.md", "Old Note")],
                suggestedTags: ["planning"],
                theme: palette.theme, onOpen: { _ in }, onCreate: { _ in }
            )
            .padding(AinkradSpacing.lg)
        }
    }

    // MARK: - S9 read-only viewers

    func test_s09_readOnlyViewers() throws {
        // The PDF viewer is Tier B: `PDFView` draws its pages in asynchronous
        // tiles that `cacheDisplay` never captures (the shot came out blank),
        // and QuickLook attachments render out of process. Both are shot live.
        let vault = try makeVault()
        let rtf = vault.appendingPathComponent("Attachments/Brief.rtf")
        try writeRTF(to: rtf)
        let size = CGSize(width: 720, height: 560)

        let richText = try RichTextEngine.load(rtf)
        try snap("s09-rich-text", size) { palette in
            richText.makeEditor(EditorContext(theme: palette.theme, onChange: {}))
        }
        try snap("s09-error-card", size) { palette in
            DocumentErrorCard(
                url: URL(fileURLWithPath: "/Parity Vault/Attachments/Budget.numbers"),
                message: "Lore couldn't open this document.", theme: palette.theme)
        }
        try snap("s09-render-gate", size) { palette in
            EmptyExtractionFallbackView(
                url: URL(fileURLWithPath: "/Parity Vault/Attachments/Page.html"), theme: palette.theme)
        }
    }

    // MARK: - S10 banners

    func test_s10_banners() throws {
        let vault = try makeVault()
        let store = makeStore()
        try store.setVaultRootForTesting(vault)
        store.open(url: vault.appendingPathComponent("Projects/Plan.md"))
        let session = try XCTUnwrap(store.selectedTab)
        let failure = NSError(
            domain: "parity", code: 28,
            userInfo: [NSLocalizedDescriptionKey: "The volume is out of space."])
        let size = CGSize(width: 720, height: 140)
        func pane(_ palette: ParityPalette) -> DocumentPane {
            DocumentPane(
                store: store, session: session, theme: palette.theme, ops: SidebarOperations(store: store),
                onOutlineChange: { _ in }, onScrollHandler: { _ in }, onTagClick: { _ in },
                mentionsRequest: .constant(false), showingActions: .constant(false), actionItems: [])
        }
        try snap("s10-save-error", size) { pane($0).saveErrorBanner(failure) }
        try snap("s10-external-change", size) { pane($0).conflictBanner }
        try snap("s10-read-only", size) { pane($0).readOnlyBanner }
    }

    // MARK: - S11 import

    func test_s11_import() async throws {
        let vault = try makeVault()
        let size = CGSize(width: 620, height: 460)
        let picker = ImportCoordinator(vaultRoot: vault)
        try snap("s11-import-entry", size) { palette in
            ImportEntryView(coordinator: picker, theme: palette.theme, onClose: {})
        }

        let obsidian = ImportCoordinator(vaultRoot: vault)
        await obsidian.scan(StubSource<ObsidianStub>(items: obsidianItems), sourceRoot: nil)
        try snap("s11-import-obsidian", size) { palette in
            ImportEntryView(coordinator: obsidian, theme: palette.theme, onClose: {})
        }

        let notes = ImportCoordinator(vaultRoot: vault)
        await notes.scan(StubSource<AppleNotesStub>(items: appleNotesItems), sourceRoot: nil)
        try snap("s11-import-apple-notes", size) { palette in
            ImportEntryView(coordinator: notes, theme: palette.theme, onClose: {})
        }

        let denied = ImportCoordinator(vaultRoot: vault)
        await denied.scan(
            StubSource<AppleNotesStub>(items: [], deniedDetail: "Lore is not allowed to control Notes."),
            sourceRoot: nil)
        try snap("s11-import-permission", size) { palette in
            ImportEntryView(coordinator: denied, theme: palette.theme, onClose: {})
        }
    }

    // MARK: - S12 shortcuts reference

    func test_s12_shortcutsReference() throws {
        try snap("s12-shortcuts", CGSize(width: 560, height: 1100)) { palette in
            LoreShortcutsReference(theme: palette.theme)
                .padding(AinkradSpacing.lg)
                .background(palette.tokens.surface)
        }
    }

    // MARK: - plumbing

    /// Shoots one screen under every palette and writes `<slug>-<palette>.png`.
    private func snap<V: View>(
        _ slug: String, _ size: CGSize, settleFor seconds: TimeInterval = 0.5,
        _ make: (ParityPalette) -> V
    ) throws {
        for palette in palettes {
            let rep = try shoot(make(palette), size: size, palette: palette, settleFor: seconds)
            XCTAssertGreaterThan(
                distinctRowCount(of: rep), 2, "\(slug) rendered nothing under \(palette.id)")
            try write(rep, to: directory.appendingPathComponent("\(slug)-\(palette.id).png"))
        }
    }

    private func makeStore() -> LoreStore {
        LoreStore(
            documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("lore-parity-\(UUID().uuidString).sqlite"))
    }

    /// A fixed row. `updated` is a constant: nothing on screen may depend on
    /// the clock, or the same commit renders differently tomorrow.
    private func row(_ path: String, _ title: String) -> IndexRow {
        IndexRow(
            path: URL(fileURLWithPath: path), id: title.lowercased(), title: title, tags: [],
            aliases: [], updated: Date(timeIntervalSince1970: 1_790_000_000),
            type: MarkdownEngine.identifier, properties: [])
    }

    /// `<tmp>/<uuid>/Parity Vault`. Only the vault's own name reaches the
    /// screen (the breadcrumb), so the random parent never shows.
    private func makeVault() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-parity-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let vault = parent.appendingPathComponent("Parity Vault")
        for folder in ["Projects", "Archive", "Attachments"] {
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "---\nid: plan\ntitle: Plan\n---\n# Plan\n\nGoals for the quarter.\n".write(
            to: vault.appendingPathComponent("Projects/Plan.md"), atomically: true, encoding: .utf8)
        return vault
    }
}

// MARK: - fixed fixture data

private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

private protocol StubIdentity { static var identifier: String { get } }
private enum ObsidianStub: StubIdentity { static let identifier = ObsidianSource.identifier }
private enum AppleNotesStub: StubIdentity { static let identifier = AppleNotesScriptSource.identifier }

/// A source with a fixed answer. Its identifier is the real source's, which is
/// what `ImportCoordinator` keys the Apple Notes permission state on.
private struct StubSource<Identity: StubIdentity>: ImportSource {
    static var identifier: String { Identity.identifier }
    let items: [ImportItem]
    var deniedDetail: String?

    func scan() async throws -> [ImportItem] {
        if let deniedDetail { throw ImportSourceError.permissionDenied(deniedDetail) }
        return items
    }
}

private func item(
    _ sourceID: String, _ title: String, _ body: ImportBody, folder: [String] = [],
    fidelity: [FidelityWarning] = [], kind: ImportItemKind = .note
) -> ImportItem {
    ImportItem(
        sourceID: sourceID, title: title, body: body, attachments: [], folderPath: folder,
        created: fixedDate, modified: fixedDate, fidelity: fidelity, kind: kind)
}

private let obsidianItems = [
    item("Inbox.md", "Inbox", .markdown("# Inbox\n")),
    item("Projects/Plan.md", "Plan", .markdown("See [[Design Doc]]."), folder: ["Projects"]),
    item(
        "Projects/Dashboard.md", "Dashboard", .markdown("```dataview\nTABLE file.mtime\n```"),
        folder: ["Projects"],
        fidelity: [FidelityWarning(kind: .pluginSyntax, detail: "Dataview query copied as text")]),
    item("Media/diagram.png", "diagram.png", .markdown(""), folder: ["Media"], kind: .file),
]

private let appleNotesItems = [
    item("x-coredata://notes/p1", "Groceries", .html("<div>Milk</div>"), folder: ["iCloud", "Notes"]),
    item(
        "x-coredata://notes/p2", "Trip ideas", .html("<div>Lisbon</div>"), folder: ["iCloud", "Travel"],
        fidelity: [FidelityWarning(kind: .attachmentUnavailable, detail: "1 attachment could not be read")]),
    item(
        "x-coredata://notes/p3", "Locked note", .html(""), folder: ["iCloud", "Notes"],
        fidelity: [FidelityWarning(kind: .lockedNote, detail: "Locked notes are left alone")]),
]

private func writeRTF(to url: URL) throws {
    let text = NSMutableAttributedString(
        string: "Project brief\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
    text.append(
        NSAttributedString(
            string: "A rich-text document, shown as authored: its own fonts and colours.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemBlue]))
    let data = try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    try data.write(to: url)
}
