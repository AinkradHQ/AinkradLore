import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E3T2: the seams that must not move.
///
/// The index, the link graph, rename and the MCP tools all operate on the
/// document STRING and on offsets into it. The plan's acceptance is that none of
/// them needs modifying — and its instruction if one does is to stop, because
/// that would mean the document contract has been broken.
///
/// So this asserts the contract itself rather than each consumer: a corpus of
/// documents goes through the CodeMirror surface and comes back, and both the
/// bytes and the parsed link offsets are identical. If they are, no consumer
/// CAN be affected — they are pure functions of the string.
///
/// Asserting it this way rather than by running the suite with the flag on is
/// deliberate: a green suite with the flag on would prove the consumers agree
/// TODAY, while this proves the input they receive is unchanged, which is the
/// property that has to hold for every consumer written later.
final class CM6SeamsTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// Documents chosen for the things that break offsets: astral characters,
    /// combining marks, RTL text, tabs, trailing whitespace, no final newline,
    /// and every construct this milestone renders.
    private static let corpus: [(String, String)] = [
        ("plain", "Just some prose.\n\nTwo paragraphs.\n"),
        ("no final newline", "No newline at the end"),
        ("links", "See [[Design Doc]] and [[Projects/Other|other]] here.\n"),
        ("embeds", "![[shot.png]] and ![[Contract.pdf]] and ![[Note.md]]\n"),
        ("tags", "Tagged #project/ainkrad and #editor, not #1234.\n"),
        ("tasks", "- [ ] open\n- [x] done\n"),
        ("callout", "> [!warning] Careful\n> Body text.\n"),
        ("maths", "Inline $\\pi r^2$ and $$\\frac{a}{b}$$ here.\n"),
        ("table", "| A | B |\n|---|---|\n| one | two |\n"),
        ("fence", "```swift\nlet x = [[NotALink]]\n```\n"),
        ("astral", "An emoji 🌍 and a family 👩‍👩‍👧‍👦 then [[Link]].\n"),
        ("combining", "Ame\u{0301}lie and cafe\u{0301} then [[Link]].\n"),
        ("rtl", "عربي نص هنا and [[Link]] after.\n"),
        ("tabs", "\tindented\twith\ttabs\n\t\t[[Link]]\n"),
        ("trailing space", "line with trailing spaces   \nnext\n"),
        ("blank lines", "one\n\n\n\nfour blank lines above\n"),
        ("dollar prose", "It cost $5 and then $10 more.\n"),
        ("frontmatter-ish", "---\ntitle: Not parsed by the editor\n---\n\nBody.\n"),
    ]

    @MainActor
    private func roundTrip(_ text: String) throws -> String {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
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
        // Exactly what the coordinator does on both legs.
        let ending = CM6LineEndings.dominant(in: text)
        _ = try js(
            "window.loreEditor.init("
                + CM6EditorView.Coordinator.jsString(CM6LineEndings.toLF(text)) + ")")
        // Move the caret through the document so every decoration is built and
        // torn down — a rendering pass is where a mutation would come from.
        _ = try js("window.loreEditor.selectAt(0)")
        _ = try js("window.loreEditor.selectAt(Math.floor(window.loreEditor.text().length / 2))")
        _ = try js("window.loreEditor.selectAt(window.loreEditor.text().length)")
        let reported = try js("window.loreEditor.text()") as? String ?? ""
        return CM6LineEndings.from(reported, to: ending)
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

    // MARK: - the bytes

    @MainActor
    func test_everyDocumentInTheCorpusSurvivesByteForByte() throws {
        for (name, document) in Self.corpus {
            let back = try roundTrip(document)
            XCTAssertEqual(back, document, "\(name) was changed by the editor")
            // UTF-16 length too: an equal String comparison would still pass
            // for a canonically-equivalent but differently-composed string,
            // and every offset the index holds is measured in UTF-16 units.
            XCTAssertEqual(
                back.utf16.count, document.utf16.count,
                "\(name) changed length in UTF-16 units")
        }
    }

    // MARK: - the offsets

    /// The link graph and rename hold RANGES into the document. Equal strings
    /// imply equal ranges, but asserting the ranges directly is what makes the
    /// implication visible — and it is the assertion that would fail first if
    /// the surface ever normalised composition.
    @MainActor
    func test_theLinkOffsetsAreIdenticalAfterTheRoundTrip() throws {
        for (name, document) in Self.corpus {
            let back = try roundTrip(document)
            let before = LinkParser.spans(in: document)
            let after = LinkParser.spans(in: back)
            XCTAssertEqual(before.count, after.count, "\(name): link count changed")
            for (a, b) in zip(before, after) {
                XCTAssertEqual(
                    a.targetRange, b.targetRange,
                    "\(name): a link moved")
                XCTAssertEqual(
                    a.link.rawTarget, b.link.rawTarget,
                    "\(name): a link target changed")
                XCTAssertEqual(a.link.isEmbed, b.link.isEmbed, "\(name)")
                XCTAssertEqual(a.link.syntax, b.link.syntax, "\(name)")
            }
        }
    }

    /// And the outbound links themselves — what actually lands in the index.
    @MainActor
    func test_theDocumentsOutboundLinksAreUnchanged() throws {
        for (name, document) in Self.corpus {
            let back = try roundTrip(document)
            XCTAssertEqual(
                LinkParser.links(in: document), LinkParser.links(in: back),
                "\(name): the link graph would change")
        }
    }
}
