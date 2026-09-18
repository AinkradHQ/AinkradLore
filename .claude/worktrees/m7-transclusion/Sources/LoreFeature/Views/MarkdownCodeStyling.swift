import AppKit
import SwiftUI
import AinkradAppKit

/// Syntax colouring inside a fenced code block.
///
/// Split out of `MarkdownStyleRendering.swift`, which reached the 500-line
/// ceiling when this landed. The division is real rather than arbitrary: that
/// file turns MARKDOWN structure into attributes, and this one turns CODE
/// structure into attributes, using a scanner (`CodeHighlighter`) and a table
/// (`CodeGrammar`) that know nothing about markdown at all.
extension MarkdownStyleRenderer {

    // MARK: - Code highlighting

    /// Colours the tokens inside a fence.
    ///
    /// Only ever ADDS a foreground colour (and italics for comments) on top of
    /// the monospaced font the code case already applied — it does not touch
    /// the paragraph style, the panel, or anything structural, so it cannot
    /// disturb the block's geometry.
    ///
    /// Scans the whole span, opening fence included. The fence line is
    /// ```` ```swift ````, which contains nothing the scanner will tokenise (a
    /// backtick is not a word character and `swift` is not a keyword in the
    /// table), and the language label is restyled straight afterwards
    /// regardless — so excluding it would be bookkeeping with no observable
    /// difference.
    static func highlightCode(in r: NSRange, grammar: CodeGrammar,
                              storage: NSTextStorage, tokens: HostThemeTokens) {
        let text = storage.string as NSString
        let palette = CodePalette(tokens: tokens)
        for token in CodeHighlighter.tokens(in: text, range: r, grammar: grammar) {
            let range = NSRange(location: token.range.lowerBound,
                                length: token.range.count)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: palette.colour(for: token.kind),
                                 range: range)
            // Comments in italic as well as colour, so they stay legible as
            // asides on a display where the tint is hard to separate — the same
            // reason the accessibility pass stopped using colour alone.
            if token.kind == .comment {
                composeFont(in: range, storage: storage) { current in
                    Self.applying(Self.inheritedTraits(of: current).union(.italicFontMask),
                                  to: current)
                }
            }
        }
    }

    /// Syntax colours: fixed hues, theme-derived brightness.
    ///
    /// The same trade `MarkdownCallout` makes, for the same reason. These are
    /// SEMANTIC — a reader who knows one editor expects strings and comments to
    /// keep their familiar families — but a palette picked for a dark surface
    /// is unreadable on a light one, so only the hue is fixed.
    ///
    /// Deliberately NOT the theme's accents. `accent` means "you can click
    /// this" everywhere else in Lore, and spending it on a `func` keyword would
    /// make every code block look full of links.
    struct CodePalette {
        let comment: NSColor
        let string: NSColor
        let number: NSColor
        let keyword: NSColor
        let type: NSColor

        init(tokens: HostThemeTokens) {
            let onDark = MarkdownBlockBackgrounds.Palette.isDarkSurface(tokens: tokens)
            func hued(_ hue: CGFloat) -> NSColor {
                NSColor(hue: hue / 360,
                        saturation: onDark ? 0.50 : 0.72,
                        brightness: onDark ? 0.95 : 0.66,
                        alpha: 1)
            }
            // Comments are quiet foreground rather than a hue: they are the one
            // token kind meant to recede.
            comment = NSColor(tokens.foreground).withAlphaComponent(0.45)
            string = hued(140)      // green
            number = hued(30)       // orange
            keyword = hued(285)     // violet
            type = hued(200)        // blue
        }

        func colour(for kind: CodeToken.Kind) -> NSColor {
            switch kind {
            case .comment: return comment
            case .string: return string
            case .number: return number
            case .keyword: return keyword
            case .type: return type
            }
        }
    }

    /// Styles the info string (`swift` in an opening ```` ```swift ```` line)
    /// as a trailing label on that line, distinct from the block's body.
    ///
    /// `CodeBlock.range` covers the opening fence line itself (verified in
    /// `test_codeBlockSpanRangeIncludesTheOpeningFence`), so the language text
    /// is real characters already inside `r` — no attachment, no overlay
    /// drawing, no second pass over the layout manager. The label is found by
    /// locating the block's first line and searching it for `language`, which
    /// is safe because CommonMark's info string is exactly that word (an
    /// identifier, no spaces) immediately after the fence run.
    static func styleLanguageLabel(_ language: String, in r: NSRange,
                                           storage: NSTextStorage, tokens: HostThemeTokens) {
        let full = storage.string as NSString
        let limit = NSMaxRange(r)
        var lineEnd = r.location
        while lineEnd < limit, full.character(at: lineEnd) != 0x0A { lineEnd += 1 }
        let fenceLine = NSRange(location: r.location, length: lineEnd - r.location)
        guard fenceLine.length > 0 else { return }
        let lineText = full.substring(with: fenceLine)
        guard let langRange = lineText.range(of: language, options: .backwards) else { return }
        let nsLangRange = NSRange(langRange, in: lineText)
        let labelRange = NSRange(location: fenceLine.location + nsLangRange.location,
                                 length: nsLangRange.length)
        guard NSMaxRange(labelRange) <= full.length else { return }
        storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: labelRange)
        storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentTertiary), range: labelRange)
    }
}
