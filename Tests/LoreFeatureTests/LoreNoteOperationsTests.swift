import AinkradAppKit
import Foundation
import Testing

@testable import LoreFeature

extension LoreNoteOperationsTests {
    final class MemoryDocs: PluginDocumentStore {
        private var store: [String: Data] = [:]
        func data(forKey key: String) -> Data? { store[key] }
        func setData(_ data: Data?, forKey key: String) { store[key] = data }
    }

    /// A temp vault. **Never the user's real vault.**
    @MainActor
    func makeVault() async throws -> (URL, LoreNoteOperations, LoreStore) {
        // Nested one level deeper than the shared temp directory ON PURPOSE.
        // `createRejectsTitlesThatEscapeTheVault` snapshots the vault's PARENT
        // before and after, and a parent shared with every other suite's temp
        // directories puts their files in that diff — turning the one test that
        // proves a title cannot write outside the vault into a flaky one.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-ops-\(UUID())", isDirectory: true)
            .appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(
            documents: MemoryDocs(),
            indexPath: root.appendingPathComponent(".index.sqlite"))
        try store.setVaultRootForTesting(root)
        // Activation starts a background rescan of the (empty) vault. Let it finish
        // before the test writes anything, or its `replaceAll` can land afterwards
        // and wipe the notes the test just created.
        await store.settleForTesting()
        return (root, LoreNoteOperations(store: store), store)
    }

    @MainActor
    func run(
        _ operations: LoreNoteOperations,
        _ object: [String: Any]
    ) async -> (text: String, isError: Bool) {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let result = await operations.run(json)
        return (result.text, result.isError)
    }

    /// Rewrites a note's file behind the store's back and forces its mtime forward.
    /// The explicit bump keeps the assertion on the guard rather than on filesystem
    /// timestamp granularity.
    func externallyEditFile(_ url: URL, to body: String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let head = text.components(separatedBy: "---").prefix(3).joined(separator: "---")
        try (head + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    }
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
        let store = LoreStore(
            documents: MemoryDocs(),
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
            #expect(
                outcome.text == LoreNoteOperations.noVaultMessage,
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
        #expect(
            outcome.text.contains("b.txt") == false,
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

    /// Non-markdown files (`.pdf`, `.png`) appear in `store.rows` so the
    /// sidebar does not lie about the vault. The note tools must be unmoved by
    /// that: they are type-filtered to markdown and stay so.
    @Test func noteToolsIgnoreUnclaimedFileTypes() async throws {
        let (root, operations, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try store.create(title: "Real Note")
        note.body = "zorkmid body"
        try store.save(note)
        try "%PDF-1.4 zorkmid".write(
            to: root.appendingPathComponent("paper.pdf"),
            atomically: true, encoding: .utf8)
        try "pixels zorkmid".write(
            to: root.appendingPathComponent("image.png"),
            atomically: true, encoding: .utf8)
        try store.rebuild()
        #expect(store.rows.count == 3, "precondition: non-markdown rows are indexed")

        let listed = await run(operations, ["operation": "search"])
        #expect(listed.isError == false)
        #expect(listed.text.contains("Real Note"))
        #expect(listed.text.contains("paper.pdf") == false)
        #expect(listed.text.contains("image.png") == false)

        let searched = await run(operations, ["operation": "search", "query": "zorkmid"])
        #expect(searched.text.contains("paper.pdf") == false)
        #expect(searched.text.contains("image.png") == false)

        let resolved = await run(
            operations,
            [
                "operation": "read",
                "note": root.appendingPathComponent("image.png").path,
            ])
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
        #expect(
            store.externalChangeDetected(for: note),
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
