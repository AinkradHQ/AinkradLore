import XCTest
@testable import LoreFeature

final class FrontmatterTests: XCTestCase {
    private let path = URL(fileURLWithPath: "/tmp/lore/sample.md")

    func test_parse_wellFormed() {
        let text = """
        ---
        id: abc-123
        title: My Note
        tags: [work, ideas]
        created: 2026-07-19
        updated: 2026-07-19
        ---
        Hello body
        """
        let note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.id, "abc-123")
        XCTAssertEqual(note.title, "My Note")
        XCTAssertEqual(note.tags, ["work", "ideas"])
        XCTAssertEqual(note.body, "Hello body")
    }

    func test_parse_missingFrontmatter_fallsBackToBodyAndFilename() {
        let note = Frontmatter.parse("# Heading\nplain", path: path)
        XCTAssertEqual(note.title, "Heading")          // first heading wins
        XCTAssertEqual(note.body, "# Heading\nplain")  // whole text is body
        XCTAssertFalse(note.id.isEmpty)                // synthesized
    }

    func test_roundTrip_isStable() {
        let text = Frontmatter.serialize(Frontmatter.parse("""
        ---
        id: r1
        title: Round
        tags: [a]
        created: 2026-07-19
        updated: 2026-07-19
        ---
        body text
        """, path: path))
        let reparsed = Frontmatter.parse(text, path: path)
        XCTAssertEqual(reparsed.id, "r1")
        XCTAssertEqual(reparsed.title, "Round")
        XCTAssertEqual(reparsed.tags, ["a"])
        XCTAssertEqual(reparsed.body, "body text")
    }

    func test_parse_capturesUnmodelledKeysInOrder() {
        let text = """
        ---
        id: abc
        aliases: [one, two]
        title: Kept
        status: active
        ---
        body text
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertEqual(note.extra.map(\.key), ["aliases", "status"])
        XCTAssertEqual(note.extra.first?.rawValue, "[one, two]")
    }

    func test_serialize_reemitsUnmodelledKeys() {
        let text = """
        ---
        id: abc
        title: Kept
        status: active
        cssclasses: wide
        ---
        body text
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/x.md"))
        let out = Frontmatter.serialize(note)
        XCTAssertTrue(out.contains("status: active"), out)
        XCTAssertTrue(out.contains("cssclasses: wide"), out)
    }

    // MARK: - preserve-and-patch (Task 1b)

    /// Every case here asserts a BYTE-EXACT round trip of an unmodified note.
    /// The old "parse into a model, re-emit from the model" design could not
    /// pass any of them that involve a shape `Note` does not model.
    private func assertByteExact(_ text: String, _ message: String = "",
                                 line: UInt = #line) {
        let out = Frontmatter.serialize(Frontmatter.parse(text, path: path))
        XCTAssertEqual(out, text, message, line: line)
    }

    func test_byteExact_blockSequenceAliases() {
        assertByteExact("""
        ---
        id: a
        title: T
        aliases:
          - one
          - two
        created: 2026-01-01
        updated: 2026-01-01
        ---
        body
        """)
    }

    func test_byteExact_blockSequenceCssclasses() {
        assertByteExact("""
        ---
        id: a
        title: T
        cssclasses:
          - wide
          - dark
        ---
        body
        """)
    }

    func test_byteExact_blockSequenceTags() {
        assertByteExact("""
        ---
        id: a
        title: T
        tags:
          - work
          - ideas
        ---
        body
        """)
    }

    /// The critical one: a block-sequence `tags:` must be READ into `note.tags`
    /// (or tag filtering and the index silently see an untagged vault) and
    /// still be written back as a block sequence.
    func test_blockSequenceTags_areReadAndWrittenBackUnchanged() {
        let text = """
        ---
        id: a
        title: T
        tags:
          - work
          - "quoted tag"
        ---
        body
        """
        let note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.tags, ["work", "quoted tag"])
        XCTAssertEqual(Frontmatter.serialize(note), text)
    }

    func test_byteExact_inlineListsStillWork() {
        assertByteExact("""
        ---
        id: a
        title: T
        tags: [work, ideas]
        aliases: [one, two]
        created: 2026-01-01
        updated: 2026-01-01
        ---
        body
        """)
    }

    func test_byteExact_isoCreatedIsNotRewritten() {
        let text = """
        ---
        id: a
        title: T
        created: 2026-01-02T10:00:00Z
        updated: 2026-01-02T10:00:00Z
        ---
        body
        """
        let note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.created, Date(timeIntervalSince1970: 1_767_348_000))
        XCTAssertEqual(Frontmatter.serialize(note), text)
    }

    func test_byteExact_dayCreatedIsNotRewritten() {
        assertByteExact("""
        ---
        id: a
        title: T
        created: 2026-01-02
        ---
        body
        """)
    }

    func test_byteExact_unparseableCreatedIsLeftAlone() {
        let text = """
        ---
        id: a
        title: T
        created: sometime last tuesday
        ---
        body
        """
        // It parses to `now` in the model, but the file must not be touched.
        assertByteExact(text, "an unparseable date must never be overwritten")
    }

    func test_byteExact_commentsAndBlankLines() {
        assertByteExact("""
        ---
        # the note's identity
        id: a
        title: T

        # obsidian properties
        aliases:
          - one
        ---
        body
        """)
    }

    func test_byteExact_quotedValuesAndColonsAndHashes() {
        assertByteExact("""
        ---
        id: a
        title: "Ratio: 3#4"
        source: https://example.com/a#b
        note: 'it: works'
        ---
        body
        """)
    }

    func test_byteExact_blockScalars() {
        assertByteExact("""
        ---
        id: a
        title: T
        description: |
          line one
          line two
        summary: >
          folded text
        ---
        body
        """)
    }

    func test_byteExact_keyOrderIsPreserved() {
        assertByteExact("""
        ---
        updated: 2026-01-01
        zeta: last
        title: T
        created: 2026-01-01
        alpha: first
        id: a
        tags: [x]
        ---
        body
        """)
    }

    func test_changingTitle_altersOnlyTheTitleLine() {
        let text = """
        ---
        id: a
        title: Old
        aliases:
          - one
        created: 2026-01-02T10:00:00Z
        # keep me
        status: active
        ---
        body
        """
        var note = Frontmatter.parse(text, path: path)
        note.title = "New"
        let out = Frontmatter.serialize(note)
        XCTAssertEqual(out, text.replacingOccurrences(of: "title: Old", with: "title: New"))
    }

    func test_noFrontmatter_serializesFromTheModel() {
        let note = Frontmatter.parse("# Heading\nplain", path: path)
        XCTAssertNil(note.rawFrontmatter)
        let out = Frontmatter.serialize(note)
        XCTAssertTrue(out.hasPrefix("---\nid: \(note.id)\ntitle: Heading\n"), out)
        XCTAssertTrue(out.hasSuffix("---\n# Heading\nplain"), out)
    }

    func test_emptyFrontmatterBlock_gainsOnlyAnIdAndKeepsBody() {
        let note = Frontmatter.parse("---\n---\nbody", path: path)
        XCTAssertEqual(note.rawFrontmatter, "")
        XCTAssertEqual(note.body, "body")
        // Only `id` is appended: a derived title, an empty tag list and dates
        // that defaulted to "now" are fabrications, not preserved facts.
        XCTAssertEqual(Frontmatter.serialize(note), "---\nid: \(note.id)\n---\nbody")
    }

    func test_absentModelledKeysAreAppendedOnlyWhenTheyCarryRealValues() {
        var note = Frontmatter.parse("""
        ---
        aliases:
          - one
        ---
        body
        """, path: path)
        note.title = "Explicit"
        note.tags = ["x"]
        XCTAssertEqual(Frontmatter.serialize(note), """
        ---
        aliases:
          - one
        id: \(note.id)
        title: Explicit
        tags: [x]
        ---
        body
        """)
    }

    func test_unmodelledBlockSequence_isFlattenedForTheIndexOnly() {
        let note = Frontmatter.parse("""
        ---
        id: a
        aliases:
          - one
          - two
        ---
        body
        """, path: path)
        XCTAssertEqual(note.extra.map(\.key), ["aliases"])
        XCTAssertEqual(note.extra.first?.rawValue, "[one, two]")
    }

    func test_roundTrip_isStableAcrossTwoPasses() {
        let text = """
        ---
        id: abc
        title: Kept
        tags: [a, b]
        created: 2026-01-01
        updated: 2026-01-02
        source: https://example.com
        ---
        body text
        """
        let path = URL(fileURLWithPath: "/tmp/x.md")
        let once = Frontmatter.serialize(Frontmatter.parse(text, path: path))
        let twice = Frontmatter.serialize(Frontmatter.parse(once, path: path))
        XCTAssertEqual(once, twice)
    }

    func test_readsInlineAliases() {
        let text = """
        ---
        id: a
        title: T
        aliases: [Design Doc, Spec]
        ---
        body
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertEqual(note.aliases, ["Design Doc", "Spec"])
    }

    func test_readsBlockSequenceAliases() {
        let text = """
        ---
        id: a
        title: T
        aliases:
          - Design Doc
          - Spec
        ---
        body
        """
        let note = Frontmatter.parse(text, path: URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertEqual(note.aliases, ["Design Doc", "Spec"])
    }

    func test_readingAliasesDoesNotChangeSerialization() {
        let text = """
        ---
        id: a
        title: T
        aliases:
          - Design Doc
        ---
        body
        """
        let path = URL(fileURLWithPath: "/tmp/a.md")
        XCTAssertEqual(Frontmatter.serialize(Frontmatter.parse(text, path: path)), text)
    }
}
