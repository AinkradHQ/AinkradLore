import XCTest
@testable import LoreFeature
import AinkradAppKit

/// Wave 2 Lore fixes: FTS5 expression injection (search silently returning
/// nothing for ordinary input) and `save()` clobbering concurrent external
/// edits.
final class LoreSearchExpressionTests: XCTestCase {

    /// Every one of these threw an FTS5 syntax error when passed through raw.
    /// Because every call site uses `try?`, the error became "no matches" — so
    /// typing a colon made search look broken rather than erroring.
    func testOperatorCharactersAreTreatedAsText() throws {
        let cases = [
            "size: 3",          // ':' is FTS5's column filter
            "AND",              // bare boolean operator
            "OR",
            "NOT",
            "NEAR",
            "C++",
            "a-b",
            "(unclosed",
            "he said \"hi",     // unbalanced quote
            "^caret",
            "*star",
        ]
        for input in cases {
            let expression = try XCTUnwrap(LoreIndex.ftsExpression(for: input),
                                           "produced no expression for \(input)")
            // Every term must be a quoted literal, where FTS5 treats all
            // characters as data rather than syntax.
            XCTAssertTrue(expression.hasPrefix("\""), "unquoted term in: \(expression)")
        }
    }

    func testEmbeddedQuotesAreDoubled() throws {
        // FTS5 escapes `"` inside a string literal by doubling it. Anything
        // else terminates the literal early and the rest becomes syntax.
        let expression = try XCTUnwrap(LoreIndex.ftsExpression(for: "say\"hi"))
        XCTAssertEqual(expression, "\"say\"\"hi\"*")
    }

    func testMultipleTermsBecomeSeparatePrefixMatches() throws {
        let expression = try XCTUnwrap(LoreIndex.ftsExpression(for: "swift  concurrency"))
        XCTAssertEqual(expression, "\"swift\"* \"concurrency\"*")
    }

    func testEmptyAndWhitespaceQueriesProduceNoExpression() {
        // nil means "no filter" — the caller falls back to listing everything,
        // which is the correct behaviour for an empty search box.
        XCTAssertNil(LoreIndex.ftsExpression(for: ""))
        XCTAssertNil(LoreIndex.ftsExpression(for: "   \n\t "))
    }

    func testOrdinaryQueryIsUnchangedInMeaning() throws {
        let expression = try XCTUnwrap(LoreIndex.ftsExpression(for: "meeting"))
        XCTAssertEqual(expression, "\"meeting\"*", "prefix search must still work")
    }
}

@MainActor
final class LoreExternalChangeTests: XCTestCase {

    private func makeStore() throws -> (LoreStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(
            documents: FakeDocs(),
            indexPath: root.appendingPathComponent("index.sqlite"))
        try store.setVaultRootForTesting(root)
        return (store, root)
    }

    func testSaveRefusesToClobberAnExternalEdit() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = try store.create(title: "Shared")

        // Someone else edits the file — Obsidian, a sync client, or the
        // agent's edit_file. mtime granularity means we must not write in the
        // same instant.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "---\ntitle: Shared\n---\nEXTERNAL EDIT\n"
            .write(to: note.path, atomically: true, encoding: .utf8)

        var mine = note
        mine.body = "my local edit"
        XCTAssertThrowsError(try store.save(mine)) { error in
            guard case LoreError.externalChange = error else {
                return XCTFail("expected .externalChange, got \(error)")
            }
        }

        // The external edit survived — this is the whole point.
        let onDisk = try String(contentsOf: note.path, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("EXTERNAL EDIT"), "the external edit was destroyed")
    }

    func testExplicitOverwriteIsAllowed() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = try store.create(title: "Shared")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "---\ntitle: Shared\n---\nEXTERNAL\n".write(to: note.path, atomically: true, encoding: .utf8)

        var mine = note
        mine.body = "mine wins"
        // "Keep my version" from the conflict prompt.
        XCTAssertNoThrow(try store.save(mine, overwritingExternalChanges: true))
        XCTAssertTrue(try String(contentsOf: note.path, encoding: .utf8).contains("mine wins"))
    }

    func testNormalSaveStillWorks() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var note = try store.create(title: "Mine")
        note.body = "first edit"
        XCTAssertNoThrow(try store.save(note))
        note.body = "second edit"
        // Consecutive saves from the editor must not trip the conflict check —
        // `save` updates the known mtime each time.
        XCTAssertNoThrow(try store.save(note))
        XCTAssertTrue(try String(contentsOf: note.path, encoding: .utf8).contains("second edit"))
    }

    func testSaveSuppressesItsOwnWatcherEvent() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var note = try store.create(title: "Note")
        note.body = "text"
        try store.save(note)

        // The watcher fires on our own write. Handling it means a full rescan
        // of the whole vault on the main actor, per autosave keystroke.
        let before = store.rows
        store.handleVaultChange()
        XCTAssertEqual(store.rows, before, "self-write triggered a full rebuild")
    }
}

/// Wave 2: the whole-vault rescan was synchronous and on the MainActor —
/// and `LoreStore.init` runs from `LoreApp.makeRootView`, i.e. inside a SwiftUI
/// `body`. Opening Lore froze the UI for as long as the vault was large.
@MainActor
final class LoreRescanTests: XCTestCase {

    private func makeVault(noteCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<noteCount {
            try "---\ntitle: Note \(i)\ntags: [a]\n---\nbody \(i)\n"
                .write(to: root.appendingPathComponent("n\(i).md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func store(at root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    func testActivatingAVaultDoesNotBlockOnAFullScan() throws {
        let root = try makeVault(noteCount: 300)
        defer { try? FileManager.default.removeItem(at: root) }

        // This is the call that happens inside a SwiftUI body. It must return
        // promptly — the scan is handed to a background task.
        let started = Date()
        let s = try store(at: root)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "activate() blocked for \(elapsed)s on a 300-note vault")
        _ = s
    }

    func testBackgroundRebuildEventuallyPopulatesRows() async throws {
        let root = try makeVault(noteCount: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try store(at: root)

        // Poll rather than sleeping a fixed amount — the point is that it
        // completes, not how fast.
        var attempts = 0
        while s.rows.count < 50 && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        XCTAssertEqual(s.rows.count, 50)
    }

    func testSynchronousRebuildStillWorksAndPrunes() throws {
        let root = try makeVault(noteCount: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try store(at: root)

        try s.rebuild()
        XCTAssertEqual(s.rows.count, 5)

        // Deleting a file must drop its index row — the prune half of the
        // single-transaction replaceAll.
        try FileManager.default.removeItem(at: root.appendingPathComponent("n0.md"))
        try s.rebuild()
        XCTAssertEqual(s.rows.count, 4)
    }

    func testConcurrentVaultChangesCoalesceIntoOneRescan() async throws {
        let root = try makeVault(noteCount: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try store(at: root)

        // FSEvents delivers bursts (a `git checkout` in the vault is hundreds
        // of events). Each used to start its own full synchronous rescan.
        for _ in 0..<50 { s.startBackgroundRebuild() }

        var attempts = 0
        while s.rows.count < 20 && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        XCTAssertEqual(s.rows.count, 20, "burst of change events left the index wrong")
    }
}
