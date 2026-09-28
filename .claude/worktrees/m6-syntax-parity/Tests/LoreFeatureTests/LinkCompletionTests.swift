import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

final class LinkCompletionTests: XCTestCase {
    func test_detectsPrefixAfterOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[Des", caret: 9), "Des")
    }

    func test_returnsEmptyPrefixImmediatelyAfterBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "see [[", caret: 6), "")
    }

    func test_nilWhenLinkIsAlreadyClosed() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "see [[Design]] x", caret: 16))
    }

    func test_nilWhenNoBracketsBeforeCaret() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "plain text", caret: 5))
    }

    func test_stopsAtNewline() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[\nDesign", caret: 9))
    }

    func test_usesTheNearestOpenBrackets() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "[[A]] and [[B", caret: 13), "B")
    }

    /// The index-based rewrite must keep working on multi-scalar characters,
    /// where a Character offset and a UTF-16 offset disagree.
    func test_prefixWithMultiScalarCharacters() {
        XCTAssertEqual(LinkCompletionContext.activePrefix(in: "[[👍a", caret: 4), "👍a")
    }

    func test_prefixIgnoresAnOutOfRangeCaret() {
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[A", caret: 99))
        XCTAssertNil(LinkCompletionContext.activePrefix(in: "[[A", caret: -1))
    }

    // MARK: - Click-to-open span detection

    func test_targetUnderCaretInsideSpan() {
        XCTAssertEqual(LinkCompletionContext.target(in: "see [[Design]] x", at: 8), "Design")
    }

    func test_targetAtSpanEdges() {
        // Just inside the opening brackets and just before the closing ones.
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 2), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 8), "Design")
    }

    /// The brackets are part of the link as far as the user is concerned, so
    /// clicking them opens it too.
    func test_targetOnTheBracketGlyphsThemselves() {
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 0), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 1), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design]]", at: 9), "Design")
        XCTAssertEqual(LinkCompletionContext.target(in: "x [[Design]] y", at: 2), "Design")
    }

    func test_targetNilOutsideAnySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "see [[Design]] x", at: 15))
        XCTAssertNil(LinkCompletionContext.target(in: "plain text", at: 3))
    }

    func test_targetDoesNotCrossLines() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[Design\n]] x", at: 4))
    }

    func test_targetKeepsRawAliasAndHeadingSyntax() {
        XCTAssertEqual(LinkCompletionContext.target(in: "[[Design#Goals|why]]", at: 5),
                       "Design#Goals|why")
    }

    func test_targetNilForEmptySpan() {
        XCTAssertNil(LinkCompletionContext.target(in: "[[]]", at: 2))
    }

    // MARK: - documentName

    func test_documentNameStripsAliasAndFragment() {
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design#Goals|why"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design|why"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Design#Goals"), "Design")
        XCTAssertEqual(LinkCompletionContext.documentName(of: "Projects/Design"),
                       "Projects/Design")
    }

    // MARK: - Selection state

    /// The list is typed on `LinkCompletionItem` rather than `IndexRow` since
    /// the popup gained a "Create …" row — there is no `IndexRow` for a
    /// document that does not exist yet. These selection rules are unchanged;
    /// only the element type is.
    private func rows(_ n: Int) -> [LinkCompletionItem] {
        (0..<n).map { i in
            .document(IndexRow(path: URL(fileURLWithPath: "/v/\(i).md"), id: "\(i)",
                               title: "T\(i)", tags: [], aliases: [], updated: Date(),
                               type: "markdown", properties: []))
        }
    }

    func test_selectionStartsAtTheTop() {
        let three = rows(3)
        var s = LinkCompletionSelection()
        s.update(to: three)
        XCTAssertEqual(s.index, 0)
        XCTAssertEqual(s.current, three[0])
    }

    func test_selectionClampsAtBothEnds() {
        var s = LinkCompletionSelection()
        s.update(to: rows(3))
        s.move(by: -1)
        XCTAssertEqual(s.index, 0, "up at the top must not wrap to the bottom")
        s.move(by: 5)
        XCTAssertEqual(s.index, 2, "down past the end must not wrap to the top")
    }

    /// The highlight may never point past a row the list can actually show.
    func test_selectionClampsToTheVisibleRowLimit() {
        var s = LinkCompletionSelection()
        s.update(to: rows(20))
        s.move(by: 50)
        XCTAssertEqual(s.index, LinkCompletionView.maxRows - 1)
        XCTAssertEqual(s.visibleCount, LinkCompletionView.maxRows)
    }

    func test_changedMatchesResetTheHighlight() {
        let five = rows(5)
        var s = LinkCompletionSelection()
        s.update(to: five)
        s.move(by: 3)
        XCTAssertEqual(s.index, 3)
        s.update(to: Array(five.dropFirst()))
        XCTAssertEqual(s.index, 0, "a different match set must not keep the old highlight")
    }

    func test_identicalMatchesKeepTheHighlight() {
        let five = rows(5)
        var s = LinkCompletionSelection()
        s.update(to: five)
        s.move(by: 2)
        s.update(to: five)
        XCTAssertEqual(s.index, 2)
    }

    func test_emptySelectionHasNoCurrentRow() {
        var s = LinkCompletionSelection()
        s.update(to: rows(3))
        s.move(by: 2)
        s.clear()
        XCTAssertNil(s.current)
        XCTAssertEqual(s.index, 0)
        s.move(by: 1)
        XCTAssertEqual(s.index, 0, "moving with no matches must stay put")
    }

    // MARK: - View smoke test

    func test_completionViewBuilds() {
        _ = LinkCompletionView(matches: rows(12), selected: 3,
                               tokens: TestTokens.make()) { _ in }
        _ = LinkCompletionView(matches: [], selected: 0,
                               tokens: TestTokens.make()) { _ in }
    }
}

/// What a picked completion inserts has to resolve back to the document that
/// was picked. These go through the real `LinkResolver` on a real vault,
/// because the assertion that matters is "resolving the inserted text finds
/// this file again", not the literal string.
/// Every vault here holds MORE THAN ONE document: a single-file vault cannot
/// exhibit the failure that matters most, which is a link that resolves to the
/// wrong document rather than to none.
@MainActor
final class LinkInsertionRoundTripTests: XCTestCase {
    /// `path` is vault-relative and includes `.md`, so subfolders can be tested.
    private func vault(_ files: [(path: String, title: String)]) async throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-insert-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Quoted: these titles contain YAML-significant characters, and
            // quoting is also what preserves a deliberate trailing space.
            try "---\nid: \(UUID().uuidString)\ntitle: \"\(file.title)\"\n---\nbody"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        // Activation scans in the background; the rows are not there until it lands.
        await store.settleForTesting()
        return (root, store)
    }

    private func row(_ store: LoreStore, _ path: String) throws -> IndexRow {
        try XCTUnwrap(store.rows.first { $0.path.path.hasSuffix("/" + path) },
                      "\(path) not indexed; have \(store.rows.map(\.path.lastPathComponent))")
    }

    /// The assertion that matters: resolving what we inserted finds THIS file.
    @discardableResult
    private func assertRoundTrip(_ store: LoreStore, _ path: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> String {
        let wanted = try row(store, path)
        let inserted = store.linkTarget(for: wanted)
        XCTAssertEqual(store.resolveLink(inserted)?.standardizedFileURL,
                       wanted.path.standardizedFileURL,
                       "[[\(inserted)]] must resolve to \(path)", file: file, line: line)
        return inserted
    }

    // MARK: - Ambiguity: the wrong-document cases

    /// One document's TITLE equals another document's FILENAME. `byKey["design"]`
    /// holds both, and `resolve` returns the shortest path — so inserting the
    /// title silently linked to the other file.
    ///
    /// The longer filename is deliberate: `resolve` breaks the tie by SHORTEST
    /// path, so this is the arrangement where the titled document LOSES its own
    /// title and the bug is reachable.
    func test_titleCollidingWithAnotherFilename() async throws {
        let (_, store) = try await vault([("a-much-longer-name.md", "Design"),
                                          ("design.md", "Something")])
        XCTAssertEqual(store.resolveLink("Design")?.lastPathComponent, "design.md",
                       "premise: the bare title resolves to the OTHER document")
        let inserted = try assertRoundTrip(store, "a-much-longer-name.md")
        XCTAssertNotEqual(inserted, "Design", "the colliding title must not be inserted")
        try assertRoundTrip(store, "design.md")
    }

    /// Two documents sharing a basename in different folders. One of them wins
    /// the bare name; the other has to be written as a path.
    func test_sameBasenameInDifferentFolders() async throws {
        let (_, store) = try await vault([("A/design.md", "Design"),
                                          ("Bee/design.md", "Design")])
        let first = try assertRoundTrip(store, "A/design.md")
        let second = try assertRoundTrip(store, "Bee/design.md")
        XCTAssertNotEqual(first, second, "two documents cannot share one target")
    }

    /// Three-way: same title, same basename, three folders.
    func test_threeWayCollision() async throws {
        let (_, store) = try await vault([("A/design.md", "Design"),
                                          ("Bee/design.md", "Design"),
                                          ("Cee/design.md", "Design")])
        let targets = try ["A/design.md", "Bee/design.md", "Cee/design.md"]
            .map { try assertRoundTrip(store, $0) }
        XCTAssertEqual(Set(targets).count, 3, "each document needs its own target")
    }

    /// A title identical to ANOTHER document's title.
    func test_duplicateTitlesInTheSameFolder() async throws {
        let (_, store) = try await vault([("one.md", "Design"), ("two.md", "Design")])
        let a = try assertRoundTrip(store, "one.md")
        let b = try assertRoundTrip(store, "two.md")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Whitespace

    /// `LinkResolver` keys on the RAW title, so a stored `"Design "` is found
    /// by neither `Design` (not the key) nor `Design ` (`basename` trims).
    func test_titleWithATrailingSpace() async throws {
        let (_, store) = try await vault([("notes.md", "Design "), ("other.md", "Other")])
        let wanted = try row(store, "notes.md")
        XCTAssertEqual(wanted.title, "Design ", "frontmatter must preserve the space "
                       + "or this test is not exercising the case")
        let inserted = try assertRoundTrip(store, "notes.md")
        XCTAssertNotEqual(inserted, "Design")
    }

    func test_titleWithALeadingSpace() async throws {
        let (_, store) = try await vault([("notes.md", " Design"), ("other.md", "Other")])
        try assertRoundTrip(store, "notes.md")
    }

    // MARK: - Punctuation, now in a multi-document vault

    private func assertPunctuation(_ name: String, _ title: String) async throws {
        let (_, store) = try await vault([("\(name).md", title), ("decoy.md", "Decoy")])
        try assertRoundTrip(store, "\(name).md")
        try assertRoundTrip(store, "decoy.md")
    }

    func test_plainTitleRoundTrips() async throws {
        try await assertPunctuation("design", "Design")
    }

    /// `#` starts a fragment — `[[Sprint #3]]` resolves to "Sprint", or nothing.
    func test_titleWithHashRoundTrips() async throws {
        try await assertPunctuation("sprint-3", "Sprint #3")
    }

    /// `|` starts an alias.
    func test_titleWithPipeRoundTrips() async throws {
        try await assertPunctuation("either-or", "Either|Or")
    }

    /// `]]` would truncate the span outright.
    func test_titleWithClosingBracketsRoundTrips() async throws {
        try await assertPunctuation("brackets", "Odd]]Title")
    }

    func test_titleWithOpeningBracketsRoundTrips() async throws {
        try await assertPunctuation("opening", "Odd[[Title")
    }

    /// A `/` in a title would be read as a path suffix, which this file is not.
    func test_titleWithSlashRoundTrips() async throws {
        try await assertPunctuation("ratio", "A/B Test")
    }

    /// `basename` strips a trailing `.md`.
    func test_titleEndingInDotMDRoundTrips() async throws {
        try await assertPunctuation("readme-doc", "Readme.md")
    }

    func test_emptyTitleFallsBackToTheFilename() async throws {
        try await assertPunctuation("untitled-note", "")
    }

    /// A document in a subfolder with an unambiguous title still gets the
    /// readable target, not the path — verification must not make every link ugly.
    func test_unambiguousTitleIsPreferredOverThePath() async throws {
        let (_, store) = try await vault([("Projects/design-doc.md", "Design"),
                                          ("other.md", "Other")])
        XCTAssertEqual(try assertRoundTrip(store, "Projects/design-doc.md"), "Design")
    }

    /// And when the title is unusable but the filename is unambiguous, the
    /// filename is preferred over the longer path.
    func test_filenameIsPreferredOverThePath() async throws {
        let (_, store) = try await vault([("Projects/sprint-3.md", "Sprint #3"),
                                          ("other.md", "Other")])
        XCTAssertEqual(try assertRoundTrip(store, "Projects/sprint-3.md"), "sprint-3")
    }
}

/// The "this link points nowhere — create it?" path.
@MainActor
final class LinkCreateOnUnresolvedTests: XCTestCase {
    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-create-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// A real containment check: the note's directory must resolve to something
    /// under the vault root, not merely end in a same-named component.
    private func assertInsideVault(_ url: URL, _ root: URL,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(path.hasPrefix(rootPath + "/"),
                      "\(path) is not inside \(rootPath)", file: file, line: line)
    }

    /// `[[Projects/Design]]` used to fail silently: `create` slugged the whole
    /// thing to `projects/design` and wrote into a folder that did not exist.
    func test_createsTheSubfolderNamedByTheLink() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "Projects")
        XCTAssertEqual(note.path.deletingLastPathComponent().lastPathComponent, "Projects")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path.path))
        assertInsideVault(note.path, root)
        // The whole point: the link the user clicked now resolves.
        XCTAssertEqual(store.resolveLink("Projects/Design"), note.path)
    }

    /// Path arithmetic is not containment. A symlinked folder inside the vault
    /// — ordinary in Obsidian setups — would otherwise let
    /// `withIntermediateDirectories` follow it and write outside the root.
    func test_symlinkedSubfolderCannotEscapeTheVault() throws {
        let (root, store) = try store()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"),
                                                   withDestinationURL: outside)

        XCTAssertThrowsError(try store.create(title: "Design", in: "out")) { error in
            guard case .outsideVault(let url) = error as? LoreError ?? .noVault else {
                return XCTFail("expected .outsideVault, got \(error)")
            }
            // Compared by suffix, not by whole URL: the store canonicalises the
            // vault root (`/var` → `/private/var`), so the two spellings of the
            // same directory are not `==`.
            XCTAssertTrue(url.standardizedFileURL.path.hasSuffix("/out"),
                          "the error must name the offending directory, got \(url.path)")
        }
        XCTAssertTrue(try FileManager.default
            .contentsOfDirectory(atPath: outside.path).isEmpty,
                      "nothing may be written through the symlink")
    }

    /// A symlink that stays inside the vault is not an escape, and must work.
    func test_symlinkedSubfolderInsideTheVaultIsAllowed() throws {
        let (root, store) = try store()
        let real = root.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"),
                                                   withDestinationURL: real)
        let note = try store.create(title: "Design", in: "Alias")
        assertInsideVault(note.path, root)
    }

    func test_createsNestedSubfolders() throws {
        let (_, store) = try store()
        let note = try store.create(title: "Design", in: "A/B")
        XCTAssertEqual(store.resolveLink("A/B/Design"), note.path)
    }

    /// The folder name is untrusted document text.
    func test_subfolderCannotEscapeTheVault() throws {
        let (root, store) = try store()
        let note = try store.create(title: "Design", in: "../../etc")
        assertInsideVault(note.path, root)
    }

    /// `[[Design|why]]` names the document "Design", not "Design|why".
    func test_aliasIsNotPartOfTheCreatedNoteName() throws {
        let (_, store) = try store()
        let name = LinkCompletionContext.documentName(of: "Design|why")
        XCTAssertEqual(name, "Design")
        let note = try store.create(title: name)
        XCTAssertEqual(note.title, "Design")
        XCTAssertEqual(store.resolveLink("Design"), note.path)
    }

    /// Failure must be reportable, not swallowed — `create` throws rather than
    /// returning nil, which is what lets `DocumentPane` surface it.
    func test_createThrowsWithoutAVault() {
        let store = LoreStore(documents: FakeDocs(),
            indexPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID()).sqlite"))
        XCTAssertThrowsError(try store.create(title: "Design"))
    }

    // MARK: - Trigger detection (`[[` vs `#`)

    func test_trigger_doubleBracketIsWikilink() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "see [[Des", at: 9)?.kind, .wikilink)
    }

    func test_trigger_hashIsTag() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "about #des", at: 10)?.kind, .tag)
    }

    func test_trigger_hashQueryExcludesTheHash() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "about #des", at: 10)?.query, "des")
    }

    func test_trigger_headingHashDoesNotTrigger() {
        // `# ` at line start is a heading, and offering tag completions there
        // would fire on every new heading anyone types.
        XCTAssertNil(LinkCompletionContext.trigger(in: "# ", at: 2))
    }

    func test_trigger_hashInsideWikilinkDoesNotTrigger() {
        // `[[Note#` is a heading fragment — the wikilink trigger owns it.
        XCTAssertEqual(LinkCompletionContext.trigger(in: "[[Note#Head", at: 11)?.kind, .wikilink)
    }

    func test_trigger_nestedTagQueryKeepsTheSlash() {
        XCTAssertEqual(LinkCompletionContext.trigger(in: "#project/ain", at: 12)?.query,
                       "project/ain")
    }
}
