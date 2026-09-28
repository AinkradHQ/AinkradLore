import XCTest
@testable import LoreFeature

final class TransclusionResolverTests: XCTestCase {

    private func resolve(_ target: String,
                         files: [String: String],
                         path: [URL] = []) -> TransclusionContent {
        // NOTE the shape: `LinkResolver.init` takes tuples, not bare URLs
        // (`Sources/LoreFeature/Logic/LinkResolver.swift:51`).
        let docs = files.keys.map { name in
            (url: URL(fileURLWithPath: "/vault/\(name)"),
             title: (name as NSString).deletingPathExtension,
             aliases: [String]())
        }
        let resolver = LinkResolver(documents: docs)
        return TransclusionResolver.resolve(
            rawTarget: target, resolver: resolver, path: path,
            readFile: { url in
                guard let body = files[url.lastPathComponent] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return body
            })
    }

    func test_wholeNote_stripsFrontmatter() {
        let content = resolve("note.md", files: [
            "note.md": "---\ntitle: T\n---\n# Heading\n\nBody text.",
        ])
        XCTAssertEqual(content, .content("# Heading\n\nBody text."))
    }

    func test_blockFragment_returnsThatBlockOnly() {
        let content = resolve("note.md#^abc", files: [
            "note.md": "First para.\n\nSecond para. ^abc\n\nThird para.",
        ])
        XCTAssertEqual(content, .content("Second para. ^abc"))
    }

    func test_headingFragment_returnsUntilNextHeadingOfSameOrHigherLevel() {
        let content = resolve("note.md#Two", files: [
            "note.md": "# One\n\nA\n\n## Two\n\nB\n\n## Three\n\nC",
        ])
        XCTAssertEqual(content, .content("## Two\n\nB"))
    }

    func test_missingFragment_returnsOpeningContentAndNamesIt() {
        let content = resolve("note.md#^nope", files: ["note.md": "Body."])
        guard case .missingFragment(_, let name) = content else {
            return XCTFail("expected .missingFragment, got \(content)")
        }
        XCTAssertEqual(name, "nope")
    }

    func test_cycle_isDetectedByPath() {
        let a = URL(fileURLWithPath: "/vault/note.md")
        let content = resolve("note.md", files: ["note.md": "x"], path: [a])
        XCTAssertEqual(content, .circular)
    }

    func test_depthCapExceeded() {
        let deep = (0..<TransclusionResolver.depthCap).map {
            URL(fileURLWithPath: "/vault/d\($0).md")
        }
        let content = resolve("note.md", files: ["note.md": "x"], path: deep)
        XCTAssertEqual(content, .tooDeep)
    }

    func test_oversizeTargetIsTruncatedAtAWholeLine() {
        let big = String(repeating: "line of text\n", count: 40_000)
        let content = resolve("note.md", files: ["note.md": big])
        guard case .truncated(let slice) = content else {
            return XCTFail("expected .truncated, got \(content)")
        }
        XCTAssertLessThanOrEqual(slice.utf8.count, TransclusionResolver.byteCap)
        XCTAssertTrue(slice.hasSuffix("\n") || slice.hasSuffix("line of text"))
    }

    func test_crlfTargetSlicesWithoutEatingAByte() {
        let content = resolve("note.md#^abc", files: [
            "note.md": "First.\r\n\r\nSecond. ^abc\r\n\r\nThird.",
        ])
        XCTAssertEqual(content, .content("Second. ^abc"))
    }

    func test_unreadableTargetCarriesTheError() {
        let content = resolve("gone.md", files: [:])
        guard case .unreadable = content else {
            return XCTFail("expected .unreadable, got \(content)")
        }
    }
}
