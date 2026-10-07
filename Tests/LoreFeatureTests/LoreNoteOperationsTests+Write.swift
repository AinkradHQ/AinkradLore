import AinkradAppKit
import Foundation
import Testing

@testable import LoreFeature

// The write operations, split from `LoreNoteOperationsTests.swift` to keep it
// under the 500-line ceiling. The helpers live there.
extension LoreNoteOperationsTests {
    // MARK: - write

    @Test func createWritesTitleBodyAndTags() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await run(
            operations,
            [
                "operation": "create", "title": "Made", "body": "fresh", "tags": ["x"],
            ])
        #expect(outcome.isError == false)
        let row = try #require(store.rows.first { $0.title == "Made" })
        #expect(row.tags == ["x"])
        #expect(try String(contentsOf: row.path, encoding: .utf8).contains("fresh"))
    }

    @Test func createRequiresATitle() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "create", "title": "  "])
        #expect(outcome.isError)
        #expect(outcome.text.contains("title"))
    }

    /// `create_note` is ungated, so a title reaching it may have come from a
    /// model that read untrusted content. Each of these titles would otherwise
    /// slug straight into a path component. The assertion is on the OUTCOME:
    /// nothing may appear anywhere outside the vault root.
    @Test func createRejectsTitlesThatEscapeTheVault() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        // The sibling directory `../../escape` and friends would land in.
        let outside = root.deletingLastPathComponent()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? [])

        for title in ["../../escape", "a/b", "..", ".hidden", "./x"] {
            let outcome = await run(operations, ["operation": "create", "title": title])
            #expect(outcome.isError, "\"\(title)\" was accepted")
            #expect(store.rows.isEmpty, "\"\(title)\" created an indexed note")
        }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? [])
        #expect(after.subtracting(before).isEmpty, "a file was written outside the vault")
        // And every note file that does exist is inside the vault root.
        #expect(VaultIndexCoordinator.scanVault(at: root).isEmpty)
    }

    @Test func createStillAcceptsAnOrdinaryTitle() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "create", "title": "My Note"])
        #expect(outcome.isError == false)
        let row = try #require(store.rows.first { $0.title == "My Note" })
        #expect(row.path.lastPathComponent == "my-note.md")
        #expect(row.path.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    /// The reason `save_note` can be classified non-destructive: an omitted
    /// field is left alone, so a call that only adds a tag cannot blank a body
    /// the model never read.
    @Test func savePatchesRatherThanReplacing() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Patched")
        note.body = "keep me"
        try store.save(note)

        let outcome = await run(
            operations,
            [
                "operation": "save", "note": note.id, "tags": ["added"],
            ])
        #expect(outcome.isError == false)
        let text = try String(contentsOf: note.path, encoding: .utf8)
        #expect(text.contains("keep me"), "an omitted body was blanked")
        #expect(text.contains("added"))
    }

    @Test func saveRefusesAnExternalChangeAndNamesTheOtherTool() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Contested")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let outcome = await run(
            operations,
            [
                "operation": "save", "note": note.id, "body": "mine again",
            ])
        #expect(outcome.isError)
        #expect(outcome.text.contains("save_note_overwriting"))
        #expect(
            try String(contentsOf: note.path, encoding: .utf8).contains("theirs"),
            "the outside edit was destroyed by a refused save")
    }

    @Test func saveWithTheInjectedFlagOverwritesTheExternalChange() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Overwritten")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let outcome = await run(
            operations,
            [
                "operation": "save", "note": note.id, "body": "mine again",
                "overwritingExternalChanges": true,
            ])
        #expect(outcome.isError == false)
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("mine again"))
    }

    @Test func deleteRemovesTheFileAndTheRow() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "Doomed")

        let outcome = await run(operations, ["operation": "delete", "note": note.id])
        #expect(outcome.isError == false)
        #expect(FileManager.default.fileExists(atPath: note.path.path) == false)
        #expect(store.rows.isEmpty)
    }

    /// `delete_note` used to call `LoreStore.delete`, which closed no tab and
    /// cancelled no pending save: an MCP delete could permanently unlink a file
    /// AND have the open tab's debounced autosave recreate it 500ms later. It
    /// goes through `trash` now, which owns both.
    @Test func deleteClosesAnOpenTabAndCancelsItsPendingSave() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "Doomed")
        try store.rebuild()
        let row = try #require(store.rows.first { $0.id == note.id })
        store.open(row)
        let session = try #require(store.selectedTab)
        let engine = try #require(session.engine as? MarkdownEngine)
        // An armed autosave: exactly what used to resurrect the file.
        engine.note.body = "would resurrect"
        session.markChanged()

        let outcome = await run(operations, ["operation": "delete", "note": note.id])
        #expect(outcome.isError == false)
        #expect(store.tabs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: note.path.path) == false)

        // Well past the 500ms autosave debounce.
        try await Task.sleep(for: .milliseconds(900))
        #expect(
            FileManager.default.fileExists(atPath: note.path.path) == false,
            "a pending autosave resurrected a trashed note")
    }

    /// The refusal reaches the agent through the existing error-reporting shape
    /// rather than as a thrown surprise.
    @Test func deleteReportsARefusalWhenATabHoldsUnsavedEdits() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "Contested")
        try store.rebuild()
        let row = try #require(store.rows.first { $0.id == note.id })
        store.open(row)
        let session = try #require(store.selectedTab)
        let engine = try #require(session.engine as? MarkdownEngine)
        engine.note.body = "unsaved edit"
        session.markChanged()
        session.cancelPendingSave()

        try await Task.sleep(for: .milliseconds(1100))
        try "---\nid: \(note.id)\ntitle: Contested\n---\nsomebody else"
            .write(to: note.path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try session.saveNow() }

        let outcome = await run(operations, ["operation": "delete", "note": note.id])
        #expect(outcome.isError)
        #expect(outcome.text.contains("unsaved edits"))
        #expect(FileManager.default.fileExists(atPath: note.path.path))
        #expect(store.tabs.count == 1)
    }
}
