import AppKit
import XCTest

@testable import LoreFeature

/// Pins `MarkdownStyleRenderer.apply`'s output byte for byte: the parity
/// document's spans rendered into an `NSTextStorage`, every attribute run
/// dumped to text, compared with `Tests/Fixtures/style-golden.txt`.
///
/// Written before 5B.7 split the renderer, so the splits and 5B.8's token
/// mapping can each prove they changed nothing. A mismatch writes the actual
/// dump next to the temporary directory and names it in the failure.
@MainActor
final class MarkdownStyleGoldenTests: XCTestCase {

    private final class BundleToken {}

    func test_theParityDocumentRendersToTheGoldenAttributes() throws {
        let text = CM6ParityShotTests.parityDocument
        let storage = NSTextStorage(string: text)
        let tokens = TestTokens.make()
        MarkdownStyleRenderer.apply(
            MarkdownStyleCache.derive(text).spans, to: storage,
            tokens: tokens, theme: MarkdownTheme(tokens: tokens), limitedTo: nil)
        let actual = Self.dump(storage)

        let url = try XCTUnwrap(
            Bundle(for: BundleToken.self).url(forResource: "style-golden", withExtension: "txt"),
            "style-golden.txt is missing from the test bundle")
        let expected = try String(contentsOf: url, encoding: .utf8)
        if actual != expected {
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("style-golden.actual.txt")
            try actual.write(to: out, atomically: true, encoding: .utf8)
            XCTFail("styled attributes differ from style-golden.txt; actual dump at \(out.path)")
        }
    }

    // MARK: - The dump

    /// One block per attribute run: its range and text, then each attribute
    /// sorted by key. Values are printed by content, never by identity.
    static func dump(_ storage: NSTextStorage) -> String {
        var out = ""
        let string = storage.string as NSString
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            out += "[\(range.location),\(NSMaxRange(range))) \(escape(string.substring(with: range)))\n"
            for key in attrs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                out += "  \(key.rawValue) = \(describe(attrs[key]))\n"
            }
        }
        return out
    }

    private static func escape(_ text: String) -> String {
        "\""
            + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let font as NSFont:
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weight = (traits?[.weight] as? NSNumber).map { number(CGFloat($0.doubleValue)) } ?? "-"
            return "font(\(font.fontName) \(number(font.pointSize)) "
                + "traits=\(font.fontDescriptor.symbolicTraits.rawValue) weight=\(weight))"
        case let color as NSColor:
            guard let rgb = color.usingColorSpace(.sRGB) else { return stripAddresses("\(color)") }
            return "rgba(\(number(rgb.redComponent)) \(number(rgb.greenComponent)) "
                + "\(number(rgb.blueComponent)) \(number(rgb.alphaComponent)))"
        case let value?:
            return stripAddresses(String(describing: value))
        case nil:
            return "nil"
        }
    }

    private static func stripAddresses(_ text: String) -> String {
        text.replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x?", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
    }
}
