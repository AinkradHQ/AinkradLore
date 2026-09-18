import XCTest
@testable import LoreFeature

/// The PATCH axis: what happens when a modelled value CHANGES, and on document
/// shapes the preserve tests do not reach (CRLF, hostile scalar values).
///
/// Split from `FrontmatterTests`, which covers the PRESERVE axis. The original
/// defect shipped because the suite only tested tidy inline lists; the review
/// of the first fix found the same blind spot had moved one level over — good
/// preserve coverage, one benign mutation test. This file is that gap.
final class FrontmatterPatchTests: XCTestCase {
    private let path = URL(fileURLWithPath: "/tmp/lore/sample.md")

    private func assertByteExact(_ text: String, _ message: String = "",
                                 line: UInt = #line) {
        let out = Frontmatter.serialize(Frontmatter.parse(text, path: path))
        XCTAssertEqual(out, text, message, line: line)
    }

    // MARK: - CRLF (review finding: Critical 1)

    /// A CRLF document must round-trip byte-exact. Splitting on "\n" alone
    /// leaves "---\r" as the first line, no frontmatter is recognised, and
    /// serialize PREPENDS a fabricated block — every property lost.

    func test_crlf_unmodifiedRoundTripIsByteExact() {
        assertByteExact("---\r\nid: a\r\ntitle: T\r\ntags: [x]\r\n---\r\nbody\r\nmore")
    }

    func test_crlf_blockSequencePropertyIsByteExact() {
        assertByteExact("---\r\nid: a\r\ntitle: T\r\naliases:\r\n  - one\r\n  - two\r\n---\r\nbody")
    }

    func test_crlf_titleChangeAltersOnlyTheTitleLineAndKeepsCRLF() {
        let text = "---\r\nid: a\r\ntitle: Old\r\naliases:\r\n  - one\r\n---\r\nbody"
        var note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.lineEnding, "\r\n")
        XCTAssertEqual(note.title, "Old")
        note.title = "New"
        XCTAssertEqual(Frontmatter.serialize(note),
                       "---\r\nid: a\r\ntitle: New\r\naliases:\r\n  - one\r\n---\r\nbody")
    }

    func test_lf_documentKeepsLFLineEndings() {
        XCTAssertEqual(Frontmatter.parse("---\nid: a\n---\nbody", path: path).lineEnding, "\n")
    }

    /// Documents, rather than promises, what mixed endings do: any CRLF present
    /// wins for the WHOLE document. Not a per-line guarantee.
    func test_mixedLineEndings_areEmittedEntirelyAsCRLF() {
        let out = Frontmatter.serialize(
            Frontmatter.parse("---\nid: a\ntitle: T\r\nother: x\n---\nbody", path: path))
        XCTAssertEqual(out, "---\r\nid: a\r\ntitle: T\r\nother: x\r\n---\r\nbody")
    }

    // MARK: - byte order mark (review finding, round 2 item 1)

    /// A BOM shifts the opening fence to "\u{FEFF}---", so without this the
    /// frontmatter is not recognised and a fabricated block is prepended above
    /// the user's real one — the same total-property-loss failure as CRLF, on a
    /// file Obsidian renders perfectly.

    func test_bom_unmodifiedRoundTripIsByteExact() {
        assertByteExact("\u{FEFF}---\nid: a\ntitle: T\nstatus: x\n---\nb")
    }

    func test_bom_isRecognisedAsFrontmatterNotAsBody() {
        let note = Frontmatter.parse("\u{FEFF}---\nid: a\ntitle: T\nstatus: x\n---\nb", path: path)
        XCTAssertTrue(note.hasByteOrderMark)
        XCTAssertEqual(note.id, "a")
        XCTAssertEqual(note.title, "T")
        XCTAssertEqual(note.extra.map(\.key), ["status"])
        XCTAssertEqual(note.body, "b")
    }

    func test_bom_titleChangeAltersOnlyTheTitleLineAndKeepsTheMark() {
        let text = "\u{FEFF}---\nid: a\ntitle: Old\nstatus: x\n---\nb"
        var note = Frontmatter.parse(text, path: path)
        note.title = "New"
        XCTAssertEqual(Frontmatter.serialize(note),
                       "\u{FEFF}---\nid: a\ntitle: New\nstatus: x\n---\nb")
    }

    /// Both preservation mechanisms composing.
    func test_bomAndCRLF_roundTripByteExact() {
        assertByteExact("\u{FEFF}---\r\nid: a\r\ntitle: T\r\naliases:\r\n  - one\r\n---\r\nbody")
    }

    func test_bom_withNoFrontmatter_isNotDuplicatedIntoTheBody() {
        let text = "\u{FEFF}# Heading\nplain"
        let note = Frontmatter.parse(text, path: path)
        XCTAssertTrue(note.hasByteOrderMark)
        XCTAssertEqual(note.body, "# Heading\nplain", "the mark must not be left inside the body")
        let out = Frontmatter.serialize(note)
        XCTAssertTrue(out.hasPrefix("\u{FEFF}---\n"), out)
        XCTAssertEqual(out.filter { $0 == "\u{FEFF}" }.count, 1, out)
    }

    // MARK: - hostile scalar values (review finding: Critical 2)

    /// `serialize` then `parse` must return the EXACT original string for
    /// arbitrary text. `LoreNoteOperations.saveNote` takes `object["title"]`
    /// unsanitised, so this has to hold for hostile input, not tidy input.
    private func assertTitleSurvives(_ title: String, line: UInt = #line) {
        let base = "---\nid: a\ntitle: placeholder\nstatus: active\n---\nbody"
        var note = Frontmatter.parse(base, path: path)
        note.title = title
        let out = Frontmatter.serialize(note)
        let reparsed = Frontmatter.parse(out, path: path)
        XCTAssertEqual(reparsed.title, title, "title mangled by \(out)", line: line)
        // Nothing else may be disturbed — no injected or lost properties.
        XCTAssertEqual(reparsed.id, "a", out, line: line)
        XCTAssertEqual(reparsed.extra.map(\.key), ["status"], out, line: line)
        XCTAssertEqual(reparsed.body, "body", out, line: line)
    }

    func test_hostileTitle_colonDoesNotProduceInvalidYAML() {
        assertTitleSurvives("Ratio: 3")
        assertTitleSurvives("Meeting: Q3")
    }

    func test_hostileTitle_newlineCannotInjectAProperty() {
        assertTitleSurvives("Evil\nmalicious: yes")
        let base = "---\nid: a\ntitle: placeholder\n---\nbody"
        var note = Frontmatter.parse(base, path: path)
        note.title = "Evil\nmalicious: yes"
        let out = Frontmatter.serialize(note)
        XCTAssertFalse(out.contains("\nmalicious: yes"), "property injected:\n\(out)")
        XCTAssertEqual(Frontmatter.parse(out, path: path).extra, [])
    }

    func test_hostileTitle_leadingDashHashQuotesSpacesAndEmpty() {
        assertTitleSurvives("- dash")
        assertTitleSurvives("#tag")
        assertTitleSurvives("\"already quoted\"")
        assertTitleSurvives("trailing space ")
        assertTitleSurvives(" leading space")
        assertTitleSurvives("true")
        assertTitleSurvives("[not, a, list]")
        assertTitleSurvives("back\\slash")
        // Escaping is only correct if the escape character itself round-trips.
        assertTitleSurvives("\\")
        assertTitleSurvives("\\\\")
        assertTitleSurvives("trailing backslash\\")
        assertTitleSurvives("mixed \"quote\" and \\back\\slash")
        assertTitleSurvives("\\\"not an escape\\\"")
    }

    /// The one value that deliberately does NOT round-trip: an empty title is
    /// the absence of a title, not a value. `parse` always derives one, so
    /// `title: ""` could never survive a reload — it is left off the file
    /// rather than written as a meaningless key.
    func test_emptyTitle_isNotWrittenAndFallsBackToTheDerivedTitle() {
        var note = Frontmatter.parse("---\nid: a\ntitle: Old\n---\n# Heading\nbody", path: path)
        note.title = ""
        let out = Frontmatter.serialize(note)
        XCTAssertEqual(out, "---\nid: a\ntitle: Old\n---\n# Heading\nbody")
        XCTAssertFalse(out.contains("title: \"\""), out)
    }

    func test_hostileTagItems_surviveTheRoundTrip() {
        let hostile = ["a, b", "c: d", "[e]", "#f"]
        var note = Frontmatter.parse("---\nid: a\ntitle: T\ntags: [old]\n---\nbody", path: path)
        note.tags = hostile
        let out = Frontmatter.serialize(note)
        XCTAssertEqual(Frontmatter.parse(out, path: path).tags, hostile, out)
    }

    func test_quotedTitle_isUnquotedOnReadAndStillByteExact() {
        let text = """
        ---
        id: "quoted-id"
        title: "Quoted"
        ---
        body
        """
        let note = Frontmatter.parse(text, path: path)
        XCTAssertEqual(note.title, "Quoted")
        XCTAssertEqual(note.id, "quoted-id")
        XCTAssertEqual(Frontmatter.serialize(note), text)
    }

    // MARK: - patching a block sequence (review findings: Important 3 & 5)

    func test_mutatingBlockSequenceTags_replacesTheWholeBlock() {
        let note0 = Frontmatter.parse("""
        ---
        id: a
        tags:
          - one
          - two
        status: active
        ---
        body
        """, path: path)
        var note = note0
        note.tags = ["z"]
        XCTAssertEqual(Frontmatter.serialize(note), """
        ---
        id: a
        tags: [z]
        status: active
        ---
        body
        """)
    }

    func test_mutatingBlockSequenceTags_withInteriorComment_leavesNoOrphans() {
        var note = Frontmatter.parse("""
        ---
        id: a
        tags:
          - one
        # c
          - two
        status: active
        ---
        body
        """, path: path)
        XCTAssertEqual(note.tags, ["one", "two"], "an interior comment must not truncate the list")
        note.tags = ["z"]
        XCTAssertEqual(Frontmatter.serialize(note), """
        ---
        id: a
        tags: [z]
        status: active
        ---
        body
        """)
    }

    func test_mutatingBlockSequenceTags_withInteriorBlankLine_leavesNoOrphans() {
        var note = Frontmatter.parse("---\nid: a\ntags:\n  - one\n\n  - two\nstatus: active\n---\nbody",
                                     path: path)
        XCTAssertEqual(note.tags, ["one", "two"])
        note.tags = ["z"]
        XCTAssertEqual(Frontmatter.serialize(note), "---\nid: a\ntags: [z]\nstatus: active\n---\nbody")
    }

    /// A comment AFTER the last item belongs to nobody and must not be eaten.
    func test_trailingCommentIsNotSwallowedByThePrecedingBlock() {
        var note = Frontmatter.parse("""
        ---
        id: a
        tags:
          - one
        # trailing
        ---
        body
        """, path: path)
        note.tags = ["z"]
        XCTAssertEqual(Frontmatter.serialize(note), """
        ---
        id: a
        tags: [z]
        # trailing
        ---
        body
        """)
    }

    func test_changedIsoUpdated_keepsItsIsoFormat() {
        var note = Frontmatter.parse("""
        ---
        id: a
        updated: 2026-01-02T10:00:00Z
        ---
        body
        """, path: path)
        note.updated = Date(timeIntervalSince1970: 1_767_434_445)  // 2026-01-03T10:00:45Z
        // Not truncated to `2026-01-03`: external tools sort on this field.
        XCTAssertEqual(Frontmatter.serialize(note), """
        ---
        id: a
        updated: 2026-01-03T10:00:45Z
        ---
        body
        """)
    }

}
