import Foundation

/// Obsidian callouts: `> [!note] An optional title`.
///
/// A callout is a block quote whose first line opens with `[!type]`. It is not
/// CommonMark and swift-markdown does not know about it, so — exactly as with
/// wikilinks — the AST gives us the quote and this gives us what the quote
/// MEANS. Kept pure and text-only so the rule can be asserted directly rather
/// than through a text view.
public enum MarkdownCallout {

    /// The callout types Obsidian ships, each with the spellings it accepts.
    ///
    /// The aliases are not decoration: a vault written against Obsidian will
    /// contain `[!tldr]` and `[!warning]` interchangeably with `[!abstract]`
    /// and `[!caution]`, and a type Lore does not recognise falls back to a
    /// plain quote — which is a silent downgrade the author would have to
    /// notice for themselves. Cheaper to accept all of them.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case note, abstract, info, todo, tip, success
        case question, warning, failure, danger, bug, example, quote

        /// The type name as written, mapped to a kind. Case-insensitive,
        /// because Obsidian's is.
        public static func named(_ raw: String) -> Kind? {
            switch raw.lowercased() {
            case "note": return .note
            case "abstract", "summary", "tldr": return .abstract
            case "info": return .info
            case "todo": return .todo
            case "tip", "hint", "important": return .tip
            case "success", "check", "done": return .success
            case "question", "help", "faq": return .question
            case "warning", "caution", "attention": return .warning
            case "failure", "fail", "missing": return .failure
            case "danger", "error": return .danger
            case "bug": return .bug
            case "example": return .example
            case "quote", "cite": return .quote
            default: return nil
            }
        }

        /// What to show when the author gave no title of their own.
        ///
        /// Obsidian always shows a heading — `> [!note]` alone renders as
        /// "Note" — so this is not a nicety. It is DRAWN rather than inserted:
        /// putting it in the text would change the document, and every offset
        /// the index and the link graph hold with it.
        public var displayTitle: String {
            switch self {
            case .note: return "Note"
            case .abstract: return "Abstract"
            case .info: return "Info"
            case .todo: return "Todo"
            case .tip: return "Tip"
            case .success: return "Success"
            case .question: return "Question"
            case .warning: return "Warning"
            case .failure: return "Failure"
            case .danger: return "Danger"
            case .bug: return "Bug"
            case .example: return "Example"
            case .quote: return "Quote"
            }
        }

        /// The SF Symbol drawn beside the title.
        public var symbolName: String {
            switch self {
            case .note: return "pencil"
            case .abstract: return "doc.text"
            case .info: return "info.circle"
            case .todo: return "checkmark.circle"
            case .tip: return "flame"
            case .success: return "checkmark"
            case .question: return "questionmark.circle"
            case .warning: return "exclamationmark.triangle"
            case .failure: return "xmark"
            case .danger: return "bolt"
            case .bug: return "ant"
            case .example: return "list.bullet"
            case .quote: return "quote.opening"
            }
        }

        /// Hue in degrees, for the bar, the panel tint and the title.
        ///
        /// A fixed hue rather than a theme token, and deliberately: a callout's
        /// colour is SEMANTIC — danger is red in every theme, or it is not
        /// saying "danger" — in the same way syntax colouring is. Saturation
        /// and brightness are derived from the theme so the result still sits
        /// correctly on a light or a dark surface; see
        /// `MarkdownBlockBackgrounds.Palette`.
        public var hue: CGFloat {
            switch self {
            case .note, .info: return 210      // blue
            case .abstract, .tip: return 175   // teal
            case .todo, .question: return 45   // amber
            case .success: return 140          // green
            case .warning: return 30           // orange
            case .failure, .danger: return 0   // red
            case .bug: return 350              // crimson
            case .example: return 275          // violet
            case .quote: return 0              // neutral, see isNeutral
            }
        }

        /// `quote` is a callout with no colour of its own — Obsidian renders it
        /// as an ordinary quote with a heading. Its `hue` is meaningless.
        public var isNeutral: Bool { self == .quote }
    }

    /// What a callout's opening line contains.
    public struct Header: Equatable, Sendable {
        public let kind: Kind
        /// The `[!type]` text, INCLUDING the brackets, in absolute UTF-16
        /// offsets. Collapsed by the same marker machinery that hides `**`.
        public let markerRange: Range<Int>
        /// The author's own title, if they wrote one — the rest of the first
        /// line after the marker, trimmed. Empty when they did not, in which
        /// case `kind.displayTitle` is drawn instead.
        public let titleRange: Range<Int>?
        /// Whether the author wrote a fold marker (`[!note]-` / `[!note]+`).
        /// Parsed so the syntax does not render as stray punctuation; folding
        /// itself is not implemented.
        public let isFoldable: Bool
    }

    /// Reads the header out of a block quote whose absolute range is `range`.
    ///
    /// Returns `nil` for an ordinary quote, which is the overwhelmingly common
    /// case and must stay cheap: the scan gives up at the first character that
    /// cannot begin `[!`.
    ///
    /// - Parameters:
    ///   - range: the quote's own UTF-16 range, as the AST resolved it.
    ///   - text: the WHOLE editor string, which `range` indexes.
    public static func header(ofQuoteAt range: Range<Int>, in text: NSString) -> Header? {
        guard range.lowerBound >= 0, range.upperBound <= text.length,
              range.lowerBound < range.upperBound else { return nil }
        // The quote's first line only. A `[!note]` on line three is prose.
        let firstLine = text.lineRange(for: NSRange(location: range.lowerBound, length: 0))
        let lineEnd = min(NSMaxRange(firstLine), range.upperBound)
        var index = range.lowerBound

        // Skip the quote markers and the space after them. More than one `>`
        // is a nested quote, and Obsidian reads the callout at the depth it is
        // written, so every `>` is consumed rather than just the first.
        while index < lineEnd {
            let unit = text.character(at: index)
            if unit == 0x3E || unit == 0x20 || unit == 0x09 { index += 1 } else { break }
        }
        guard index + 2 < lineEnd,
              text.character(at: index) == 0x5B,        // [
              text.character(at: index + 1) == 0x21     // !
        else { return nil }

        // The type name runs to the closing bracket, on this line.
        var close = index + 2
        while close < lineEnd, text.character(at: close) != 0x5D { close += 1 }
        guard close < lineEnd else { return nil }
        let name = text.substring(with: NSRange(location: index + 2,
                                                length: close - (index + 2)))
        guard !name.isEmpty, let kind = Kind.named(name) else { return nil }

        // An optional fold marker sits immediately after the `]`.
        var markerEnd = close + 1
        var foldable = false
        if markerEnd < lineEnd {
            let unit = text.character(at: markerEnd)
            if unit == 0x2D || unit == 0x2B { foldable = true; markerEnd += 1 }   // - +
        }

        // Whatever is left on the line, minus surrounding whitespace, is the
        // author's title.
        var titleStart = markerEnd
        while titleStart < lineEnd,
              text.character(at: titleStart) == 0x20
                || text.character(at: titleStart) == 0x09 { titleStart += 1 }
        var titleEnd = lineEnd
        while titleEnd > titleStart {
            let unit = text.character(at: titleEnd - 1)
            guard unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D else { break }
            titleEnd -= 1
        }
        return Header(kind: kind,
                      markerRange: index..<markerEnd,
                      titleRange: titleEnd > titleStart ? titleStart..<titleEnd : nil,
                      isFoldable: foldable)
    }
}
