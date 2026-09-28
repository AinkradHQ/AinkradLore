import XCTest
@testable import LoreFeature

final class LinkResolverTests: XCTestCase {
    private func resolver(_ docs: [(String, String, [String])]) -> LinkResolver {
        LinkResolver(documents: docs.map {
            (url: URL(fileURLWithPath: $0.0), title: $0.1, aliases: $0.2)
        })
    }

    func test_resolvesByBasenameIgnoringFolderAndExtension() {
        let r = resolver([("/v/Projects/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Design")?.path, "/v/Projects/Design.md")
    }

    func test_resolutionIsCaseInsensitive() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("design")?.path, "/v/Design.md")
    }

    func test_ignoresHeadingFragment() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Design#Overview")?.path, "/v/Design.md")
        XCTAssertEqual(r.resolve("Design#^abc")?.path, "/v/Design.md")
    }

    func test_resolvesByFrontmatterAlias() {
        let r = resolver([("/v/Design.md", "Design", ["Spec", "Design Doc"])])
        XCTAssertEqual(r.resolve("Spec")?.path, "/v/Design.md")
    }

    func test_ambiguousBasenameResolvesToShortestPath() {
        let r = resolver([
            ("/v/Archive/Deep/Design.md", "Design", []),
            ("/v/Design.md", "Design", []),
        ])
        XCTAssertEqual(r.resolve("Design")?.path, "/v/Design.md")
    }

    func test_explicitPathDisambiguates() {
        let r = resolver([
            ("/v/Archive/Design.md", "Design", []),
            ("/v/Design.md", "Design", []),
        ])
        XCTAssertEqual(r.resolve("Archive/Design")?.path, "/v/Archive/Design.md")
    }

    func test_unresolvedTargetReturnsNil() {
        let r = resolver([("/v/Design.md", "Design", [])])
        XCTAssertNil(r.resolve("Nonexistent"))
    }

    func test_explicitPathWithExtensionResolves() {
        let r = resolver([("/v/Notes/Design.md", "Design", [])])
        XCTAssertEqual(r.resolve("Notes/Design.md")?.path, "/v/Notes/Design.md")
    }

    /// Pins the CRITICAL determinism bug: two documents at EQUAL-length paths
    /// both matching an explicit suffix must resolve to the same one
    /// regardless of the order they were passed to `init` — never to whichever
    /// happened to land first in `Dictionary.values`'s randomized iteration
    /// order. The tiebreak is lexicographic on the full path.
    func test_explicitPathAmbiguousEqualLengthResolvesLexicographicallyRegardlessOfInputOrder() {
        let a = ("/v/Aaa/Notes/Design.md", "Design", [String]())
        let b = ("/v/Bbb/Notes/Design.md", "Design", [String]())

        let forward = resolver([a, b])
        let reversed = resolver([b, a])

        // Both paths are the same length; "/v/Aaa/..." < "/v/Bbb/..." lexicographically.
        XCTAssertEqual(forward.resolve("Notes/Design")?.path, "/v/Aaa/Notes/Design.md")
        XCTAssertEqual(reversed.resolve("Notes/Design")?.path, "/v/Aaa/Notes/Design.md")
    }

    /// Pins the same class of bug one step quieter: equal-length basename
    /// collisions (no explicit path in the link) must resolve identically
    /// regardless of input order, via the lexicographic tiebreak in `byKey`.
    func test_basenameAmbiguousEqualLengthResolvesLexicographicallyRegardlessOfInputOrder() {
        let a = ("/v/Aaa/Design.md", "Design", [String]())
        let b = ("/v/Bbb/Design.md", "Design", [String]())

        let forward = resolver([a, b])
        let reversed = resolver([b, a])

        XCTAssertEqual(forward.resolve("Design")?.path, "/v/Aaa/Design.md")
        XCTAssertEqual(reversed.resolve("Design")?.path, "/v/Aaa/Design.md")
    }

    func test_resolvesAnAttachmentByFilenameWithExtension() {
        let pdf = URL(fileURLWithPath: "/v/Docs/Contract.pdf")
        let resolver = LinkResolver(documents: [
            (url: pdf, title: "Contract.pdf", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("Contract.pdf"), pdf)
    }

    func test_markdownNoteWinsOverAnAttachmentWithTheSameBasename() {
        let note = URL(fileURLWithPath: "/v/Notes/Budget.md")
        let sheet = URL(fileURLWithPath: "/v/Budget.xlsx")
        // The attachment's path is SHORTER, so the old length-first tie-break
        // would have picked it. `[[Budget]]` in a vault of notes must mean the note.
        let resolver = LinkResolver(documents: [
            (url: sheet, title: "Budget.xlsx", aliases: []),
            (url: note, title: "Budget", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("Budget"), note)
        XCTAssertEqual(resolver.resolve("Budget.xlsx"), sheet)
    }

    func test_explicitPathResolvesToAnAttachment() {
        let pdf = URL(fileURLWithPath: "/v/Docs/Contract.pdf")
        let resolver = LinkResolver(documents: [
            (url: pdf, title: "Contract.pdf", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("Docs/Contract.pdf"), pdf)
    }

    /// CRITICAL, review-caught: an explicit path target that carries an
    /// extension must resolve to the file with THAT extension, even when a
    /// same-stem markdown note also exists. Before the fix, the without-
    /// extension suffix-match pass ran unconditionally as an `||` alternative,
    /// so `Docs/Contract.pdf` could match `Docs/Contract.md` on the stem —
    /// and `sortedDocuments` being markdown-first meant the note always won.
    /// `VaultIndexCoordinator` persists whatever `resolve` returns into
    /// `links.target_path`, and `LinkRewriter` plans renames from that column,
    /// so this bug would rewrite an embed that named the PDF as if it named
    /// the note.
    func test_explicitPathWithExtensionDoesNotCollideWithASameStemMarkdownNote() {
        let pdf = URL(fileURLWithPath: "/v/Docs/Contract.pdf")
        let note = URL(fileURLWithPath: "/v/Docs/Contract.md")
        let resolver = LinkResolver(documents: [
            (url: pdf, title: "Contract.pdf", aliases: []),
            (url: note, title: "Contract", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("Docs/Contract.pdf"), pdf)
        XCTAssertEqual(resolver.resolve("Docs/Contract.md"), note)
        XCTAssertEqual(resolver.resolve("Docs/Contract"), note)
    }

    /// Same collision, image extension instead of a document extension —
    /// makes sure the fix isn't accidentally `.pdf`-specific.
    func test_explicitPathWithExtensionDoesNotCollideWithASameStemMarkdownNoteForImages() {
        let png = URL(fileURLWithPath: "/v/a/diagram.png")
        let note = URL(fileURLWithPath: "/v/a/diagram.md")
        let resolver = LinkResolver(documents: [
            (url: png, title: "diagram.png", aliases: []),
            (url: note, title: "diagram", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("a/diagram.png"), png)
        XCTAssertEqual(resolver.resolve("a/diagram.md"), note)
    }

    /// `[[Contract.pdf#Page]]`: the fragment must be stripped before
    /// resolution reaches the attachment, same as it is for a markdown note.
    func test_ignoresHeadingFragmentOnAnAttachmentTarget() {
        let pdf = URL(fileURLWithPath: "/v/Docs/Contract.pdf")
        let resolver = LinkResolver(documents: [
            (url: pdf, title: "Contract.pdf", aliases: []),
        ])
        XCTAssertEqual(resolver.resolve("Contract.pdf#Page"), pdf)
        XCTAssertEqual(resolver.resolve("Docs/Contract.pdf#Page"), pdf)
    }

    /// Determinism for the explicit-path, extension-bearing collision case
    /// specifically: the same two-document vault, built with the input
    /// tuples in both orders, must resolve `Docs/Contract.pdf` to the same
    /// URL either way — never to whichever document happened to be built
    /// (or iterated) first.
    func test_explicitPathWithExtensionCollisionResolvesIdenticallyRegardlessOfInputOrder() {
        let pdf = ("/v/Docs/Contract.pdf", "Contract.pdf", [String]())
        let note = ("/v/Docs/Contract.md", "Contract", [String]())

        let forward = resolver([pdf, note])
        let reversed = resolver([note, pdf])

        XCTAssertEqual(forward.resolve("Docs/Contract.pdf")?.path, "/v/Docs/Contract.pdf")
        XCTAssertEqual(reversed.resolve("Docs/Contract.pdf")?.path, "/v/Docs/Contract.pdf")
    }
}
