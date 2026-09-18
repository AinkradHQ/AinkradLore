import Foundation

/// `$inline$` and `$$block$$` math.
///
/// ## What this deliberately is not
///
/// It is not a TeX renderer, and it does not pretend to be one. Obsidian ships
/// MathJax; there is no equivalent for AppKit that does not drag in a web view,
/// and the one thing this editor may never do is CHANGE THE TEXT — every
/// offset the index, the link graph and the MCP tools hold is measured against
/// it. That rules out the whole substitution family: `\alpha` cannot become
/// `α`, because `α` is a character the document does not contain.
///
/// So the expression is COLLAPSED and DRAWN instead. `MathParser` turns the
/// source into a tree, `MathLayout` turns the tree into a box of positioned
/// glyphs, `.kern` on the collapsed run reserves exactly the box's width, and
/// the box is painted into the gap. Every one of those techniques is already
/// load-bearing elsewhere in this editor — marker collapse, table alignment,
/// the drawn list marker and callout heading — and none of them touches a
/// character of the document.
///
/// ## The rule is all-or-nothing per expression
///
/// An expression is drawn only when EVERY part of it parses. Anything
/// containing a construct the parser refuses is left as source and merely
/// tinted, so it still reads as mathematics rather than as prose.
/// Half-rendering — `α` drawn but `\frac{a}{b}` left raw inside the same
/// expression — would be worse than either, because the reader could no longer
/// tell which parts are notation and which are content.
enum MarkdownMath {

    struct Span: Equatable {
        /// The whole expression, delimiters included.
        let range: Range<Int>
        /// Between the delimiters.
        let content: Range<Int>
        let isBlock: Bool
        /// The parsed tree, or `nil` when this expression contains something
        /// that cannot be drawn exactly. `nil` means the source is shown and
        /// merely tinted — see the type comment.
        let tree: MathNode?

        var isRenderable: Bool { tree != nil }
    }

    /// Finds every math expression in `text`.
    ///
    /// - Parameter isSuppressed: answers whether an offset sits inside a code
    ///   region. A `$` in a shell fence is a variable, not mathematics, and
    ///   `$PATH` would otherwise open an expression that runs to the next `$`
    ///   in the file.
    static func spans(in text: NSString,
                      isSuppressed: (Int) -> Bool = { _ in false }) -> [Span] {
        var out: [Span] = []
        var index = 0
        while index < text.length {
            guard text.character(at: index) == 0x24, !isSuppressed(index) else {
                index += 1
                continue
            }
            let isBlock = index + 1 < text.length && text.character(at: index + 1) == 0x24
            let width = isBlock ? 2 : 1
            guard let close = closingDelimiter(from: index + width, width: width,
                                               isBlock: isBlock, in: text) else {
                index += 1
                continue
            }
            let content = (index + width)..<close
            let whole = index..<(close + width)
            let source = text.substring(with: NSRange(location: content.lowerBound,
                                                      length: content.count))
            out.append(Span(range: whole, content: content, isBlock: isBlock,
                            tree: MathParser.parse(source)))
            index = close + width
        }
        return out
    }

    /// The matching closing delimiter, or `nil`.
    ///
    /// The two rules that keep prose out: an expression may not be empty, and
    /// its closing delimiter may not be preceded by a space. Together they are
    /// what stops `costs $5 and $7` from reading as the expression `5 and ` —
    /// the candidate closer is preceded by a space, so it is rejected, and the
    /// scan moves on rather than swallowing the line.
    ///
    /// An INLINE expression may not cross a line either. A stray `$` in prose
    /// would otherwise reach for one three paragraphs down and tint everything
    /// between.
    private static func closingDelimiter(from start: Int, width: Int, isBlock: Bool,
                                         in text: NSString) -> Int? {
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            if !isBlock, unit == 0x0A || unit == 0x0D { return nil }
            if unit == 0x5C { index += 2; continue }               // \$ is a literal
            if unit == 0x24 {
                let matches = width == 1
                    || (index + 1 < text.length && text.character(at: index + 1) == 0x24)
                if matches, index > start,
                   !isSpace(text.character(at: index - 1)) { return index }
            }
            index += 1
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}


/// The editor's math spans.
///
/// An extension rather than a member of `MarkdownDocumentModel`: math is not
/// CommonMark, the model never saw it, and that file reached its length ceiling
/// carrying something that was never really its subject.
extension MarkdownDocumentModel {
    /// `$…$` spans, derived on demand for the same reason `wikilinkSpans` is:
    /// math is not CommonMark, so the AST never saw it.
    ///
    /// Code regions are handed over so a `$PATH` in a shell fence cannot open
    /// an expression — the same suppression the link scanner uses, for the same
    /// class of false positive.
    public var mathSpans: [StyleSpan] {
        let text = fullText as NSString
        var out: [StyleSpan] = []
        for span in MarkdownMath.spans(in: text, isSuppressed: { isInsideCode(utf16Offset: $0) }) {
            out.append(StyleSpan(range: span.range,
                                 kind: .math(isRendered: span.isRenderable)))
            // A drawable expression collapses WHOLE — delimiters, commands and
            // all — because the drawn box stands in for the entire thing.
            // Collapsing only the syntax would leave `frac` and its braces on
            // screen underneath the fraction.
            if span.isRenderable {
                out.append(StyleSpan(range: span.range, kind: .marker(of: .math)))
            }
        }
        return out
    }
}
