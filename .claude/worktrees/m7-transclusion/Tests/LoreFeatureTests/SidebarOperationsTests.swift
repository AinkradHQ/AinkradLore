import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

/// The sidebar's rename / move / trash flows, tested where the behaviour lives
/// rather than through a view host. Every case here is a review finding from an
/// earlier task that a SwiftUI-only test could not have caught.
@MainActor
final class SidebarOperationsTests: XCTestCase {

    private func vault(_ label: String = "ops") throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".idx.sqlite"))
        try s.setVaultRootForTesting(root)
        return (root, s)
    }

    private func row(_ s: LoreStore, _ name: String) throws -> IndexRow {
        try XCTUnwrap(s.rows.first { $0.path.lastPathComponent == name })
    }

    // MARK: - The preview is the whole safety net

    /// M1 HAS NO UNDO, so a plan the store already refused must never be
    /// reachable through a confirm button. Asserted on the value the button is
    /// built from, and on `confirm()` refusing to act.
    func test_refusedPlanCannotBeConfirmed() async throws {
        let (root, s) = try vault()
        try "---\nid: a\ntitle: A\n---\nx"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)

        ops.beginRename(try row(s, "a.md"))
        ops.nameText = "../escaped"
        ops.commitName()

        let preview = try XCTUnwrap(ops.preview)
        XCTAssertNotNil(preview.refusal)
        XCTAssertFalse(preview.canConfirm)
        ops.confirm()
        XCTAssertNil(ops.report, "a refused plan must not be applicable")
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appendingPathComponent("a.md").path))
    }

    func test_validRenameProducesAConfirmablePreviewNamingTheAffectedFiles() async throws {
        let (root, s) = try vault()
        try "---\nid: a\ntitle: A\n---\nsee [[Design]]"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "---\nid: d\ntitle: Design\n---\nx"
            .write(to: root.appendingPathComponent("Design.md"), atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)

        ops.beginRename(try row(s, "Design.md"))
        XCTAssertEqual(ops.nameText, "Design", "the prompt starts from the current name")
        ops.nameText = "Architecture"
        ops.commitName()

        let preview = try XCTUnwrap(ops.preview)
        XCTAssertTrue(preview.canConfirm)
        XCTAssertEqual(preview.editCount, 1)
        XCTAssertEqual(preview.files.map(\.lastPathComponent), ["a.md"])
        XCTAssertTrue(preview.summary.contains("1 link"), preview.summary)

        ops.confirm()
        let report = try XCTUnwrap(ops.report)
        XCTAssertTrue(report.isCompleteSuccess, "\(report.failed) \(report.skipped)")
        XCTAssertEqual(report.rewritten.map(\.lastPathComponent), ["a.md"])
    }

    /// A move out of the vault is refused BEFORE a plan exists: the store would
    /// move the file, but its inbound links have no vault-relative path to be
    /// rewritten to, so they would all break.
    func test_moveOutsideTheVaultIsRefusedWithAVisibleMessage() async throws {
        let (root, s) = try vault()
        try "---\nid: a\ntitle: A\n---\nx"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)

        ops.move(try row(s, "a.md"), toFolder: FileManager.default.temporaryDirectory)

        XCTAssertNil(ops.preview)
        XCTAssertEqual(ops.activeSheet, .message)
        XCTAssertTrue(try XCTUnwrap(ops.message).contains("outside the vault"),
                      ops.message ?? "")
    }

    // MARK: - A refused trash must be VISIBLE

    /// INHERITED REQUIREMENT. This was `try? store.trash(row)`: `trash` refuses
    /// when a tab holds unsaved edits it could not flush, so the user pressed
    /// Delete, the file stayed, and NOTHING said why.
    func test_refusedTrashSurfacesTheRefusalInsteadOfDoingNothingSilently() async throws {
        let (root, s) = try vault("ops-trash")
        let url = root.appendingPathComponent("gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let target = try row(s, "gone.md")
        s.open(target)
        let session = try XCTUnwrap(s.selectedTab)
        let engine = try XCTUnwrap(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit"
        session.markChanged()
        session.cancelPendingSave()

        // Drive the session into conflict, which is what makes the flush refuse.
        try await Task.sleep(for: .milliseconds(1100))
        try "---\nid: g\ntitle: Gone\n---\nsomebody else"
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try session.saveNow())

        let ops = SidebarOperations(store: s)
        ops.requestTrash(target)
        ops.confirmTrash()

        let message = try XCTUnwrap(ops.message, "the refusal was swallowed")
        XCTAssertTrue(message.contains("was not deleted"), message)
        XCTAssertTrue(message.contains("unsaved edits"), message)
        // ...and it tells the user how to clear it.
        XCTAssertTrue(message.contains("Resolve"), message)
        XCTAssertEqual(ops.activeSheet, .message)
        // The file and the unsaved text are both untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(session.isDirty)
    }

    func test_successfulTrashSurfacesNothingAndTheInboundCountIsStated() async throws {
        let (root, s) = try vault("ops-trash-ok")
        try "---\nid: a\ntitle: A\n---\nsee [[Gone]]"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let gone = root.appendingPathComponent("Gone.md")
        try "---\nid: g\ntitle: Gone\n---\nx".write(to: gone, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)
        let target = try row(s, "Gone.md")

        // The warning states the count, and promises no rewrite.
        let warning = ops.trashMessage(for: target)
        XCTAssertTrue(warning.contains("1 note link"), warning)
        XCTAssertTrue(warning.contains("stop resolving"), warning)

        ops.requestTrash(target)
        ops.confirmTrash()
        XCTAssertNil(ops.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    /// `LoreError.trashFailed` gets a sentence too, and that sentence promises
    /// the file was NOT permanently deleted — the fallback `trash` refuses to do.
    func test_trashFailedIsDescribedAndPromisesNoPermanentDelete() {
        let url = URL(fileURLWithPath: "/v/x.md")
        let target = IndexRow(path: url, id: "x", title: "X", tags: [], aliases: [],
                              updated: Date(), type: MarkdownEngine.identifier, properties: [])
        let text = SidebarOperations.describe(.trashFailed(url, "No .Trashes on the volume."),
                                              row: target)
        XCTAssertTrue(text.contains("No .Trashes"), text)
        XCTAssertTrue(text.contains("Nothing was deleted"), text)
    }

    // MARK: - Smoke

    func test_sheetsBuildInEveryState() throws {
        let theme = HostTheme(TestTokens.make())
        let plan = RenamePlan(source: URL(fileURLWithPath: "/v/Design.md"),
                              destination: URL(fileURLWithPath: "/v/Architecture.md"),
                              edits: [LinkEdit(file: URL(fileURLWithPath: "/v/A.md"),
                                               oldTarget: "Design", newTarget: "Architecture")])
        let preview = RenamePreview(document: plan, isMove: false)
        _ = RenamePreviewSheet(preview: preview, report: nil, theme: theme,
                               onConfirm: {}, onCancel: {})
        _ = RenamePreviewSheet(
            preview: preview,
            report: RenameReport(rewritten: [URL(fileURLWithPath: "/v/A.md")],
                                 skipped: [], failed: [], movedTo: plan.destination),
            theme: theme, onConfirm: {}, onCancel: {})
        _ = RenamePreviewSheet(
            preview: RenamePreview(document: RenamePlan(source: plan.source,
                                                        destination: plan.source, edits: [],
                                                        refusal: "Not a name."),
                                   isMove: false),
            report: nil, theme: theme, onConfirm: {}, onCancel: {})
        _ = NameSheet(title: "Rename", text: .constant("x"), theme: theme,
                      onConfirm: {}, onCancel: {})
        _ = MessageSheet(text: "nope", theme: theme, onDismiss: {})
    }

    /// A folder with no indexed documents still MOVES, so its preview must not
    /// claim there is nothing to do.
    func test_folderPreviewWithNoIndexedDocumentsStillDescribesTheMove() {
        let plan = FolderRenamePlan(source: URL(fileURLWithPath: "/v/Projects"),
                                    destination: URL(fileURLWithPath: "/v/Work"))
        let preview = RenamePreview(folder: plan)
        XCTAssertTrue(preview.canConfirm)
        XCTAssertTrue(preview.summary.contains("will still be renamed"), preview.summary)
        XCTAssertTrue(preview.summary.contains("does not index"), preview.summary)
    }

    // MARK: - New Folder reachability (M3.1 defect 1)

    /// `loreRootMenuItems` is the empty-space/root menu's whole content — the
    /// route this task adds for a vault with no subfolder yet, or every
    /// folder collapsed. Its one item must target the VAULT ROOT, not some
    /// other folder, or "New Folder" from empty space would create in the
    /// wrong place.
    func test_rootMenuNewFolderTargetsTheVaultRoot() throws {
        let (root, s) = try vault("root-menu")
        let ops = SidebarOperations(store: s)

        let items = loreRootMenuItems(root: root, ops: ops)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "New Folder…")

        items[0].action()
        XCTAssertEqual(ops.nameTarget, .newFolder(root))
    }

    /// `loreFolderMenuItems`'s New Folder item must target the FOLDER the menu
    /// was opened on, not the vault root — the same action from a folder row
    /// and from empty space must resolve to two different parents.
    func test_folderMenuNewFolderTargetsThatFolderNotTheRoot() throws {
        let (root, s) = try vault("folder-menu")
        let sub = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let ops = SidebarOperations(store: s)

        let items = loreFolderMenuItems(folder: sub, ops: ops)
        let newFolder = try XCTUnwrap(items.first { $0.title == "New Folder…" })

        newFolder.action()
        XCTAssertEqual(ops.nameTarget, .newFolder(sub))
        XCTAssertNotEqual(ops.nameTarget, .newFolder(root))
    }

    /// The folder menu's destructive item stays tagged as destructive after
    /// the move off raw `Button(role: .destructive)` and onto
    /// `AinkradMenuItem.isDestructive` — the kit reads that flag to apply the
    /// danger tint (`AinkradContextMenuRow.tint` in `AinkradContextMenu.swift`),
    /// so losing the flag would silently un-style Move to Trash.
    func test_folderMenuTrashItemIsMarkedDestructive() throws {
        let (root, s) = try vault("folder-menu-trash")
        let ops = SidebarOperations(store: s)

        let items = loreFolderMenuItems(folder: root, ops: ops)
        let trash = try XCTUnwrap(items.first { $0.title == "Move to Trash" })
        XCTAssertTrue(trash.isDestructive)
        XCTAssertFalse(items.contains { $0.title != "Move to Trash" && $0.isDestructive })
    }

    /// The document row menu drops Move to Trash for attachment rows (a
    /// pre-existing rule from `LoreRowMenu`, preserved across the move to
    /// `AinkradMenuItem`), and keeps it — marked destructive — for everything
    /// else.
    func test_rowMenuOmitsTrashForAttachmentsButKeepsItElsewhere() throws {
        let (_, s) = try vault("row-menu")
        let ops = SidebarOperations(store: s)
        let doc = IndexRow(path: URL(fileURLWithPath: "/v/a.md"), id: "a", title: "A",
                           tags: [], aliases: [], updated: Date(),
                           type: MarkdownEngine.identifier, properties: [])
        let attachment = IndexRow(path: URL(fileURLWithPath: "/v/a.pdf"), id: "b", title: "B",
                                  tags: [], aliases: [], updated: Date(),
                                  type: AttachmentEngine.identifier, properties: [])

        let docItems = loreRowMenuItems(row: doc, ops: ops)
        XCTAssertTrue(docItems.contains { $0.title == "Move to Trash" && $0.isDestructive })

        let attachmentItems = loreRowMenuItems(row: attachment, ops: ops)
        XCTAssertFalse(attachmentItems.contains { $0.title == "Move to Trash" })
    }

    // MARK: - Successes are not failures

    /// The bug this split exists to kill: `message` is rendered by
    /// `MessageSheet`, whose heading is the literal words "Not done". Creating
    /// a folder set `message`, so a SUCCESSFUL create told the user
    /// "Not done: Created “Projects”." — the opposite of what happened.
    func test_creatingAFolderReportsASuccessNotAFailure() async throws {
        let (root, s) = try vault("notice-folder")
        await s.settleForTesting()
        let ops = SidebarOperations(store: s)

        ops.beginNewFolder(in: root)
        ops.nameText = "Projects"
        ops.commitName()

        XCTAssertNil(ops.message, "a successful create must not raise the “Not done” sheet")
        XCTAssertEqual(ops.notice?.kind, .success)
        XCTAssertEqual(ops.notice?.text.contains("Projects"), true)
    }

    /// A create that genuinely FAILS still goes to the modal channel — the
    /// split is by weight, and an invalid name is something the user must fix.
    func test_aFailedFolderCreateStillRaisesTheSheet() async throws {
        let (root, s) = try vault("notice-folder-bad")
        await s.settleForTesting()
        let ops = SidebarOperations(store: s)

        ops.beginNewFolder(in: root)
        ops.nameText = "bad/name"
        ops.commitName()

        XCTAssertNotNil(ops.message)
        XCTAssertNil(ops.notice, "a failure must not be downgraded to a toast")
    }

    /// A confirmed delete reports success as a toast AND advertises the undo,
    /// which is the only place the ⌘Z affordance is discoverable.
    func test_aConfirmedTrashReportsSuccessAndOffersUndo() async throws {
        let (root, s) = try vault("notice-trash")
        try "---\nid: g\ntitle: G\n---\nx".write(
            to: root.appendingPathComponent("g.md"), atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)

        ops.requestTrash(try row(s, "g.md"))
        ops.confirmTrash()

        XCTAssertNil(ops.message, "a successful delete is not a refusal")
        XCTAssertEqual(ops.notice?.kind, .success)
        XCTAssertEqual(ops.notice?.text.contains("⌘Z"), true,
                       "the undo is unreachable if nothing mentions it")
        XCTAssertTrue(ops.canUndoTrash)
    }

    /// And the undo runs through the same channel, restoring the file.
    func test_undoLastTrashRestoresAndReportsIt() async throws {
        let (root, s) = try vault("notice-undo")
        let url = root.appendingPathComponent("back.md")
        try "---\nid: b\ntitle: B\n---\nx".write(to: url, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()
        let ops = SidebarOperations(store: s)

        ops.requestTrash(try row(s, "back.md"))
        ops.confirmTrash()
        ops.undoLastTrash()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(ops.message)
        XCTAssertEqual(ops.notice?.kind, .success)
        XCTAssertEqual(ops.notice?.text.contains("Restored"), true)
        XCTAssertFalse(ops.canUndoTrash, "the record must be consumed")
    }

    /// ⌘Z with nothing to undo is silent — not an error, and not a toast. An
    /// idle keystroke must not become an interruption.
    func test_undoWithNothingToUndoIsSilent() async throws {
        let (_, s) = try vault("notice-undo-empty")
        await s.settleForTesting()
        let ops = SidebarOperations(store: s)

        ops.undoLastTrash()

        XCTAssertNil(ops.message)
        XCTAssertNil(ops.notice)
    }
}
