import Foundation
import Markdown

/// Walks the AST ONCE, collecting the source ranges of code and — in the same
/// pass, see `MarkdownSpanBuilder.swift` for the prose visits — the style spans.
///
/// A node whose `range` is nil contributes nothing rather than guessing — a
/// dropped range means a link inside that code is treated as a real link, which
/// is a visible wrong answer, whereas a GUESSED range could suppress a real
/// link silently. Neither is good; the visible one is preferable.
///
/// `SourceRange` is `Range<SourceLocation>` and swift-markdown has ALREADY
/// converted cmark's inclusive end column into an exclusive one (it adds 1 in
/// `CommonMarkConverter.range(_:)`), so `upperBound.column` is passed straight
/// through to `SourceOffsetMap.utf16Range`, which also treats `toColumn` as
/// exclusive. Adding a further +1 here would overrun every node by one unit.
struct MarkdownASTCollector: MarkupWalker {
    let map: SourceOffsetMap
    /// The FULL text, used to tell a fenced code block from an indented one
    /// (see `isFenced(at:code:)`) and to locate a task item's checkbox marker.
    let text: NSString
    var regions: [CodeRegion] = []
    var styleSpans: [StyleSpan] = []
    var outline: [OutlineEntry] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let ns = resolve(codeBlock.range) else { return }
        regions.append(
            CodeRegion(
                range: ns,
                kind: isFenced(at: ns, code: codeBlock.code)
                    ? .fencedCodeBlock : .indentedCodeBlock))
        styleSpans.append(
            StyleSpan(
                range: swiftRange(ns),
                kind: .codeBlock(language: codeBlock.language)))
        // Only a FENCED block has fence lines; an indented one yields nothing.
        appendMarkers(MarkdownMarkers.fences(in: ns, text: text), .codeFence)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let ns = resolve(inlineCode.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .inlineCode))
        styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .inlineCode))
        appendMarkers(MarkdownMarkers.backtickPair(in: ns, text: text), .inlineCode)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let ns = resolve(html.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .htmlBlock))
    }

    /// Fenced or indented? swift-markdown models both as `CodeBlock`, and
    /// `language` / `fenceInfo` is nil for a bare ``` opener as well as for
    /// indented code, so neither can discriminate.
    ///
    /// `CodeBlock.range` starts at the block's CONTENT, never at column 1 — a
    /// 4-space indented block reports its start already PAST the indent. So
    /// leading whitespace is invisible here, and column arithmetic cannot help
    /// either: a fence nested in a list and an indented code block both report
    /// column 5. The discriminator has to be the text itself, in two parts.
    ///
    /// 1. The range must START with a run of 3+ backticks or tildes. Necessary,
    ///    not sufficient — an INDENTED block whose first content line happens to
    ///    be ```` ``` ```` also satisfies it, and reading that as a fence made
    ///    the block suppress links, which the owner's ruling forbids.
    /// 2. So: reject when the block's own CONTENT contains a line that would
    ///    have CLOSED that fence — a bare run of the same character, at least as
    ///    long. CommonMark guarantees a real fenced block can never contain such
    ///    a line, because it would have terminated the block. Only an indented
    ///    block can. `[[X]]` inside `"    ```\n    [[X]]\n    ```"` therefore
    ///    stays a link, while ```` ```` ````-fenced content containing ```` ``` ````
    ///    (a shorter run) is still correctly fenced.
    ///
    /// Every content line is checked, not just the first: an indented block may
    /// open with an info-string line (`    ```swift`), which is not itself a
    /// closer, and only reveal the bare closer further down.
    ///
    /// "Bare" matters: ` ```text ` does not close a fence, so a fenced block MAY
    /// contain it, and it must not be mistaken for indented code.
    ///
    /// KNOWN LIMIT — an accepted REGRESSION against the old scanner.
    ///
    /// An indented block whose first line is fence-shaped WITH an info string,
    /// and which never contains a line that closes THAT run, still reads as
    /// fenced and suppresses. The old scanner required `indent <= 3` on the raw
    /// line, so it saw these as ordinary text and kept the link; we drop it.
    /// Direction is link rot: the link leaves the graph and a rename stops
    /// rewriting it. Accepted by the owner — the shapes are rare in prose and
    /// the alternative risks the fence direction, which is verified sound.
    ///
    /// The class is wider than "unterminated". All five measured members, each
    /// yielding `["X"]` from the old scanner and `[]` from this one:
    ///
    ///   1. unterminated:            `"    ```swift\n    [[X]]\n"`
    ///   2. closer indented further: `"    ```swift\n    [[X]]\n     ```\n"`
    ///   3. closer SHORTER than the opener:
    ///                               `"    ````js\n    [[X]]\n    ```\n"`
    ///   4. closer of the WRONG character:
    ///                               `"    ~~~x\n    [[X]]\n    ```\n"`
    ///   5. info line alone:         `"    ```swift\n"` — same misclassification,
    ///      though it holds no link, so no link is actually lost.
    ///
    /// 3 and 4 are worth naming separately: they are not "unterminated" at all —
    /// they have a closing-looking line that simply does not close the opener's
    /// run, so `code` never contains a qualifying bare closer.
    ///
    /// A block with a MATCHING bare closer is classified correctly and is NOT
    /// part of this class: `"    ```swift\n    [[X]]\n    ```\n"` keeps `[[X]]`,
    /// matching the old scanner exactly.
    private func isFenced(at range: NSRange, code: String) -> Bool {
        guard let marker = leadingFenceRun(in: sourceLine(at: range)) else {
            return false
        }
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if let closer = leadingFenceRun(in: String(line)),
                closer.character == marker.character,
                closer.length >= marker.length,
                closer.isBare
            {
                return false
            }
        }
        return true
    }

    /// The source text from `range`'s start to the end of that line.
    private func sourceLine(at range: NSRange) -> String {
        var end = range.location
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        guard end > range.location else { return "" }
        return text.substring(
            with: NSRange(
                location: range.location,
                length: end - range.location))
    }

    private func leadingFenceRun(in line: String)
        -> (character: Character, length: Int, isBare: Bool)?
    {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let rest = line[run.endIndex...]
        return (first, run.count, rest.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" })
    }

    func resolve(_ sourceRange: SourceRange?) -> NSRange? {
        guard let r = sourceRange else { return nil }
        return map.utf16Range(
            fromLine: r.lowerBound.line,
            fromColumn: r.lowerBound.column,
            toLine: r.upperBound.line,
            toColumn: r.upperBound.column)
    }
}
