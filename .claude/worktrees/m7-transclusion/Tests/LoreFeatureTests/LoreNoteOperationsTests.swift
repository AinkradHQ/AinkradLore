import Testing
import Foundation
import AinkradAppKit
@testable import LoreFeature

private final class MemoryDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

/// A temp vault. **Never the user's real vault.**
@MainActor
private func makeVault() async throws -> (URL, LoreNoteOperations, LoreStore) {
    // Nested one level deeper than the shared temp directory ON PURPOSE.
    // `createRejectsTitlesThatEscapeTheVault` snapshots the vault's PARENT
    // before and after, and a parent shared with every other suite's temp
    // directories puts their files in that diff — turning the one test that
    // proves a title cannot write outside the vault into a flaky one.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-ops-\(UUID())", isDirectory: true)
        .appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(documents: MemoryDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
    try store.setVaultRootForTesting(root)
    // Activation starts a background rescan of the (empty) vault. Let it finish
    // before the test writes anything, or its `replaceAll` can land afterwards
    // and wipe the notes the test just created.
    await store.settleForTesting()
    return (root, LoreNoteOperations(store: store), store)
}

@MainActor
private func run(_ operations: LoreNoteOperations,
                 _ object: [String: Any]) async -> (text: String, isError: Bool) {
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let result = await operations.run(json)
    return (result.text, result.isError)
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoreNoteOperationsTests {

    // MARK: - the fresh-install case
    //
    // A store whose bookmark never resolved has no vault. Left unhandled this
    // is the WORST state to debug from the assistant's side, because the
    // underlying APIs disagree about how to fail: `search` returns an empty
    // array, `create`/`save`/`delete` throw `LoreError.noVault`, and
    // `allTags`/`subfolders` return empty arrays. "No notes match" is a lie
    // when the truth is "there is no vault".

    private func vaultlessOperations() -> LoreNoteOperations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-novault-\(UUID())", isDirectory: true)
        let store = LoreStore(documents: MemoryDocs(),
                              indexPath: root.appendingPathComponent(".index.sqlite"))
        return LoreNoteOperations(store: store)
    }

    /// Walks the WHOLE published table rather than naming operations, so a tool
    /// added later cannot quietly skip the check.
    @Test func everyPublishedOperationFailsClearlyWithNoVault() async {
        let operations = vaultlessOperations()
        for tool in LoreMCPServer.tools {
            let outcome = await run(operations, ["operation": tool.operation, "note": "anything"])
            #expect(outcome.isError, "\(tool.name) did not report an error without a vault")
            #expect(outcome.text == LoreNoteOperations.noVaultMessage,
                    "\(tool.name) gave a confusing message without a vault: \(outcome.text)")
        }
    }

    @Test func theVaultResourceSaysSoWhenThereIsNoVault() {
        #expect(vaultlessOperations().vaultSummary() == LoreNoteOperations.noVaultMessage)
    }

    @Test func theVaultResourceReportsTheRootAndCounts() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Counted")
        note.tags = ["alpha"]
        try store.save(note)

        let summary = operations.vaultSummary()
        #expect(summary.contains(root.path))
        #expect(summary.contains("notes: 1"))
        #expect(summary.contains("tags: 1"))
    }

    // MARK: - read

    @Test func searchFindsNotesByBody() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Findable")
        note.body = "a distinctive haystack"
        try store.save(note)

        let outcome = await run(operations, ["operation": "search", "query": "haystack"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains(note.id))
        #expect(outcome.text.contains("Findable"))
    }

    @Test func anEmptyQueryListsRecentNotesRatherThanNothing() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.create(title: "Browseable")

        let outcome = await run(operations, ["operation": "search"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("Browseable"))
    }

    /// `IndexRow.type` now spans markdown notes AND plaintext/source files
    /// (Task 5's generalized index). `search_notes` is documented as
    /// searching notes; silently surfacing a `.txt` match would be the tool
    /// lying about its own contract.
    @Test func searchOnlyReturnsMarkdownNotes() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "A")
        note.body = "needle"
        try store.save(note)
        try "needle in plain text".write(
            to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try store.rebuild()

        let outcome = await run(operations, ["operation": "search", "query": "needle"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains(note.id))
        #expect(outcome.text.contains("b.txt") == false,
                "note tools must not claim plain-text files are notes")
    }

    @Test func searchReportsNoMatchesWithoutErroring() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "search", "query": "nothingatall"])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("No notes match"))
    }

    /// `resolve` backs `read_note`/`save_note`/`delete_note`; it must not
    /// resolve a non-markdown row even when the caller's identifier happens to
    /// match one exactly (its path, here).
    @Test func readCannotResolveANonMarkdownFile() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("notes.txt")
        try "plain text, not a note".write(to: textURL, atomically: true, encoding: .utf8)
        try store.rebuild()

        let outcome = await run(operations, ["operation": "read", "note": textURL.path])
        #expect(outcome.isError)
        #expect(outcome.text.contains("search_notes"))
    }

    /// Unclaimed files (`.pdf`, `.xlsx`) now appear in `store.rows` so the
    /// sidebar does not lie about the vault. The note tools must be unmoved by
    /// that: they are type-filtered to markdown and stay so.
    @Test func noteToolsIgnoreUnclaimedFileTypes() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Real Note")
        note.body = "zorkmid body"
        try store.save(note)
        try "%PDF-1.4 zorkmid".write(to: root.appendingPathComponent("paper.pdf"),
                                     atomically: true, encoding: .utf8)
        try "sheet zorkmid".write(to: root.appendingPathComponent("book.xlsx"),
                                  atomically: true, encoding: .utf8)
        try store.rebuild()
        #expect(store.rows.count == 3, "precondition: unclaimed rows are indexed")

        let listed = await run(operations, ["operation": "search"])
        #expect(listed.isError == false)
        #expect(listed.text.contains("Real Note"))
        #expect(listed.text.contains("paper.pdf") == false)
        #expect(listed.text.contains("book.xlsx") == false)

        let searched = await run(operations, ["operation": "search", "query": "zorkmid"])
        #expect(searched.text.contains("paper.pdf") == false)
        #expect(searched.text.contains("book.xlsx") == false)

        let resolved = await run(operations,
                                 ["operation": "read",
                                  "note": root.appendingPathComponent("book.xlsx").path])
        #expect(resolved.isError)
    }

    @Test func readReturnsTitleTagsAndBody() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Readable")
        note.tags = ["one", "two"]
        note.body = "the body text"
        try store.save(note)

        let outcome = await run(operations, ["operation": "read", "note": note.id])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("title: Readable"))
        #expect(outcome.text.contains("tags: one, two"))
        #expect(outcome.text.contains("the body text"))
        // Vault-relative, not the user's absolute home path.
        #expect(outcome.text.contains("path: \(note.path.lastPathComponent)"))
    }

    /// `read_note` is advertised `readOnly`, and that has to be true of the
    /// STORE's state as well as the disk. `LoreStore.load` re-baselines the
    /// external-change mtime, so using it here would disarm the guard that
    /// stops an open editor's autosave destroying an outside edit — a read tool
    /// silently enabling data loss. The operations layer parses the file
    /// directly instead, and this pins that.
    @Test func readingDoesNotDisarmTheExternalChangeGuard() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Guarded")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let read = await run(operations, ["operation": "read", "note": note.id])
        #expect(read.isError == false)
        #expect(store.externalChangeDetected(for: note),
                "read_note re-baselined the mtime — the external-change guard is now disarmed")
    }

    @Test func listTagsAndFoldersAnswerFromTheVault() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Tagged")
        note.tags = ["zeta", "alpha"]
        try store.save(note)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)

        let tags = await run(operations, ["operation": "listTags"])
        #expect(tags.text == "alpha\nzeta")
        let folders = await run(operations, ["operation": "listFolders"])
        #expect(folders.text == "inbox")
    }

    // MARK: - write

    @Test func createWritesTitleBodyAndTags() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await run(operations, [
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

        let outcome = await run(operations, [
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

        let outcome = await run(operations, [
            "operation": "save", "note": note.id, "body": "mine again",
        ])
        #expect(outcome.isError)
        #expect(outcome.text.contains("save_note_overwriting"))
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("theirs"),
                "the outside edit was destroyed by a refused save")
    }

    @Test func saveWithTheInjectedFlagOverwritesTheExternalChange() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Overwritten")
        note.body = "mine"
        try store.save(note)
        try externallyEditFile(note.path, to: "theirs")

        let outcome = await run(operations, [
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
        #expect(FileManager.default.fileExists(atPath: note.path.path) == false,
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

    // MARK: - identifier handling

    @Test func anAbsolutePathIdentifiesANoteToo() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try store.create(title: "ByPath")

        let outcome = await run(operations, ["operation": "read", "note": note.path.path])
        #expect(outcome.isError == false)
        #expect(outcome.text.contains("title: ByPath"))
    }

    @Test func anUnknownIdentifierIsAnActionableError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "read", "note": "no-such-id"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("search_notes"))
    }

    @Test func aMissingIdentifierIsAnActionableError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "delete"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("\"note\""))
    }

    /// `tags: "a, b"` is ambiguous — one tag or two? Guessing would silently
    /// mangle metadata, so a non-array is ignored rather than coerced.
    @Test func aBareStringIsNotCoercedIntoATagList() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Tagless")
        note.tags = ["original"]
        try store.save(note)

        _ = await run(operations, ["operation": "save", "note": note.id, "tags": "a, b"])
        let row = try #require(store.rows.first { $0.id == note.id })
        #expect(row.tags == ["original"])
    }

    @Test func anUnknownOperationIsAnError() async throws {
        let (root, operations, _) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await run(operations, ["operation": "launchMissiles"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("unknown operation"))
    }
}

/// Rewrites a note's file behind the store's back and forces its mtime forward.
/// The explicit bump keeps the assertion on the guard rather than on filesystem
/// timestamp granularity.
private func externallyEditFile(_ url: URL, to body: String) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let head = text.components(separatedBy: "---").prefix(3).joined(separator: "---")
    try (head + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
}
