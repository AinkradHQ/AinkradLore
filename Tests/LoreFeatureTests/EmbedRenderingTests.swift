import AppKit
import SwiftUI
import XCTest

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
        for ext in ["pdf", "docx", "xlsx", "zip"] {
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

    func test_markdownTargetBecomesTransclusion() {
        let url = URL(fileURLWithPath: "/vault/note.md")
        XCTAssertEqual(EmbedRendering.kind(for: url), .transclusion(url))
    }

    func test_markdownTargetIsCaseInsensitive() {
        let url = URL(fileURLWithPath: "/vault/NOTE.MD")
        XCTAssertEqual(EmbedRendering.kind(for: url), .transclusion(url))
    }

    func test_imageStillRendersInline() {
        let url = URL(fileURLWithPath: "/vault/shot.PNG")
        XCTAssertEqual(EmbedRendering.kind(for: url), .image(url))
    }

    func test_pdfIsStillAChip() {
        let url = URL(fileURLWithPath: "/vault/contract.pdf")
        XCTAssertEqual(EmbedRendering.kind(for: url), .chip(url))
    }
}

/// The offset-safety proof Task 8's brief demands: an embed's decoration must
/// never touch the character COUNT of the document, or the caret and the
/// document text disagree about where "after the embed" is.
@MainActor
final class EmbedOffsetSafetyTests: XCTestCase {

    private func makeEditor(_ text: String, resolveEmbedTarget: (@MainActor (String) -> URL?)? = nil)
        -> (MarkdownEditor.Coordinator, NSTextView)
    {
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
            XCTAssertEqual(
                (tv.string as NSString).length, before,
                "an image embed must never change the storage's character count")
            XCTAssertEqual(
                tv.string, text,
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
            XCTAssertEqual(
                tv.string, expected,
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
