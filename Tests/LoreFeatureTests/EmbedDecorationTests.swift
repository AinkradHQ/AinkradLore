import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Fix round 1, Important 8: the offset-safety tests above pin a contract an
/// `applyEmbeds` that does NOTHING would also satisfy. These assert the
/// actual decoration happened — they would fail against a no-op.
@MainActor
final class EmbedDecorationTests: XCTestCase {

    private func makeEditor(_ text: String, resolveEmbedTarget: @escaping @MainActor (String) -> URL?)
        -> (MarkdownEditor.Coordinator, LinkTextView)
    {
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
            XCTAssertEqual(
                tv.embedImages.count, 1,
                "a resolved, decodable image embed must produce one drawn region")
            let embedStart = (text as NSString).range(of: "![[").location
            let font = tv.textStorage?.attribute(.font, at: embedStart, effectiveRange: nil) as? NSFont
            XCTAssertNotNil(font)
            XCTAssertLessThan(
                font?.pointSize ?? 99, 1,
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
            XCTAssertNotNil(
                storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil),
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
            XCTAssertEqual(
                tv.embedImages.first?.writingDirection, .rightToLeft,
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
            XCTAssertTrue(
                tv.embedImages.isEmpty,
                "a mid-paragraph embed must never produce a drawn image region")
            guard let storage = tv.textStorage else { return XCTFail("no storage") }
            let ns = text as NSString
            let targetStart = ns.range(of: "shot.png").location
            XCTAssertNotNil(
                storage.attribute(.backgroundColor, at: targetStart, effectiveRange: nil),
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
        XCTAssertNotNil(
            EmbedImageCache.shared.image(for: url),
            "a changed file must be re-decoded, not served the stale cached failure")
    }
}
