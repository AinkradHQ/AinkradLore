import XCTest
import AppKit
import SwiftUI
import AinkradAppKit
@testable import LoreFeature

final class RichTextEngineTests: XCTestCase {
    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-rtf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_claimsRichTextExtensionsOnly() {
        for ext in ["docx", "rtf", "odt", "html", "htm", "DOCX"] {
            XCTAssertTrue(RichTextEngine.canOpen(URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
        for ext in ["md", "txt", "pdf", "png"] {
            XCTAssertFalse(RichTextEngine.canOpen(URL(fileURLWithPath: "/x/a.\(ext)")), ext)
        }
    }

    func test_extractsPlainTextFromRTF() throws {
        let attributed = NSAttributedString(string: "Quarterly revenue summary")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = try tempFile("report.rtf", rtf)
        let engine = try RichTextEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.contains("Quarterly revenue"))
        XCTAssertEqual(engine.indexTitle, "report")
        XCTAssertFalse(engine.isEditable)
    }

    func test_extractsPlainTextFromHTML() throws {
        let html = Data("<html><body><h1>Ainkrad</h1><p>Design notes</p></body></html>".utf8)
        let url = try tempFile("page.html", html)
        let engine = try RichTextEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.contains("Design notes"))
    }

    func test_unparseableFile_loadsWithAFailureAndNoText() throws {
        let url = try tempFile("broken.docx", Data([0x00, 0x01, 0x02, 0x03]))
        let engine = try RichTextEngine.load(url)
        XCTAssertNotNil(engine.loadFailure)
        XCTAssertEqual(engine.indexPayload.plaintext, "")
        XCTAssertEqual(engine.indexTitle, "broken")
    }

    /// The defect: a scripted single-page app saved as `.html` — empty
    /// `<body>`, content built by `<script>` tags AppKit's importer never
    /// runs. It must NOT look like an ordinary successfully-extracted
    /// document: `hasNoExtractableText` is the flag `makeEditor` uses to
    /// swap in the QuickLook fallback instead of a blank `NSTextView`.
    func test_scriptOnlySPA_hasNoExtractableText() throws {
        let html = Data("""
            <html><body></body>
            <script>document.body.innerHTML = window.__APP__.render();</script>
            <script>console.log('boot');</script>
            </html>
            """.utf8)
        let url = try tempFile("app.html", html)
        let engine = try RichTextEngine.load(url)
        XCTAssertNil(engine.loadFailure, "the HTML format WAS recognized; this is not a load failure")
        XCTAssertTrue(engine.hasNoExtractableText)
    }

    /// The index must stay honest either way: a document that extracts to
    /// nothing contributes EMPTY plaintext, never invented text (e.g. raw
    /// script source), so full-text search can never match content nobody
    /// actually parsed.
    func test_scriptOnlySPA_indexesEmptyPlaintextNotInventedText() throws {
        let html = Data("<html><body></body><script>var x = 'SECRET_TOKEN_1';</script></html>".utf8)
        let url = try tempFile("app.html", html)
        let engine = try RichTextEngine.load(url)
        XCTAssertTrue(engine.indexPayload.plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(engine.indexPayload.plaintext.contains("SECRET_TOKEN_1"),
                       "script source must never leak into the searchable index as invented text")
    }

    /// The negative case: ordinary HTML with real extractable text must NOT
    /// take the empty-extraction fallback path.
    func test_ordinaryHTML_hasExtractableText() throws {
        let html = Data("<html><body><h1>Ainkrad</h1><p>Design notes</p></body></html>".utf8)
        let url = try tempFile("page.html", html)
        let engine = try RichTextEngine.load(url)
        XCTAssertFalse(engine.hasNoExtractableText)
    }

    func test_save_throwsReadOnly() throws {
        let url = try tempFile("report.rtf", Data("{\\rtf1 hello}".utf8))
        let engine = try RichTextEngine.load(url)
        XCTAssertThrowsError(try engine.save(to: url)) { error in
            XCTAssertEqual(error as? EngineError, .readOnly(url))
        }
    }
}

/// Fix round 1, the owner's ruling on the WebKit trade-off: a rich-text
/// document with no extractable text must not auto-instantiate the
/// (script-executing, network-capable) QuickLook preview on open — only on
/// the owner's explicit "Render this page" action. `RenderGate` is the
/// object that gate lives on; a plain `XCTestCase` is enough to pin it,
/// since it is deliberately independent of SwiftUI view state — see its doc
/// comment in `ReadOnlyViewers.swift`.
@MainActor
final class RenderGateTests: XCTestCase {
    func test_startsUnrendered() {
        let gate = RenderGate()
        XCTAssertFalse(gate.isRendered,
                       "nothing may execute merely because the document was opened")
    }

    func test_renderFlipsItToRendered() {
        let gate = RenderGate()
        gate.render()
        XCTAssertTrue(gate.isRendered)
    }

    /// Two documents (or two opens of the same document) never share state:
    /// each `RichTextEngine.makeEditor` call constructs its OWN `RenderGate`,
    /// so pressing render on one instance must never be visible on another.
    func test_gatesAreIndependentPerInstance() {
        let first = RenderGate()
        let second = RenderGate()
        first.render()
        XCTAssertTrue(first.isRendered)
        XCTAssertFalse(second.isRendered,
                       "rendering one document's fallback must not opt in a different one")
    }
}

/// Fix round 2, Important 8: the bug was never inside `RenderGate` — an
/// isolated unit test of that object (`RenderGateTests` above) is correct
/// but CANNOT see this class of bug, because the bug was in WHERE the
/// instance lived: `RichTextEngine.makeEditor` builds a fresh
/// `EmptyExtractionFallbackView` value every time `DocumentPane.body`
/// re-evaluates (an outline refresh, a banner, a theme change — see
/// `DocumentPane.outline`'s doc comment for that exact trigger list), and a
/// `RenderGate` handed in from the OUTSIDE via `@ObservedObject` does not
/// survive that; only a `@StateObject` OWNED by the view itself does. These
/// tests drive the REAL SwiftUI `@StateObject` lifecycle through
/// `NSHostingView` — no shortcuts, no reaching into private state — because
/// that lifecycle is the entire property under test.
@MainActor
final class EmptyExtractionFallbackViewLifecycleTests: XCTestCase {
    /// Captures the `RenderGate` instance `EmptyExtractionFallbackView.body`
    /// is handed on every evaluation, via the view's test-only
    /// `onGateAvailable` hook — the same seam a production caller never
    /// touches (`nil` there).
    private final class GateProbe {
        var seen: [ObjectIdentifier] = []
    }

    private struct Host: View {
        var toggle: Bool
        let url: URL
        let theme: HostTheme
        let probe: GateProbe

        var body: some View {
            VStack {
                // The UNRELATED state this simulates: `DocumentPane`'s own
                // `outline`/banners, not anything `EmptyExtractionFallbackView`
                // reads.
                Text(toggle ? "a" : "b")
                EmptyExtractionFallbackView(url: url, theme: theme) { gate in
                    probe.seen.append(ObjectIdentifier(gate))
                }
            }
        }
    }

    private func hostedWindow(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// The regression proof: an UNRELATED re-render (the `toggle` flip,
    /// standing in for `DocumentPane.body` re-evaluating for any of its own
    /// reasons) must hand `body` the SAME `RenderGate` instance both times.
    /// Against the fix-round-1 `@ObservedObject` code, this fails —
    /// `RichTextEngine.makeEditor` would construct a new `RenderGate()` on
    /// every `Host.body` call, so the two captured identities would differ.
    func test_gateSurvivesAnUnrelatedReRender() {
        let probe = GateProbe()
        let url = URL(fileURLWithPath: "/tmp/lore-empty-extraction-test.html")
        let theme = HostTheme(TestTokens.make())
        let (window, hosting) = hostedWindow(Host(toggle: false, url: url, theme: theme, probe: probe))
        _ = window   // kept alive for the hosting view's lifetime

        hosting.rootView = AnyView(Host(toggle: true, url: url, theme: theme, probe: probe))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(probe.seen.count, 2, "precondition: body evaluated twice")
        XCTAssertEqual(probe.seen[0], probe.seen[1],
                       "an unrelated re-render must not construct a new RenderGate")
    }

    /// The other half of the same contract: a genuinely NEW identity (a
    /// different document; or the same document reloaded, which is what
    /// `DocumentPane`'s `.id("\(session.id)-\(session.reloadGeneration)")`
    /// changing models) must still start with a FRESH, closed gate — the
    /// fail-closed property fix round 1 established must survive fix round
    /// 2's persistence fix, not be traded away for it.
    func test_aNewHostingViewStartsWithAFreshGate() {
        let theme = HostTheme(TestTokens.make())
        let firstProbe = GateProbe()
        let (firstWindow, _) = hostedWindow(
            Host(toggle: false, url: URL(fileURLWithPath: "/tmp/a.html"),
                theme: theme, probe: firstProbe))
        _ = firstWindow

        let secondProbe = GateProbe()
        let (secondWindow, _) = hostedWindow(
            Host(toggle: false, url: URL(fileURLWithPath: "/tmp/b.html"),
                theme: theme, probe: secondProbe))
        _ = secondWindow

        XCTAssertEqual(firstProbe.seen.count, 1)
        XCTAssertEqual(secondProbe.seen.count, 1)
        XCTAssertNotEqual(firstProbe.seen[0], secondProbe.seen[0],
                          "two separate document opens must never share a gate")
    }
}
