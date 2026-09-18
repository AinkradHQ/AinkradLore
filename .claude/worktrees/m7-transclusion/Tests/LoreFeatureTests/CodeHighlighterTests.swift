import XCTest
import AppKit
import SwiftUI
@testable import LoreFeature

/// Syntax highlighting inside a fence.
///
/// The scanner is pure, so most of this asserts it directly. What it asserts
/// hardest is ORDER — comments before strings, strings before words — because
/// every way a highlighter goes badly wrong is an ordering mistake, and each
/// one paints a large region the wrong colour rather than failing quietly.
final class CodeHighlighterTests: XCTestCase {

    private func tokens(_ code: String, _ language: String) -> [(String, CodeToken.Kind)] {
        guard let grammar = CodeGrammar.named(language) else { return [] }
        let ns = code as NSString
        return CodeHighlighter
            .tokens(in: ns, range: NSRange(location: 0, length: ns.length), grammar: grammar)
            .map { (ns.substring(with: NSRange(location: $0.range.lowerBound,
                                               length: $0.range.count)), $0.kind) }
    }

    private func kinds(_ code: String, _ language: String,
                       of text: String) -> [CodeToken.Kind] {
        tokens(code, language).filter { $0.0 == text }.map(\.1)
    }

    // MARK: - Order is the algorithm

    /// A string INSIDE a comment is part of the comment. Scanning strings first
    /// would end the comment at the quote and paint the rest of the line as
    /// code.
    func test_aQuoteInsideACommentDoesNotStartAString() {
        let found = tokens("// don't stop here\nlet x = 1\n", "swift")
        XCTAssertEqual(found.first?.0, "// don't stop here")
        XCTAssertEqual(found.first?.1, .comment)
        XCTAssertEqual(kinds("// don't stop here\nlet x = 1\n", "swift", of: "let"), [.keyword],
                       "the code after the comment must still be scanned normally")
    }

    /// And the mirror: a comment marker inside a string is text.
    func test_aCommentMarkerInsideAStringDoesNotStartAComment() {
        let code = "let url = \"https://example.com\"\nlet y = 2\n"
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.0 == "\"https://example.com\"" && $0.1 == .string },
                      "the whole URL is one string; its // must not open a comment")
        XCTAssertEqual(kinds(code, "swift", of: "let"), [.keyword, .keyword],
                       "both lines must still scan as code")
    }

    /// A keyword that is only PART of a word is not a keyword.
    func test_aKeywordMustBeAWholeWord() {
        XCTAssertEqual(kinds("classy.className = 1\n", "swift", of: "class"), [],
                       "`classy` and `className` contain `class` and are not keywords")
    }

    /// Longest-first matching, which the grammar sorts for. `--` is one SQL
    /// comment marker, not two minus signs.
    func test_longerCommentMarkersWinOverShorterOnes() {
        let found = tokens("SELECT 1 -- a note\n", "sql")
        XCTAssertTrue(found.contains { $0.0 == "-- a note" && $0.1 == .comment })
    }

    /// The same rule for delimiters: `"""` must be tried before `"`, or a Swift
    /// multi-line string closes on its own opening quotes.
    func test_aTripleQuotedStringIsOneToken() {
        let code = "let s = \"\"\"\nline one\nline two\n\"\"\"\n"
        let found = tokens(code, "swift")
        let strings = found.filter { $0.1 == .string }
        XCTAssertEqual(strings.count, 1, "a multi-line string is ONE token, not three")
        XCTAssertTrue(strings.first?.0.contains("line two") == true)
    }

    // MARK: - Not swallowing the file

    /// An unterminated single-quote string stops at the end of its line. The
    /// failure this prevents is the whole rest of a snippet turning into a
    /// string because someone wrote an apostrophe.
    func test_anUnterminatedStringStopsAtTheLineEnd() {
        let code = "print('it's broken)\nx = 1\ny = 2\n"
        let found = tokens(code, "python")
        for (text, kind) in found where kind == .string {
            XCTAssertFalse(text.contains("\n"),
                           "an unterminated single-line string must not cross a line")
        }
        XCTAssertEqual(kinds(code, "python", of: "1").count, 1,
                       "code after the bad line must still scan")
    }

    /// An escaped delimiter does not close the string.
    func test_anEscapedQuoteDoesNotCloseTheString() {
        let found = tokens("let s = \"a\\\"b\" + t\n", "swift")
        XCTAssertTrue(found.contains { $0.0 == "\"a\\\"b\"" && $0.1 == .string })
    }

    // MARK: - Per language

    func test_pythonUsesHashComments() {
        XCTAssertEqual(tokens("# note\ndef f(): pass\n", "python").first?.1, .comment)
        XCTAssertEqual(kinds("# note\ndef f(): pass\n", "python", of: "def"), [.keyword])
    }

    /// `#` is a COMMENT in shell and part of a WORD in C (`#include`). The same
    /// character, opposite meanings — the case that makes a shared fallback
    /// grammar unsafe and is why an unknown language gets none.
    func test_hashMeansDifferentThingsInDifferentLanguages() {
        XCTAssertEqual(tokens("# a note\n", "bash").first?.1, .comment)
        XCTAssertEqual(kinds("#include <stdio.h>\n", "c", of: "#include"), [.keyword])
    }

    func test_anUnknownLanguageIsNotHighlighted() {
        XCTAssertNil(CodeGrammar.named("brainfuck"))
        XCTAssertEqual(tokens("let x = 1\n", "brainfuck").count, 0)
    }

    func test_languageAliasesResolve() {
        for (alias, sample) in [("js", "const"), ("ts", "interface"), ("py", "def"),
                                ("rs", "fn"), ("yml", "true"), ("sh", "echo")] {
            XCTAssertNotNil(CodeGrammar.named(alias), "\(alias) must resolve")
            XCTAssertEqual(kinds("\(sample) x\n", alias, of: sample), [.keyword],
                           "\(alias) must highlight \(sample)")
        }
    }

    /// Hyphens are word characters in CSS and operators everywhere else.
    /// Getting this wrong silently stops keywords being recognised after any
    /// subtraction.
    func test_hyphensJoinWordsOnlyWhereTheLanguageSaysSo() {
        XCTAssertEqual(kinds("a { font-face: x }\n", "css", of: "font-face"), [.keyword],
                       "font-face is ONE word in CSS, and so matches the keyword table; "
                       + "split at the hyphen it would match nothing")
        XCTAssertEqual(kinds("let y = count-1\nreturn y\n", "swift", of: "return"), [.keyword],
                       "a subtraction must not glue words together in Swift")
    }

    func test_numbersAreFoundAndWordsContainingDigitsAreNot() {
        XCTAssertEqual(kinds("let a = 42\n", "swift", of: "42"), [.number])
        XCTAssertEqual(tokens("let foo2 = 1\n", "swift").filter { $0.0 == "2" }.count, 0,
                       "`foo2` is one identifier, not a word and a number")
    }

    func test_typesAreDistinguishedFromKeywords() {
        XCTAssertEqual(kinds("let a: String = b\n", "swift", of: "String"), [.type])
        XCTAssertEqual(kinds("let a: String = b\n", "swift", of: "let"), [.keyword])
    }

    /// A fence longer than the cap is skipped rather than scanned. The cap is
    /// the one thing standing between a pasted log file and a per-render scan
    /// that grows with it.
    func test_aVeryLongFenceIsSkipped() {
        let huge = String(repeating: "let x = 1\n", count: 6_000)
        XCTAssertGreaterThan((huge as NSString).length, CodeHighlighter.maximumLength)
        XCTAssertEqual(tokens(huge, "swift").count, 0)
    }

    // MARK: - Wiring, end to end

    /// The tokens must reach the STORAGE. Everything above tests a pure
    /// function, which a renderer that never calls it would also pass.
    @MainActor
    func test_aFenceInARealEditorIsActuallyColoured() throws {
        let body = "intro\n\n```swift\n// a comment\nlet x = \"hi\"\n```\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let ns = body as NSString
            func colour(at text: String) throws -> NSColor {
                let range = ns.range(of: text)
                XCTAssertNotEqual(range.location, NSNotFound, "fixture must contain \(text)")
                return try XCTUnwrap(storage.attribute(.foregroundColor, at: range.location,
                                                        effectiveRange: nil) as? NSColor)
                    .usingColorSpace(.sRGB)!
            }
            let comment = try colour(at: "// a comment")
            let string = try colour(at: "\"hi\"")
            let keyword = try colour(at: "let x")

            func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
            }
            XCTAssertGreaterThan(distance(comment, keyword), 0.15,
                                 "a comment and a keyword must not be the same colour")
            XCTAssertGreaterThan(distance(string, keyword), 0.15,
                                 "a string and a keyword must not be the same colour")

            // And the comment carries italics too, so the distinction is not
            // colour alone.
            let commentRange = ns.range(of: "// a comment")
            let font = try XCTUnwrap(storage.attribute(.font, at: commentRange.location,
                                                        effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic),
                          "a comment must be italic as well as tinted")
        }
    }

    /// Prose OUTSIDE the fence must be untouched — the scanner is handed the
    /// code block's range and must not colour the paragraph after it.
    @MainActor
    func test_highlightingStaysInsideTheFence() throws {
        let body = "```swift\nlet x = 1\n```\n\nlet me explain in prose.\n"
        var stored = body
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = body
        coordinator.textView = tv
        coordinator.applyStyles()

        try withExtendedLifetime(coordinator) {
            let storage = try XCTUnwrap(tv.textStorage)
            let ns = body as NSString
            // The `let` in the PROSE line, which is an English word here.
            let prose = ns.range(of: "let me explain")
            let proseColour = try XCTUnwrap(
                storage.attribute(.foregroundColor, at: prose.location,
                                  effectiveRange: nil) as? NSColor).usingColorSpace(.sRGB)!
            let bodyColour = NSColor(TestTokens.make().foreground).usingColorSpace(.sRGB)!
            XCTAssertEqual(proseColour.redComponent, bodyColour.redComponent, accuracy: 0.01)
            XCTAssertEqual(proseColour.greenComponent, bodyColour.greenComponent, accuracy: 0.01)
            XCTAssertEqual(proseColour.blueComponent, bodyColour.blueComponent, accuracy: 0.01)
        }
    }
}
