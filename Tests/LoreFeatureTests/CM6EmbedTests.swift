import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E2T5: `![[picture.png]]` becomes a real image, served over `lore-asset`.
///
/// The load is asserted by `naturalWidth`, not by the presence of an `<img>`.
/// An image with an unreachable `src` still exists in the DOM and still has a
/// class, so counting elements would pass for a page showing nothing but broken
/// -image glyphs — which is precisely the picture this milestone exists to stop
/// being reported as working.
final class CM6EmbedTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    private var handler: CM6AssetSchemeHandler!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cm6-embeds-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        windows.removeAll()
        super.tearDown()
    }

    /// A real PNG of a known PIXEL size, so `naturalWidth` is an assertion and
    /// not a hope.
    ///
    /// The bitmap is built directly rather than through `NSImage.lockFocus`,
    /// which renders at the DISPLAY's scale: on this Retina machine a 64pt
    /// image came out 128px wide, so the first version of these tests asserted
    /// 64 and failed against a perfectly correct image. A test whose expected
    /// value depends on the monitor it runs on is not a test.
    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    @MainActor
    private func boot(_ text: String, resolving: [String: URL]) throws {
        let config = WKWebViewConfiguration()
        handler = CM6AssetSchemeHandler()
        // Exactly the shape the real resolver has: a RAW TARGET in, a file out.
        // Nothing here takes a path from the page.
        handler.resolve = { resolving[$0] }
        config.setURLSchemeHandler(handler, forURLScheme: CM6AssetSchemeHandler.scheme)
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: config)
        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("boot") {
            ((try? self.js("typeof window.loreEditor")) as? String) == "object"
        }
        _ = try js("window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))")
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().length)")
    }

    @MainActor @discardableResult
    private func js(_ source: String) throws -> Any? {
        var result: Any?
        var failure: Error?
        var done = false
        webView.evaluateJavaScript(source) { v, e in
            result = v
            failure = e
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { throw failure }
        return result
    }

    @MainActor
    private func waitFor(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)")
    }

    @MainActor
    private func widths() throws -> [Int] {
        (try js("window.loreEditor.embedImageWidths()") as? [Int]) ?? []
    }

    // MARK: - the round trip that matters

    @MainActor
    func test_anEmbeddedImageIsActuallyServedAndDecoded() throws {
        let file = try writePNG(named: "shot.png", width: 64, height: 32)
        try boot("Before.\n\n![[shot.png]]\n\nAfter.\n\n", resolving: ["shot.png": file])
        XCTAssertEqual(
            try js("window.loreEditor.embedImageTargets()") as? [String],
            ["shot.png"])
        try waitFor("the image to decode") { (try? self.widths())?.first ?? 0 > 0 }
        XCTAssertEqual(try widths(), [64], "the served bytes must be the real image")
    }

    /// Markdown image syntax, same channel.
    @MainActor
    func test_aMarkdownImageIsServedToo() throws {
        let file = try writePNG(named: "m.png", width: 48, height: 16)
        try boot("![alt](m.png)\n\n", resolving: ["m.png": file])
        try waitFor("the image to decode") { (try? self.widths())?.first ?? 0 > 0 }
        XCTAssertEqual(try widths(), [48])
    }

    /// A target with a space and a `#` in it. Both would truncate or re-route
    /// the request if the encoding on either side were wrong, and the two sides
    /// are written in different languages — so this is the test that pins them
    /// to each other.
    @MainActor
    func test_aTargetWithSpacesAndPunctuationSurvivesTheEncoding() throws {
        let file = try writePNG(named: "odd.png", width: 24, height: 24)
        let target = "Attachments/Screen Shot #2 (v1).png"
        try boot("![[\(target)]]\n\n", resolving: [target: file])
        try waitFor("the image to decode") { (try? self.widths())?.first ?? 0 > 0 }
        XCTAssertEqual(try widths(), [24])
    }

    /// The security property, stated as a test: the page cannot name a path.
    /// The resolver is asked for a raw target, and a target it does not know is
    /// served nothing — whatever that target looks like.
    @MainActor
    func test_thePageCannotReachAFileTheShellDidNotResolve() throws {
        let real = try writePNG(named: "real.png", width: 10, height: 10)
        try boot("![[real.png]]\n\n", resolving: ["real.png": real])
        try waitFor("the image to decode") { (try? self.widths())?.first ?? 0 > 0 }

        // A path traversal, asked for directly by script rather than by an
        // embed, so the test is about the HANDLER and not about the scanner.
        //
        // The result is parked on `window` and polled rather than returned:
        // `evaluateJavaScript` cannot marshal a Promise and fails the whole
        // call with "an unsupported type", which reads as the fetch having
        // been blocked when in fact nothing was ever asked.
        _ = try js(
            """
            (() => {
              window.__status = "pending";
              fetch("lore-asset:///..%2F..%2Fetc%2Fpasswd")
                .then(r => { window.__status = r.status })
                .catch(() => { window.__status = "rejected" });
            })()
            """)
        try waitFor("the traversal attempt to resolve") {
            ((try? self.js("window.__status")) as? String) != "pending"
        }
        let status = try js("String(window.__status)") as? String
        // 404 from the handler, or a rejected fetch. Either is a refusal; what
        // must never happen is a 200.
        XCTAssertNotEqual(status, "200", "a traversal must never be served")
    }

    /// A missing attachment is an ordinary state of a vault being edited. It
    /// must not take the surface down, and the alt text must say which file.
    @MainActor
    func test_anUnresolvedEmbedNamesTheMissingFile() throws {
        try boot("![[gone.png]]\n\nStill here.\n\n", resolving: [:])
        // The `<img>` is swapped for a named, dimmed stand-in. Asserting only
        // that nothing DECODED was true of the previous version and looked
        // terrible: WebKit drew a grey box with a `?` glyph, because it does
        // not render alt text in place of a broken image.
        try waitFor("the failure to be handled") {
            ((try? self.js("window.loreEditor.embedMissingTargets()")) as? [String])?
                .isEmpty == false
        }
        XCTAssertEqual(
            try js("window.loreEditor.embedMissingTargets()") as? [String],
            ["gone.png"])
        XCTAssertEqual(
            try js("window.loreEditor.embedImageTargets()") as? [String], [],
            "the broken image element must be gone, not merely empty")
        let shown = try js("document.querySelector('.cm-content').innerText") as? String ?? ""
        XCTAssertTrue(shown.contains("Still here."), "the rest of the note must survive")
    }

    // MARK: - the other two kinds

    /// A PDF is a chip, not an inline rendering — the native renderer's
    /// reasoning, kept.
    @MainActor
    func test_anAttachmentThatIsNotAnImageBecomesAChip() throws {
        try boot("![[Contract.pdf]]\n\n", resolving: [:])
        XCTAssertEqual(
            try js("window.loreEditor.embedChipTargets()") as? [String],
            ["Contract.pdf"])
        XCTAssertEqual(try js("window.loreEditor.embedImageTargets()") as? [String], [])
    }

    /// A note target is neither an image nor a chip: it is a transclusion
    /// (E2T1c), and a bare name with no extension is a note too.
    ///
    /// This test asserted "keeps its syntax" while that was the interim
    /// behaviour, and E2T1c changed it deliberately. Recorded rather than
    /// quietly rewritten, because the assertion moving is the POINT: this file
    /// is about which of the three kinds a target resolves to.
    @MainActor
    func test_aMarkdownTargetIsATransclusionAndNotAnImageOrAChip() throws {
        try boot("![[Some Note.md]]\n\nand ![[Bare Name]]\n\n", resolving: [:])
        XCTAssertEqual(try js("window.loreEditor.embedImageTargets()") as? [String], [])
        XCTAssertEqual(try js("window.loreEditor.embedChipTargets()") as? [String], [])
        XCTAssertEqual(
            try js("window.loreEditor.transclusionTargets()") as? [String],
            ["Some Note.md", "Bare Name"])
    }

    /// A remote image is not ours to serve.
    @MainActor
    func test_aRemoteMarkdownImageIsLeftToThePage() throws {
        try boot("![alt](https://x.test/a.png)\n\n", resolving: [:])
        XCTAssertEqual(try js("window.loreEditor.embedImageTargets()") as? [String], [])
    }

    // MARK: - the invariant

    @MainActor
    func test_renderingChangesNoByteOfTheDocument() throws {
        let file = try writePNG(named: "x.png", width: 8, height: 8)
        let source = "![[x.png]] and ![[Contract.pdf]] and ![[Note.md]]\n\n"
        try boot(source, resolving: ["x.png": file])
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, source)
    }

    // MARK: - the encoding, both directions, without a web view

    func test_theTwoSidesOfTheURLAgree() {
        for target in [
            "a.png", "Attachments/Screen Shot #2.png",
            "with space & ampersand.jpg", "café/naïve.png", "q?x=1.png",
        ] {
            let url = try? XCTUnwrap(URL(string: CM6AssetSchemeHandler.url(forTarget: target)))
            XCTAssertEqual(
                CM6AssetSchemeHandler.target(from: url!), target,
                "round trip failed for \(target)")
        }
    }

    func test_mimeTypesAreDerivedNotGuessed() {
        XCTAssertEqual(
            CM6AssetSchemeHandler.mimeType(
                of: URL(fileURLWithPath: "/a/b.png")), "image/png")
        XCTAssertEqual(
            CM6AssetSchemeHandler.mimeType(
                of: URL(fileURLWithPath: "/a/b.svg")), "image/svg+xml")
        // The fallback, rather than a wrong type: a wrong MIME type is an image
        // that silently does not render.
        XCTAssertEqual(
            CM6AssetSchemeHandler.mimeType(
                of: URL(fileURLWithPath: "/a/b.notathing")), "application/octet-stream")
    }
}
