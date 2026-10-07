import XCTest

@testable import LoreFeature

final class LinkRewriterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/v")

    func test_planRewritesBareTargetToNewBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(
            plan.edits,
            [
                LinkEdit(
                    file: URL(fileURLWithPath: "/v/A.md"),
                    oldTarget: "Design", newTarget: "Architecture")
            ])
    }

    func test_planPreservesHeadingFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture#Overview")
    }

    func test_planPreservesTheAuthorsPathStyle() {
        // A link written with an explicit folder keeps one; a bare link stays bare.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture")
    }

    func test_planPreservesMarkdownExtensionStyle() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Architecture.md")
    }

    func test_affectedFilesAreDeduplicated() {
        let a = URL(fileURLWithPath: "/v/A.md")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Architecture.md"),
            inboundLinks: [(a, "Design", .wikilink), (a, "Design#Two", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.affectedFiles, [a])
        XCTAssertEqual(plan.edits.count, 2)
    }

    func test_moveWithoutRenameStillProducesNoEditsForBareLinks() {
        // Moving Design.md into a folder does not change a bare `[[Design]]`.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design", .wikilink)],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_moveRewritesExplicitPathLinks() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }

    func test_destinationOutsideVaultRootProducesNoEdit() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/elsewhere/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertTrue(plan.edits.isEmpty)
    }

    func test_vaultRootWithTrailingSlashBehavesIdentically() {
        let trailingRoot = URL(fileURLWithPath: "/v/")
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: trailingRoot)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Design.md")
    }

    func test_vaultRootTextRecurringInsideDestinationDoesNotCorruptTarget() {
        // vaultRoot is "/v"; destination happens to contain "/v/" again as a
        // path segment further down. A substring replace would mangle this;
        // a path-component comparison must not.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/a/v/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "a/v/Design.md")
    }

    func test_normalNestedDestinationYieldsCorrectVaultRelativeTarget() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Nested/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Design.md", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Nested/Design.md")
    }

    func test_combinedShapeRenamePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Projects/Architecture.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Projects/Architecture.md#Overview")
    }

    func test_combinedShapeMovePreservesPathExtensionAndFragment() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Projects/Design.md"),
            to: URL(fileURLWithPath: "/v/Archive/Projects/Design.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Projects/Design.md#Overview", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Archive/Projects/Design.md#Overview")
    }

    // MARK: - A dotted TITLE is not an extension (regression coverage for the
    // Critical-1 fix: `(body as NSString).pathExtension` alone cannot tell
    // `[[Chapter 1.1]]`'s trailing ".1" from a real extension; only a match
    // against the SOURCE's actual extension can).

    func test_dottedTitleWithNoRealExtensionIsRewrittenAsABareBasename() {
        // "Chapter 1.1" names a note (source extension .md); its trailing
        // ".1" is not ".md", so it must stay a bare, unqualified basename —
        // not gain a path or an appended ".md".
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Notes/Chapter 1.1.md"),
            to: URL(fileURLWithPath: "/v/Notes/Chapter 2.0.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Chapter 1.1", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Chapter 2.0")
    }

    func test_versionLikeDottedTitleIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/v1.2.md"),
            to: URL(fileURLWithPath: "/v/v1.3.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "v1.2", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "v1.3")
    }

    func test_multiDotDottedTitleIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/1.2.3.md"),
            to: URL(fileURLWithPath: "/v/1.2.4.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "1.2.3", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "1.2.4")
    }

    func test_dottedTitleWithSpaceIsRewrittenAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Report 2024.10.md"),
            to: URL(fileURLWithPath: "/v/Report 2024.11.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Report 2024.10", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Report 2024.11")
    }

    /// IMPORTANT 2's corollary: before the fix, a dotted-title link whose
    /// destination happened to land outside `vaultRoot` was misclassified as
    /// an explicit-extension link and produced an `UnrewritableLink` instead
    /// of a rewrite. Since the title is not actually an extension, it must
    /// keep rewriting fine regardless of where the destination lives.
    func test_dottedTitleOutsideVaultRootStillRewritesAsABareBasename() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Chapter 1.1.md"),
            to: URL(fileURLWithPath: "/elsewhere/Chapter 2.0.md"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Chapter 1.1", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Chapter 2.0")
        XCTAssertTrue(plan.unrewritable.isEmpty)
    }

    // MARK: - Multi-dot and extensionless files

    func test_multiDotExtensionIsPreservedOnRename() {
        // `archive.tar.gz`'s REAL extension is "gz" (`NSString.pathExtension`
        // only ever sees the last dot-segment); a body ending `.tar.gz`
        // matches that the same way, so the whole compound extension survives.
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/archive.tar.gz"),
            to: URL(fileURLWithPath: "/v/backup.tar.gz"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "archive.tar.gz", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "backup.tar.gz")
    }

    func test_extensionlessSourceProducesNoExtensionMatchAndNoDanglingDot() {
        // Neither the source nor the destination carries an extension, so
        // there is nothing for a body extension to match; the rewrite must
        // not append a bare trailing ".".
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/README"),
            to: URL(fileURLWithPath: "/v/CHANGELOG"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "README", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "CHANGELOG")
    }

    /// MINOR 4: a caller-constructed destination with no extension must not
    /// leave a bare trailing "." on the rewritten target, even though
    /// `plan(rename:to:)` (the only production caller) never actually
    /// produces such a destination — it always re-appends the source's
    /// extension. Exercised directly through the low-level `LinkRewriter.plan`
    /// so the guard itself, not just today's one caller, is covered.
    func test_explicitExtensionBodyAgainstAnExtensionlessDestinationDropsCleanly() {
        let plan = LinkRewriter.plan(
            renaming: URL(fileURLWithPath: "/v/Notes.txt"),
            to: URL(fileURLWithPath: "/v/Notes2"),
            inboundLinks: [(URL(fileURLWithPath: "/v/A.md"), "Notes.txt", .wikilink)],
            vaultRoot: root)
        XCTAssertEqual(plan.edits.first?.newTarget, "Notes2")
    }
}
