import XCTest
@testable import LoreFeature

final class EngineRegistryTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-engine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_registry_hasAtLeastOneEngine() throws {
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }

    func test_specificEngines_areMutuallyExclusive() throws {
        let samples = ["n.md", "n.markdown", "n.txt", "n.json", "n.swift",
                       "n.pdf", "n.rtf", "n.html", "n.xlsx", "n.png", "n"]
        for name in samples {
            let url = try tempFile(name, "x")
            let claimers = EngineRegistry.specificEngines.filter { $0.canOpen(url) }
            XCTAssertLessThanOrEqual(claimers.count, 1,
                "\(name) claimed by \(claimers.map { $0.identifier })")
        }
    }

    func test_attachmentEngine_isLastResortOnly() throws {
        // It is not in the specific set at all...
        XCTAssertFalse(EngineRegistry.specificEngines.contains { $0 == AttachmentEngine.self })
        // ...and it never steals a file a specific engine claims.
        let md = try tempFile("n.md", "---\ntitle: N\n---\nbody\n")
        XCTAssertEqual(EngineRegistry.engine(for: md).identifier, MarkdownEngine.identifier)
    }

    func test_engineResolution_isTotal() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertEqual(EngineRegistry.engine(for: url).identifier, AttachmentEngine.identifier)
    }

    func test_attachment_indexesFilenameAndSizeButNoContent() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        let engine = try AttachmentEngine.load(url)
        XCTAssertEqual(engine.indexPayload.title, "sheet.xlsx")
        XCTAssertEqual(engine.indexPayload.plaintext, "")
        XCTAssertEqual(engine.byteSize, "binary-ish".utf8.count)
        XCTAssertFalse(engine.isEditable)
    }

    func test_load_dispatchesThroughTheRegisteredEngine() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: Hello
        ---
        searchable haystack
        """)
        let engine = try EngineRegistry.load(url)
        XCTAssertEqual(engine.indexPayload.title, "Hello")
        XCTAssertTrue(engine.indexPayload.plaintext.contains("haystack"))
    }

    /// Engine resolution is now TOTAL (Task 2): a file no specific engine
    /// claims loads via `AttachmentEngine` instead of throwing. Replaces the
    /// old `test_load_throwsUnsupportedForAnUnclaimedType`, whose expectation
    /// is exactly the behavior this task removes.
    func test_load_ofAnUnrecognizedTypeLoadsAsAnAttachment() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        let engine = try EngineRegistry.load(url)
        XCTAssertEqual(engine.indexPayload.title, "sheet.xlsx")
        XCTAssertTrue(engine is AttachmentEngine)
    }

    func test_engineIdentifiersAreUnique() {
        let ids = EngineRegistry.engines.map { $0.identifier }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate engine identifiers: \(ids)")
    }
}

final class MarkdownEngineTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-md-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_canOpen_claimsMarkdownOnly() throws {
        XCTAssertTrue(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(MarkdownEngine.canOpen(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    func test_indexPayload_exposesTitleTagsAndBody() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: Hello
        tags: [x, y]
        ---
        searchable haystack
        """)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.title, "Hello")
        XCTAssertEqual(engine.indexPayload.tags, ["x", "y"])
        XCTAssertTrue(engine.indexPayload.plaintext.contains("haystack"))
    }

    func test_outline_listsHeadings() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        ---
        # One
        text
        ## Two
        """)
        let engine = try MarkdownEngine.load(url)
        // Full `OutlineEntry` equality, offsets included. `utf16Offset` is
        // body-relative (see `MarkdownEngine.indexPayload`'s doc comment), so
        // the expected offsets are located in `engine.note.body` itself rather
        // than hand-counted — a hand-counted literal would silently stop
        // meaning anything the day the fixture text above changes.
        let body = engine.note.body as NSString
        XCTAssertEqual(engine.indexPayload.outline, [
            OutlineEntry(level: 1, text: "One", utf16Offset: body.range(of: "# One").location),
            OutlineEntry(level: 2, text: "Two", utf16Offset: body.range(of: "## Two").location),
        ])
    }

    /// Task 7: outlines come from the AST, so a `#` inside a fenced code block
    /// is prose, never a heading — the shipping bug the old line scanner had.
    func test_markdownIndexPayloadOutlineExcludesCodeFences() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outline-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("n.md")
        try "---\nid: a\ntitle: T\n---\n# Real\n\n```\n# Fake\n```\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.outline.map(\.text), ["Real"])
    }

    /// Regression for the double-strip: `note.body` has ALREADY had real
    /// frontmatter removed by `Frontmatter.parse`, so `MarkdownEngine.outline`
    /// must not run `Frontmatter.bodyOffset` over it again. Left unguarded,
    /// a body that legitimately OPENS with something fence-shaped — here, an
    /// `---` thematic break, a real heading, then another bare `---` — gets
    /// misread as a SECOND frontmatter block: everything up to that second
    /// `---` (including the "Fake" heading) is excluded from the parse
    /// entirely, not merely shifted. Both headings must survive.
    func test_markdownOutline_headingBetweenBareDashLinesIsNotMistakenForFrontmatter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-outline-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("n.md")
        try "---\nid: a\ntitle: T\n---\n---\n# Fake\n---\n# Real\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.outline.map(\.text), ["Fake", "Real"])
        XCTAssertEqual(engine.outline.map(\.level), [1, 1])
    }

    func test_saveThenLoad_preservesUnmodelledProperties() throws {
        let url = try tempFile("n.md", """
        ---
        id: abc
        title: T
        status: active
        ---
        body
        """)
        let engine = try MarkdownEngine.load(url)
        try engine.save(to: url)
        let reloaded = try MarkdownEngine.load(url)
        XCTAssertEqual(reloaded.note.extra.map(\.key), ["status"])
    }
}

/// Run against EVERY registered engine. M3-M5 engines inherit these by
/// registering — that is the point of the suite.
final class EngineConformanceTests: XCTestCase {

    /// A minimal valid document each engine can load, keyed by identifier.
    /// A new engine must add its sample here, which is the forcing function
    /// that keeps this suite honest.
    /// Each sample must be byte-identical to what its engine's own `save`
    /// re-emits after a no-op load, since `test_loadSaveLoad_isByteStable`
    /// asserts against the ORIGINAL contents, not just idempotency. The
    /// markdown sample is deliberately a REAL Obsidian shape — block-sequence
    /// `tags` and `aliases` plus a comment — because those are exactly what a
    /// model-re-emitting serializer destroys. The assertion stays strict.
    private static let samples: [String: (name: String, contents: String)] = [
        "markdown": ("c.md", "---\nid: a\ntitle: T\ntags:\n  - alpha\n  - beta\ncreated: 2026-01-01\nupdated: 2026-01-01\naliases:\n  - one\n# a trailing comment\n---\nbody"),
        "plaintext": ("c.txt", "plain body text"),
    ]

    private func write(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-conf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Scoped to the EDITABLE subset of `specificEngines`: `AttachmentEngine`
    /// and any read-only specific engine (`PDFEngine`, and later
    /// `RichTextEngine`) are deliberately not conformance citizens here — they
    /// never round-trip (`save` always throws `readOnly`), so the
    /// "byte-stable" round-trip this suite exists to enforce does not apply.
    /// `AttachmentEngine`'s own contract is covered by
    /// `test_attachment_indexesFilenameAndSizeButNoContent` in
    /// `EngineRegistryTests`; a read-only engine's load/index contract is
    /// covered by its own test file (e.g. `PDFEngineTests`).
    /// `DocumentEngine.isEditable` lives on an instance, not the type, so
    /// there is no loaded document to ask here — this suite's read-only
    /// engines are named explicitly instead. `RichTextEngine` joins `PDFEngine`
    /// here as of Task 4.
    private static let readOnlyEngineIdentifiers: Set<String> = ["pdf", "richtext"]

    func test_everyEngineHasASample() {
        for engine in EngineRegistry.specificEngines
        where !Self.readOnlyEngineIdentifiers.contains(engine.identifier) {
            XCTAssertNotNil(Self.samples[engine.identifier],
                            "engine \(engine.identifier) has no conformance sample")
        }
    }

    func test_loadSaveLoad_isByteStable() throws {
        for engine in EngineRegistry.engines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let url = try write(sample.name, sample.contents)
            let loaded = try engine.load(url)
            try loaded.save(to: url)
            let after = try String(contentsOf: url, encoding: .utf8)
            // The load-then-save-with-no-mutation round trip must reproduce
            // the ORIGINAL bytes. Comparing only two successive saves (as an
            // earlier version of this test did) would pass even for an engine
            // that strips data on every save — it only proves idempotency,
            // not fidelity.
            XCTAssertEqual(after, sample.contents,
                           "\(engine.identifier): save does not round-trip the original bytes")
            try loaded.save(to: url)
            let afterTwice = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(after, afterTwice,
                           "\(engine.identifier): save is not idempotent")
        }
    }

    func test_canOpenIsMutuallyExclusive() throws {
        // Scoped to `specificEngines`, same reasoning as `test_everyEngineHasASample`:
        // `AttachmentEngine.canOpen` is unconditionally `true`, so checking
        // mutual exclusivity across `EngineRegistry.engines` (which includes
        // it) would always find two claimers by design. Mutual exclusivity is
        // a guarantee only among `specificEngines` — `EngineRegistry`
        // consults `AttachmentEngine` last, and only when they all decline.
        for engine in EngineRegistry.specificEngines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let url = try write(sample.name, sample.contents)
            let claimers = EngineRegistry.specificEngines.filter { $0.canOpen(url) }
            XCTAssertEqual(claimers.count, 1,
                           "\(sample.name) claimed by \(claimers.map { $0.identifier })")
        }
    }

    func test_indexPayload_survivesAdversarialInput() throws {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("huge", String(repeating: "lorem ipsum ", count: 200_000)),
            ("binaryish", String(decoding: Data((0...255).map(UInt8.init)), as: UTF8.self)),
        ]
        for engine in EngineRegistry.engines {
            guard let sample = Self.samples[engine.identifier] else { continue }
            let ext = (sample.name as NSString).pathExtension
            for (label, contents) in cases {
                let url = try write("adversarial-\(label).\(ext)", contents)
                let loaded = try engine.load(url)
                let payload = loaded.indexPayload
                XCTAssertNotNil(payload.plaintext,
                                "\(engine.identifier)/\(label) produced no plaintext")
            }
        }
    }

    func test_registryHasAtLeastTwoEngines() {
        XCTAssertGreaterThanOrEqual(EngineRegistry.engines.count, 2)
    }

    func test_markdownIndexPayloadCarriesLinksAndAliases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-links-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("n.md")
        try """
        ---
        id: a
        title: T
        aliases: [Alt]
        ---
        see [[Other]] and ![[Pic]]
        """.write(to: url, atomically: true, encoding: .utf8)
        let engine = try MarkdownEngine.load(url)
        XCTAssertEqual(engine.indexPayload.links.map(\.rawTarget), ["Other", "Pic"])
        XCTAssertEqual(engine.indexPayload.links.last?.isEmbed, true)
        XCTAssertEqual(engine.indexPayload.aliases, ["Alt"])
    }
}

/// PlainTextEngine's lossy-decode / refuse-to-save contract. A lossily-decoded
/// document is legitimately unsaveable, so it is deliberately kept out of
/// `EngineConformanceTests.samples` rather than added as a case there.
final class PlainTextEngineTests: XCTestCase {
    private func write(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-plaintext-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_load_ofInvalidUTF8_succeedsAndFlagsLossyDecode() throws {
        // 0xFF is not a valid UTF-8 lead byte in any position.
        let data = Data([0x48, 0x69, 0xFF, 0x21])
        let url = try write("bad.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertTrue(engine.isLossilyDecoded)
        XCTAssertFalse(engine.indexPayload.plaintext.isEmpty)
    }

    func test_save_ofLossilyDecodedDocument_throwsNotRoundTrippable() throws {
        let data = Data([0x48, 0x69, 0xFF, 0x21])
        let url = try write("bad.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertThrowsError(try engine.save(to: url)) { error in
            XCTAssertEqual(error as? EngineError, .notRoundTrippable(url))
        }
    }

    func test_load_ofValidUTF8_isNotLossyAndSavesFine() throws {
        let data = Data("hello world".utf8)
        let url = try write("good.txt", data)
        let engine = try PlainTextEngine.load(url)
        XCTAssertFalse(engine.isLossilyDecoded)
        XCTAssertNoThrow(try engine.save(to: url))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "hello world")
    }
}
