import AinkradAppKit
import Foundation
import XCTest

@testable import LoreFeature

/// The drift guard between the skin and the CM6 stylesheet (5B.9).
///
/// `index.html` declares every variable once in `:root` so a first paint
/// before the push looks right — a hand-copied block, which is exactly what
/// drifts. These two hold it: the defaults ARE the bridge's output for the
/// default skin, and nothing in the page reads a variable nobody sets.
final class CM6ThemeBridgeTests: XCTestCase {

    private static var defaultVariables: [String: String] {
        let skin = AinkradSkin.standard
        let theme = MarkdownTheme(tokens: HostThemeTokens(skin: skin), skin: skin)
        return CM6ThemeBridge.cssVariables(skin: skin, theme: theme)
    }

    /// The shipped page and bundle, not the sources: what is checked is what
    /// the plugin loads.
    @MainActor
    private func shipped(_ name: String, _ ext: String) throws -> String {
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        let url = index.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    private func rootDefaults() throws -> [String: String] {
        let html = try shipped("index", "html")
        let open = try XCTUnwrap(html.range(of: ":root {"))
        let close = try XCTUnwrap(html.range(of: "}", range: open.upperBound..<html.endIndex))
        var declared: [String: String] = [:]
        for declaration in html[open.upperBound..<close.lowerBound].split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertNil(declared[name], "\(name) is declared twice")
            declared[name] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return declared
    }

    @MainActor
    func test_rootDefaultsAreTheBridgeOutputForTheDefaultSkin() throws {
        let declared = try rootDefaults()
        let emitted = Self.defaultVariables
        XCTAssertFalse(emitted.isEmpty)
        for (name, value) in emitted.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(declared[name], value, "\(name) in :root")
        }
        let stale = Set(declared.keys).subtracting(emitted.keys).sorted()
        XCTAssertEqual(stale, [], ":root declares variables the bridge never sets")
        if declared != emitted {
            // The block to paste into `Editor/src/index.html`, then `make editor`.
            let block = emitted.sorted { $0.key < $1.key }.map { "    \($0.key): \($0.value);" }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cm6-root.css")
            try block.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            XCTFail("regenerate :root from \(url.path)")
        }
    }

    @MainActor
    func test_everyVariableThePageReadsIsDeclaredOrEmitted() throws {
        let html = try shipped("index", "html")
        let script = try shipped("editor", "js")
        func names(_ pattern: String, in text: String) throws -> Set<String> {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            return Set(
                regex.matches(in: text, range: range).compactMap {
                    Range($0.range(at: 1), in: text).map { String(text[$0]) }
                })
        }
        let used = try names(#"var\((--[A-Za-z0-9-]+)"#, in: html + script)
        let declared = try names(#"(--[A-Za-z0-9-]+)\s*:"#, in: html)
        let unset = used.subtracting(declared).subtracting(Self.defaultVariables.keys).sorted()
        XCTAssertFalse(used.isEmpty)
        XCTAssertEqual(unset, [], "read by the page but set by nothing")
    }

    /// A family name with a quote must survive the trip into JavaScript.
    func test_thePushScriptCarriesValuesAsJSON() {
        let script = CM6ThemeBridge.pushScript(["--x": "a 'quoted' \"family\""])
        XCTAssertTrue(script.contains(#""--x":"a 'quoted' \"family\"""#), script)
    }
}
