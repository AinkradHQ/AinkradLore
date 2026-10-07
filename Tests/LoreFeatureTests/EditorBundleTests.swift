import AppKit
import WebKit
import XCTest

/// E1T1: the vendored CodeMirror bundle loads, and renders what it claims to.
///
/// The spike proved the engine works. This proves THIS repo's copy of it works
/// — a different question, and the one that breaks when a file is moved.
final class EditorBundleTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// The bundle as it sits in the repo. A built product path would test the
    /// copy phase; this tests the source of truth.
    private static var distURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LoreFeatureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Editor/dist")
    }

    // MARK: - it is actually there

    func test_theBundleIsCommittedAndNotEmpty() throws {
        for name in ["editor.js", "index.html"] {
            let url = Self.distURL.appendingPathComponent(name)
            let size =
                try FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 512, "\(name) is missing or truncated")
        }
        // `index.html` was silently truncated to zero bytes once, by a shell
        // redirect that created the file before the command feeding it failed.
        // A size assertion is the cheapest guard against that whole class.
        let html = try String(
            contentsOf: Self.distURL.appendingPathComponent("index.html"),
            encoding: .utf8)
        XCTAssertTrue(html.contains("editor.js"), "the shell must load the bundle")
        XCTAssertTrue(html.contains("--font-text"), "theming tokens must be present")
    }

    /// The half of "is committed" the size check above cannot see.
    ///
    /// This test was named `…IsCommitted…` while asserting only that the file
    /// existed ON DISK — which it always does for whoever last ran
    /// `make editor`. `.gitignore`'s `dist/` matches at every level, so
    /// `Editor/dist` was in fact ignored: the editor surface lived in one
    /// working tree, a clean checkout had no bundle, and the plugin's own
    /// resource phase would have failed on it. Asking git is the only way to
    /// assert this, so the test asks git.
    func test_theBundleIsTrackedByGitAndNotIgnored() throws {
        for name in ["editor.js", "index.html"] {
            let path = "Editor/dist/\(name)"
            let tracked = try Self.git(["ls-files", "--error-unmatch", path])
            XCTAssertFalse(tracked.isEmpty, "\(path) is not tracked by git")
            let ignored = try Self.git(["check-ignore", path])
            XCTAssertTrue(
                ignored.isEmpty,
                "\(path) is ignored by .gitignore — a clean checkout has no editor")
        }
    }

    /// `git`, run in the repo, returning stdout. A non-zero status is not a
    /// failure here: `check-ignore` exits 1 precisely when nothing is ignored,
    /// which is the passing case.
    private static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - the maths assets, in the bundle the plugin actually ships

    /// Every font `katex.min.css` asks for must be IN THE BUNDLE, resolvable by
    /// the name the stylesheet uses.
    ///
    /// This is the test for a trap that had already been laid: the fonts were
    /// copied to `dist/fonts/` and the stylesheet asked for `url(fonts/X.woff2)`,
    /// which resolves perfectly from the repo — and Xcode's resources phase
    /// FLATTENS a folder added to a target, so the plugin shipped them at
    /// `Resources/X.woff2` and every one of those URLs would have 404'd. Maths
    /// would have rendered with fallback glyphs in the app while every test
    /// passed. So this asks the BUNDLE, not the directory.
    func test_everyMathFontTheStylesheetAsksForIsInTheBundle() throws {
        let css = try String(
            contentsOf: Self.distURL
                .appendingPathComponent("katex.min.css"), encoding: .utf8)
        let references = Self.fontReferences(in: css)
        XCTAssertGreaterThan(
            references.count, 5,
            "the stylesheet should reference several fonts")
        // No subdirectory may appear in a reference, for the reason above.
        for reference in references {
            XCTAssertFalse(
                reference.contains("/"),
                "\(reference) is in a subdirectory; the bundle is flat")
        }
        let bundle = Bundle(for: Self.self)
        for reference in references {
            let name = (reference as NSString).deletingPathExtension
            let ext = (reference as NSString).pathExtension
            XCTAssertNotNil(
                bundle.url(forResource: name, withExtension: ext),
                "\(reference) is missing from the shipped bundle")
        }
    }

    /// The stylesheet has to be LINKED, or none of the above matters.
    func test_thePageLinksTheMathStylesheet() throws {
        let html = try String(
            contentsOf: Self.distURL
                .appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("katex.min.css"), "the maths stylesheet must be linked")
        XCTAssertNotNil(
            Bundle(for: Self.self)
                .url(forResource: "katex.min", withExtension: "css"))
    }

    /// `url(KaTeX_Main-Regular.woff2)` -> `KaTeX_Main-Regular.woff2`.
    private static func fontReferences(in css: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(css)
        while let open = rest.range(of: "url(") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { break }
            let value = rest[..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if value.hasSuffix(".woff2") { found.insert(value) }
            rest = rest[close...]
        }
        return found
    }

    // MARK: - it runs

    @MainActor
    private func boot(_ text: String) throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)
        webView.loadFileURL(
            Self.distURL.appendingPathComponent("index.html"),
            allowingReadAccessTo: Self.distURL)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? js("typeof window.loreEditor !== 'undefined'")) as? Bool == true { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        _ = try js("window.loreEditor.init(\(Self.jsString(text)))")
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

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    @MainActor
    func test_theVendoredBundleBootsAndHoldsTheDocument() throws {
        let doc = "# Title\n\nSome prose with `code` in it.\n"
        try boot(doc)
        XCTAssertEqual(try js("window.loreEditor.text()") as? String, doc)
    }

    /// THE assertion the spike did not make.
    ///
    /// CodeMirror's base theme sets `font-family: monospace` on `.cm-content`.
    /// The spike put the family on `.cm-editor`, lost on specificity, and
    /// rendered every document monospaced — while its S3 "theming passes"
    /// result covered only colour and size. That is the same defect M9 spent a
    /// milestone on: the font not being what the code appears to say. So the
    /// COMPUTED family is asserted here, not the stylesheet's intent.
    @MainActor
    func test_proseIsProportionalAndCodeIsNot() throws {
        try boot("Some prose with `code` in it.\n")
        let prose =
            try js("getComputedStyle(document.querySelector('.cm-content')).fontFamily")
            as? String ?? ""
        XCTAssertFalse(
            prose.contains("monospace"),
            "prose must not be monospaced — got \(prose)")
        XCTAssertTrue(
            prose.contains("system-ui") || prose.contains("apple-system"),
            "prose must use the host's text face — got \(prose)")

        // And code still IS monospaced, or the distinction carries nothing.
        //
        // Located by its TEXT, not by a class name. The first version of this
        // looked for `.tok-monospace`, which does not exist — CodeMirror's
        // HighlightStyle generates its own opaque class names — so the
        // selector fell through to "any span" and reported the font of
        // whatever that happened to be. It printed a plausible value and
        // asserted nothing, which is worse than no check at all.
        let mono =
            try js(
                """
                (() => {
                  const spans = [...document.querySelectorAll('.cm-content span')];
                  const el = spans.find(s => s.textContent === 'code');
                  return el ? getComputedStyle(el).fontFamily : 'NOT FOUND';
                })()
                """) as? String ?? ""
        XCTAssertTrue(
            mono.contains("mono") || mono.contains("Menlo"),
            "inline code must be monospaced — got \(mono)")
        print("BUNDLE prose=\(prose) code=\(mono)")
    }

    @MainActor
    func test_tablesStillRenderAsGridsFromTheVendoredCopy() throws {
        try boot("| A | B |\n|---|---|\n| one | two |\n")
        XCTAssertEqual(try js("window.loreEditor.tableCount()") as? Int, 1)
        XCTAssertEqual(try js("window.loreEditor.focusFirstCell()") as? Bool, true)
    }
}
