import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

final class EmbedRenderingTests: XCTestCase {
    func test_imageTargetsRenderInline() {
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg", "PNG"] {
            let url = URL(fileURLWithPath: "/v/a.\(ext)")
            guard case .image(let resolved) = EmbedRendering.kind(for: url) else {
                return XCTFail("\(ext) should render inline")
            }
            XCTAssertEqual(resolved, url)
        }
    }

    func test_documentTargetsRenderAsChips() {
        for ext in ["pdf", "docx", "md", "xlsx", "zip"] {
            let url = URL(fileURLWithPath: "/v/a.\(ext)")
            guard case .chip = EmbedRendering.kind(for: url) else {
                return XCTFail("\(ext) should render as a chip")
            }
        }
    }

    func test_unresolvedTargetRendersUnresolved() {
        guard case .unresolved = EmbedRendering.kind(for: nil) else {
            return XCTFail("nil target should render unresolved")
        }
    }
}

/// The offset-safety proof Task 8's brief demands: an embed's decoration must
/// never touch the character COUNT of the document, or the caret and the
/// document text disagree about where "after the embed" is.
@MainActor
final class EmbedOffsetSafetyTests: XCTestCase {

    private func makeEditor(_ text: String, resolveEmbedTarget: (@MainActor (String) -> URL?)? = nil)
        -> (MarkdownEditor.Coordinator, NSTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.resolveEmbedTarget = resolveEmbedTarget ?? { _ in nil }
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        return (coordinator, tv)
    }

    /// A resolved-image embed collapses its SOURCE TEXT visually (near-zero
    /// font), but the character it collapses stays exactly where it was —
    /// `MarkdownStyleRenderer.collapse` only ever touches attributes, never
    /// `NSTextStorage`'s characters. This proves the storage's string is
    /// byte-for-byte identical before and after an image embed is rendered.
    func test_renderingAnImageEmbedDoesNotChangeTheCharacterCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try Self.onePixelPNG().write(to: imageURL)

        let text = "Before ![[diagram.png]] after.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            let before = (tv.string as NSString).length
            XCTAssertEqual(before, (text as NSString).length)
            coordinator.applyStyles()
            XCTAssertEqual((tv.string as NSString).length, before,
                           "an image embed must never change the storage's character count")
            XCTAssertEqual(tv.string, text,
                           "the raw markdown source must be untouched by rendering")
        }
    }

    /// Typing immediately after `![[diagram.png]]` must land the new
    /// character right after the closing `]]`, not inside or before the
    /// embed — the concrete failure mode a corrupted offset mapping would
    /// produce.
    func test_typingAfterAnEmbedEditsTheCorrectOffset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try Self.onePixelPNG().write(to: imageURL)

        let text = "![[diagram.png]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            coordinator.applyStyles()
            // Caret right after the closing "]]", i.e. right before the "\n".
            let caret = ("![[diagram.png]]" as NSString).length
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            tv.insertText("X", replacementRange: tv.selectedRange())

            let expected = "![[diagram.png]]X\n"
            XCTAssertEqual(tv.string, expected,
                           "the inserted character must land exactly after the embed's ']]'")
        }
    }

    /// A one-pixel, valid PNG so `NSImage(contentsOf:)` succeeds without
    /// bundling a fixture asset.
    static func onePixelPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("failed to synthesize a test PNG")
            return Data()
        }
        return png
    }
}

/// Fix round 1, Important 8: the offset-safety tests above pin a contract an
/// `applyEmbeds` that does NOTHING would also satisfy. These assert the
/// actual decoration happened — they would fail against a no-op.
@MainActor
final class EmbedDecorationTests: XCTestCase {

    private func makeEditor(_ text: String, resolveEmbedTarget: @escaping @MainActor (String) -> URL?)
        -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.resolveEmbedTarget = resolveEmbedTarget
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        // The caret starts at {0,0} by construction. Every fixture below puts
        // the embed AFTER some leading text so the default caret position
        // does not accidentally overlap the embed's own range and suppress
        // its decoration — see `applyEmbeds`'s `isEmbedRevealed`.
        coordinator.applyStyles()
        return (coordinator, tv)
    }

    private func writeTempImage(named name: String = "diagram.png") throws -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: url)
        return (dir, url)
    }

    /// The core deliverable: a resolved image embed populates
    /// `LinkTextView.embedImages` and collapses its source to near-zero —
    /// `MarkdownStyleRenderer.collapse`'s own mechanism, asserted here by its
    /// visible effect (`.font` shrunk to the collapsed size) rather than by
    /// re-implementing `collapse`'s internals.
    func test_resolvedImageEmbedPopulatesEmbedImagesAndCollapsesItsSource() throws {
        let (dir, imageURL) = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "Intro.\n\n![[diagram.png]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            XCTAssertEqual(tv.embedImages.count, 1,
                           "a resolved, decodable image embed must produce one drawn region")
            let embedStart = (text as NSString).range(of: "![[").location
            let font = tv.textStorage?.attribute(.font, at: embedStart, effectiveRange: nil) as? NSFont
            XCTAssertNotNil(font)
            XCTAssertLessThan(font?.pointSize ?? 99, 1,
                              "the embed's source text must be collapsed to near-zero size")
        }
    }

    /// A non-image target (or any resolved target with an extension outside
    /// `EmbedRendering.imageExtensions`) renders its TARGET text as a chip —
    /// Critical 1: the pill must sit over the filename, not the raw
    /// `![[Contract.pdf]]` source, and the filename characters themselves
    /// must be UNCHANGED (still real, clickable text).
    func test_chipEmbedStylesTheFilenameNotTheRawSource() {
        let contractURL = URL(fileURLWithPath: "/vault/Attachments/Contract.pdf")
        let text = "Intro.\n\n![[Contract.pdf]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in contractURL }
        withExtendedLifetime(coordinator) {
            guard let storage = tv.textStorage else { return XCTFail("no storage") }
            let ns = text as NSString
            let targetStart = ns.range(of: "Contract.pdf").location
            let background = storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil)
            XCTAssertNotNil(background, "the chip's pill must be painted over the target text")
            XCTAssertEqual(storage.string, text, "the filename characters themselves must be untouched")
            XCTAssertTrue(tv.embedImages.isEmpty, "a non-image embed must never produce a drawn region")
        }
    }

    /// A target whose extension classifies as an image but whose bytes are
    /// not a decodable image (corrupt file, `NSImage(contentsOf:)` returns
    /// `nil`) must fall back to the chip treatment — never a blank gap.
    func test_undecodableImageFallsBackToChip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brokenURL = dir.appendingPathComponent("broken.png")
        try Data("not a png".utf8).write(to: brokenURL)

        let text = "Intro.\n\n![[broken.png]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in brokenURL }
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(tv.embedImages.isEmpty, "a failed decode must never produce a drawn region")
            guard let storage = tv.textStorage else { return XCTFail("no storage") }
            let ns = text as NSString
            let targetStart = ns.range(of: "broken.png").location
            XCTAssertNotNil(storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil),
                            "a broken image must fall back to the chip pill, not a blank gap")
        }
    }

    /// Fix round 1, Critical 1 / Important 4: the END-TO-END proof, through
    /// the real `applyEmbeds` pipeline (parsed spans, real paragraph style,
    /// real `EmbedImageRegion`), that an Arabic document's image embed
    /// resolves RTL — not just the pure-geometry unit test in
    /// `EmbedGeometryTests`. The embed paragraph itself, `![[screenshot.png]]`,
    /// is Latin-only; only the ARABIC PARAGRAPH ABOVE it can be the source of
    /// a correct `.rightToLeft` answer, which is exactly what was broken
    /// before this fix (direction resolved from the embed's own paragraph,
    /// i.e. the filename, every time).
    func test_arabicDocument_resolvesRightToLeftForALatinFilenameEmbed() throws {
        let (dir, imageURL) = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "مرحبا بكم في الملاحظات.\n\n![[screenshot.png]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            XCTAssertEqual(tv.embedImages.count, 1)
            XCTAssertEqual(tv.embedImages.first?.writingDirection, .rightToLeft,
                           "the Arabic paragraph above the embed must decide its direction")
        }
    }

    /// Fix round 2, Important 7: an embed sharing its paragraph with other
    /// text — `Before ![[shot.png]] after.` — must render as a CHIP, never
    /// as a drawn image. `EmbedGeometry.drawRect` answers in MARGIN-anchored
    /// coordinates with no idea where "Before "/"after." end, so if this
    /// guard (`isAloneOnItsParagraph`, in `applyEmbeds`) were ever bypassed,
    /// the image would paint at the paragraph's margin, directly over the
    /// surrounding prose. This is the regression guard for that guard: it
    /// uses a REAL decodable image, so a version of `applyEmbeds` that
    /// forgot the alone-on-paragraph check would fail this by producing a
    /// drawn region instead of a chip.
    func test_midParagraphEmbed_rendersAsAChipNotAnImage() throws {
        let (dir, imageURL) = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "Before ![[shot.png]] after.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(tv.embedImages.isEmpty,
                          "a mid-paragraph embed must never produce a drawn image region")
            guard let storage = tv.textStorage else { return XCTFail("no storage") }
            let ns = text as NSString
            let targetStart = ns.range(of: "shot.png").location
            XCTAssertNotNil(storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil),
                            "a mid-paragraph embed must fall back to the chip pill")
            XCTAssertEqual(storage.string, text, "the surrounding prose must be untouched")
        }
    }

    /// A directory target (no extension, so `EmbedRendering.kind(for:)`
    /// classifies it as `.chip`) must render as a chip like any other
    /// non-image target — not crash, not attempt a decode.
    func test_directoryTargetRendersAsChip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "Intro.\n\n![[Assets]]\n"
        let (coordinator, tv) = makeEditor(text) { _ in dir }
        withExtendedLifetime(coordinator) {
            XCTAssertTrue(tv.embedImages.isEmpty)
            guard let storage = tv.textStorage else { return XCTFail("no storage") }
            let targetStart = (text as NSString).range(of: "Assets").location
            XCTAssertNotNil(storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil))
        }
    }

    /// A CACHE UNIT TEST, not a decoration test — it exercises
    /// `EmbedImageCache` directly and would pass against a no-op
    /// `applyEmbeds`. Kept deliberately at this level (fix round 2, I8): the
    /// property it pins is the cache key's invalidation, which is about the
    /// cache and not about the editor, and routing it through `applyEmbeds`
    /// would test the same thing through three more layers. Named and
    /// documented as a unit test so the suite does not overstate what it
    /// covers.
    ///
    /// `EmbedImageCache` re-decodes when the FILE changes, even at the same
    /// path — the cache key is `(path, mtime, size)`, matching
    /// `ExtractionCache`'s convention, and this is what makes that key
    /// actually invalidate rather than merely exist.
    func test_unit_imageCacheInvalidatesWhenTheFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.png")

        try Data("not a png".utf8).write(to: url)
        XCTAssertNil(EmbedImageCache.shared.image(for: url), "the corrupt bytes must not decode")

        // Rewrite with a REAL image. `Thread.sleep` guarantees a distinct
        // mtime on filesystems with coarse (1s) mtime resolution — flaky
        // without it, since the cache key is exactly `(path, mtime, size)`.
        Thread.sleep(forTimeInterval: 1.05)
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: url)
        XCTAssertNotNil(EmbedImageCache.shared.image(for: url),
                        "a changed file must be re-decoded, not served the stale cached failure")
    }
}

/// Fix round 2, NEW-2: `VaultIndexCoordinator.cachedResolver` is the entire
/// correctness basis of the Critical-3 fix (one resolver build per vault
/// change instead of one per embed per render), and its invalidation rests
/// on a single `didSet` on `rows`. That `didSet` is correct today only
/// because every index-write path happens to reassign `rows`; nothing
/// enforced it. These tests are that enforcement — each obtains a resolver
/// FIRST (populating the cache), then writes to the index, then asserts the
/// new document resolves. Against a cache that never invalidated, each
/// would fail.
@MainActor
final class ResolverCacheInvalidationTests: XCTestCase {

    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-resolvercache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// The `indexDocument` path — a note saved or created through the store.
    func test_indexingANewDocumentInvalidatesTheCachedResolver() throws {
        let (_, store) = try store()
        // Populate the cache BEFORE the write. Without this the test proves
        // nothing: a cold cache builds a fresh resolver anyway.
        XCTAssertNil(store.resolveLink("Later"), "precondition: nothing named Later yet")

        let note = try store.create(title: "Later")
        XCTAssertEqual(store.resolveLink("Later"), note.path,
                       "indexDocument must invalidate the cached resolver, "
                       + "or every link created this session resolves to nothing")
    }

    /// The `rebuild()` path — a whole-vault rescan, e.g. after an external
    /// change the folder watcher noticed.
    func test_rebuildInvalidatesTheCachedResolver() throws {
        let (root, store) = try store()
        XCTAssertNil(store.resolveLink("Outside"), "precondition: nothing named Outside yet")

        // Written directly to disk, behind the store's back, exactly as an
        // external editor would — so ONLY `rebuild()` can make it known.
        let external = root.appendingPathComponent("outside.md")
        try "---\ntitle: Outside\n---\n\nbody\n".write(to: external, atomically: true,
                                                       encoding: .utf8)
        try store.rebuild()

        XCTAssertEqual(store.resolveLink("Outside")?.lastPathComponent, "outside.md",
                       "rebuild must invalidate the cached resolver")
    }

    /// The cache must still be doing its job — the same resolver instance is
    /// reused across calls when nothing changed. Asserted through behaviour
    /// rather than by reaching into the private property: two consecutive
    /// resolutions with no intervening write must agree.
    func test_theCachedResolverIsStableWhileTheVaultIsUnchanged() throws {
        let (_, store) = try store()
        let note = try store.create(title: "Stable")
        XCTAssertEqual(store.resolveLink("Stable"), note.path)
        XCTAssertEqual(store.resolveLink("Stable"), note.path)
    }
}

/// Fix round 2, I6 and NEW-3: an embed's reveal is a SPAN-level property, and
/// the caret path has to notice it without a block flip.
@MainActor
final class EmbedRevealTests: XCTestCase {

    private func makeEditor(_ text: String, resolve: @escaping @MainActor (String) -> URL?)
        -> (MarkdownEditor.Coordinator, LinkTextView) {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.resolveEmbedTarget = resolve
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        return (coordinator, tv)
    }

    /// NEW-3: a caret parked immediately after `]]`, or immediately before
    /// `!`, must NOT suppress the embed — those are the ordinary resting
    /// positions after typing an embed or before typing in front of one, and
    /// the inclusive-touch rule made the image vanish at exactly the moment
    /// the user was looking at it.
    func test_caretAtEitherBoundaryDoesNotRevealTheEmbed() {
        let embed = NSRange(location: 10, length: 16)   // e.g. "![[diagram.png]]"
        let justBefore = NSRange(location: 10, length: 0)
        let justAfter = NSRange(location: 26, length: 0)
        XCTAssertFalse(MarkdownEditor.Coordinator.isEmbedRevealed(embed, selection: justBefore))
        XCTAssertFalse(MarkdownEditor.Coordinator.isEmbedRevealed(embed, selection: justAfter))
    }

    /// The other half of the same rule: a caret genuinely INSIDE the source
    /// — which is when the user is editing the target — does reveal.
    func test_caretInsideTheEmbedRevealsIt() {
        let embed = NSRange(location: 10, length: 16)
        XCTAssertTrue(MarkdownEditor.Coordinator.isEmbedRevealed(
            embed, selection: NSRange(location: 15, length: 0)))
        XCTAssertTrue(MarkdownEditor.Coordinator.isEmbedRevealed(
            embed, selection: NSRange(location: 12, length: 4)))
    }

    /// I6, the finding that mattered: moving the caret INTO an embed's range
    /// from elsewhere in the SAME block is not a block flip, so
    /// `revealForSelectionChange`'s block-level early return used to skip it
    /// entirely — the image stayed collapsed and drawn with the caret
    /// invisibly inside it. The embed must un-render on that move alone, with
    /// no keystroke and no debounce.
    func test_movingTheCaretIntoAnEmbedRevealsItWithoutABlockFlip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: imageURL)

        // ONE block: the embed and the caret's starting position share a
        // paragraph, so nothing below can be explained by a block flip.
        let text = "![[diagram.png]]\nTrailing line.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            // Start at offset 0 — the embed's own line, but OUTSIDE its span,
            // which `currentlyRevealedEmbedSpans` tests by strict overlap.
            //
            // The caret used to start at the end of the document, one line
            // down. That was a valid "no block flip" then and is not now: the
            // reveal unit is the LINE, so crossing to another line flips it and
            // the move would go through the ordinary path, leaving I6
            // unexercised. Staying on one line keeps the reveal range fixed
            // while the EMBED's reveal changes, which is exactly the shape this
            // test exists for.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.applyStyles()
            XCTAssertEqual(tv.embedImages.count, 1,
                           "precondition: the embed renders while the caret is outside it")
            let revealedBefore = coordinator.revealedRange

            // Move INTO the embed's own range. No text change, no keystroke.
            tv.setSelectedRange(NSRange(location: 5, length: 0))
            coordinator.revealForSelectionChange()

            XCTAssertEqual(coordinator.revealedRange, revealedBefore,
                           "precondition: this move must not flip the revealed range, "
                           + "or the test is not exercising I6")
            XCTAssertTrue(tv.embedImages.isEmpty,
                          "an embed whose range the caret entered must un-render "
                          + "immediately, not wait for a keystroke or the debounce")
        }
    }

    /// And back out again: leaving the embed's range re-renders it, likewise
    /// with no block flip and no keystroke.
    func test_movingTheCaretOutOfAnEmbedRerendersIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: imageURL)

        let text = "![[diagram.png]]\nTrailing line.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 5, length: 0))
            coordinator.applyStyles()
            XCTAssertTrue(tv.embedImages.isEmpty, "precondition: revealed while inside")

            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.revealForSelectionChange()
            XCTAssertEqual(tv.embedImages.count, 1,
                           "leaving the embed's range must restore its rendering")
        }
    }
}
