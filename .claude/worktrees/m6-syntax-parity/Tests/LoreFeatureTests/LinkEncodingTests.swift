import XCTest
@testable import LoreFeature

/// Percent-encoding in link targets: when it is applied, when it is NOT, and
/// how it travels with a link's SYNTAX rather than being guessed from the
/// target text.
///
/// Its own file because `LinkRewriterTests.swift` is already 927 lines, over
/// the project's 500-line ceiling, and `LinkRewriteRegionTests.swift` is about
/// which REGIONS a rewrite may touch. These three findings are one subject.
@MainActor
final class LinkEncodingTests: XCTestCase {

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-encoding-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeStore(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    private let vault = URL(fileURLWithPath: "/v")

    // MARK: - Finding 10: encode what the NEW target requires

    /// THE interop regression. Renaming to a name containing a space used to
    /// rewrite an unencoded markdown link into another unencoded one — which
    /// Lore's own parser reads back, but CommonMark and Obsidian do not: the
    /// space ends the destination. Both halves are asserted, because "encoded"
    /// and "still resolves in Lore" are separately falsifiable.
    func test_renameToANameWithASpaceEncodesAPreviouslyUnencodedMarkdownLink() async throws {
        let root = tempDir()
        let s = try makeStore(root)
        let target = root.appendingPathComponent("Design.md")
        try "---\nid: d\ntitle: Design\n---\nbody"
            .write(to: target, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [t](Design.md)"
            .write(to: source, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        let row = s.rows.first { $0.path.lastPathComponent == "Design.md" }!
        let report = s.apply(s.plan(rename: row.path, to: "New Name"))
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty)

        let text = try String(contentsOf: source, encoding: .utf8)
        // (b) no raw space survives in the destination.
        XCTAssertTrue(text.contains("[t](New%20Name.md)"), text)
        XCTAssertFalse(text.contains("New Name.md"), text)

        // (a) Lore still resolves it — the whole point of encoding rather than
        // leaving the link broken in both readers.
        await s.settleForTesting(); try s.rebuild()
        let renamed = root.appendingPathComponent("New Name.md")
        XCTAssertEqual(s.inboundLinkCount(to: renamed), 1)
    }

    /// The other half of the ruling: a rename that needs no encoding must not
    /// introduce any. Otherwise every ordinary rename churns the user's file
    /// into `%`-triplets.
    func test_renameToANameNeedingNoEncodingProducesAPlainTarget() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("e.md")
        try "[t](Design.md)".write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design.md", newTarget: "Architecture.md")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[t](Architecture.md)")
    }

    /// A wikilink to the same renamed note keeps the raw space. Obsidian does
    /// not percent-encode wikilink targets, so an encoded one stops resolving
    /// there — the exact failure the markdown rule prevents, inverted.
    func test_aWikilinkToTheSameRenamedNoteKeepsTheRawSpace() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("w.md")
        try "see [[Design]]".write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design", newTarget: "New Name")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "see [[New Name]]")
    }

    /// The encoded SET, pinned. Space, the destination's own parentheses, a
    /// control character, and `%` itself (a round-trip requirement: every
    /// markdown reader decodes, so a literal `%` written raw comes back as
    /// something else). Everything else — including `#`-free punctuation and
    /// non-ASCII letters, which `.urlPathAllowed` would have mangled — is left
    /// exactly as the user named their file.
    func test_onlyTheCharactersThatBreakADestinationAreEncoded() {
        XCTAssertEqual(LinkRewriter.markdownDestination("a b"), "a%20b")
        XCTAssertEqual(LinkRewriter.markdownDestination("f(x).md"), "f%28x%29.md")
        XCTAssertEqual(LinkRewriter.markdownDestination("100% off"), "100%25%20off")
        XCTAssertEqual(LinkRewriter.markdownDestination("a\tb"), "a%09b")
        XCTAssertEqual(LinkRewriter.markdownDestination("Notes/Ideas-2024_v2.md"),
                       "Notes/Ideas-2024_v2.md")
        XCTAssertEqual(LinkRewriter.markdownDestination("Café&Bar[1].md"),
                       "Café&Bar[1].md")
    }

    /// A `#Heading` is a DELIMITER, not part of the name: encoding it to `%23`
    /// would fold the heading into the filename.
    func test_theFragmentIsNotEncoded() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("f.md")
        try "[t](Design.md#Overview)".write(to: file, atomically: true, encoding: .utf8)

        _ = try LinkRewriter.applyEdits(
            [LinkEdit(file: file, oldTarget: "Design.md#Overview",
                      newTarget: "New Name.md#Overview")],
            to: file, baseline: try mtime(of: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "[t](New%20Name.md#Overview)")
    }

    // MARK: - Finding 9: decoding is conditional on syntax

    /// `[[C%2FD]]` names a file with a literal `%2F` in it. Decoded — as the
    /// planner used to, unconditionally — it becomes `C/D`, so `hadPath` turns
    /// true and the link is rewritten as a vault-relative PATH it never was.
    func test_aWikilinkWhoseTargetContainsPercent2FIsNotTreatedAsAPath() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/C%2FD.md"),
            to: URL(fileURLWithPath: "/v/Renamed.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/a.md"), "C%2FD", .wikilink)],
            vaultRoot: vault)
        // A bare target with no path and no extension: the rewrite is the new
        // BASENAME, not `Renamed` computed against the vault root as a path.
        XCTAssertEqual(plan.edits.first?.newTarget, "Renamed")
        XCTAssertTrue(plan.unrewritable.isEmpty)
    }

    /// The markdown side of the same rule is unchanged: there, `%2F` really is
    /// an encoded `/`, so the target IS a path and must track the move.
    func test_aMarkdownTargetContainingPercent2FIsStillTreatedAsAPath() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/C/D.md"),
            to: URL(fileURLWithPath: "/v/Archive/D.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/a.md"), "C%2FD", .markdown)],
            vaultRoot: vault)
        XCTAssertEqual(plan.edits.first?.newTarget, "Archive/D")
    }

    /// The dangling-link half: renaming `100%20off.md` to `100 off` made the
    /// unconditionally-decoded old target (`100 off`) equal the new one, so the
    /// equality guard skipped the edit and `[[100%20off]]` was left pointing at
    /// a file that no longer exists.
    func test_renamingAFileWhoseNameContainsPercent20RewritesTheWikilink() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/100%20off.md"),
            to: URL(fileURLWithPath: "/v/100 off.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/a.md"), "100%20off", .wikilink)],
            vaultRoot: vault)
        XCTAssertEqual(plan.edits.first?.newTarget, "100 off")
    }

    /// And the markdown counterpart still produces NO edit, because there
    /// `100%20off` already spells `100 off`.
    func test_theSameRenameProducesNoEditForAnEncodedMarkdownLink() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/100 off.md"),
            to: URL(fileURLWithPath: "/v/100 off.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/a.md"), "100%20off", .markdown)],
            vaultRoot: vault)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    // MARK: - Finding 11: create-from-a-dead-link decodes

    /// Clicking "Create note" on a dead `[t](Design%20Doc.md)` used to create a
    /// junk file literally named `design%20doc.md`, which still did not resolve
    /// the link it was created for.
    func test_creatingFromAnEncodedMarkdownTargetMakesTheNoteTheLinkNames() throws {
        let root = tempDir()
        let s = try makeStore(root)
        let note = try s.createAndOpenNote(forLinkTarget: "Design%20Doc.md",
                                           syntax: .markdown)
        // `create(title:)` slugs the space to a hyphen, as it does for every
        // title — but the note is TITLED `Design Doc`, so the link resolves.
        // The junk-file symptom was `design%20doc.md`, resolving nothing.
        XCTAssertEqual(note.path.lastPathComponent, "design-doc.md")
        XCTAssertEqual(s.resolveLink("Design Doc"), note.path)
    }

    /// The wikilink side must NOT decode: `[[100%20off]]` names a file with a
    /// literal `%20`, and creating `100 off.md` would leave the link dead.
    func test_creatingFromAWikilinkTargetDoesNotDecode() throws {
        let root = tempDir()
        let s = try makeStore(root)
        let note = try s.createAndOpenNote(forLinkTarget: "100%20off", syntax: .wikilink)
        XCTAssertEqual(note.path.lastPathComponent, "100%20off.md")
        XCTAssertEqual(s.resolveLink("100%20off"), note.path)
    }

    /// End to end through the index, which is where the syntax comes FROM: the
    /// unresolved-links row the backlinks panel renders carries `.markdown`, so
    /// its "Create note" button cannot drift back into creating the junk file.
    func test_theUnresolvedLinkRowCarriesTheSyntaxTheCreateButtonNeeds() async throws {
        let root = tempDir()
        let s = try makeStore(root)
        let source = root.appendingPathComponent("a.md")
        try "---\nid: a\ntitle: A\n---\nsee [t](Design%20Doc.md) and [[100%20off]]"
            .write(to: source, atomically: true, encoding: .utf8)
        await s.settleForTesting(); try s.rebuild()

        let unresolved = s.unresolvedLinks(from: source)
        XCTAssertEqual(Set(unresolved), [
            UnresolvedLink(rawTarget: "Design%20Doc.md", syntax: .markdown),
            UnresolvedLink(rawTarget: "100%20off", syntax: .wikilink)
        ])

        let link = unresolved.first { $0.syntax == .markdown }!
        let note = try s.createAndOpenNote(forLinkTarget: link.rawTarget,
                                           syntax: link.syntax)
        XCTAssertEqual(note.path.lastPathComponent, "design-doc.md")
        // The link it was created for now resolves.
        await s.settleForTesting(); try s.rebuild()
        XCTAssertTrue(s.unresolvedLinks(from: source).allSatisfy { $0.syntax == .wikilink })
    }

    private func mtime(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }
}
