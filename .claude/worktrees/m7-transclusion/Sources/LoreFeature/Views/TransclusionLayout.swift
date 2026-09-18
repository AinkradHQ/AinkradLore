import AppKit

/// Measures how tall a resolved `![[note]]` embed will render at a given
/// width, from ONE layout pass — the same collapse-reserve-draw route
/// `MarkdownTableLayout` takes (see that file's header comment, and the
/// defect it documents at `MarkdownEditor.swift:197`: measuring one way and
/// reserving another draws over the paragraph beneath it).
///
/// `@MainActor` because `TransclusionMeasureCounter` is — every embed
/// measurement funnels through AppKit text layout, which is main-actor work
/// in this editor regardless.
@MainActor
enum TransclusionLayout {

    /// Padding around the embed's drawn frame, inside the reserved height.
    static let framePadding: CGFloat = 12

    /// One measured embed: the height reserved for it AND the exact attributed
    /// string that height was measured from.
    ///
    /// The string travels WITH the height on purpose. Task 5's review flagged
    /// the alternative — a draw pass that restyles the content independently —
    /// as the defect recorded at `MarkdownEditor.swift:197`: a block measured
    /// one way and reserved another is drawn wrong. Carrying one string means
    /// there is only ever one styling path, so the two cannot diverge.
    struct Box: Equatable {
        let text: NSAttributedString
        /// The measure the text was wrapped at — the INNER width, already
        /// inset by `framePadding` on both sides, so the draw pass wraps at
        /// exactly the width the measurement assumed.
        let innerWidth: CGFloat
        /// The full reserved height, text plus `framePadding` top and bottom.
        let height: CGFloat
    }

    /// Lays `content` out at `width` and returns both halves of the answer.
    ///
    /// - Parameter measuredHeight: a height already in `TransclusionCache`.
    ///   Supplied, this costs NO layout pass and records no measurement — the
    ///   string is rebuilt (a copy, not a layout) and the cached height reused.
    ///   `nil` measures, through `height(for:width:theme:)`, which keeps
    ///   `TransclusionMeasureCounter.record()` at its single call site: one
    ///   measured box is exactly one recorded measurement.
    static func box(for content: TransclusionContent, width: CGFloat,
                    theme: MarkdownTheme, measuredHeight: CGFloat? = nil) -> Box {
        Box(text: attributedString(for: content, theme: theme),
            innerWidth: max(1, width - framePadding * 2),
            height: measuredHeight
                ?? height(for: content, width: width, theme: theme))
    }

    /// Height reserved for `content`, laid out once at `width`.
    ///
    /// `TransclusionMeasureCounter.record()` fires exactly once per call, at
    /// the top — this is the only call site in the codebase, and the
    /// typing-path gate in `MarkdownRevealBenchmark` counts it to prove
    /// typing never re-measures.
    ///
    /// Deterministic: the same content, width and theme always produce the
    /// same height, because the string laid out and the frame padding added
    /// are both pure functions of the inputs — nothing here reads mutable
    /// state.
    static func height(for content: TransclusionContent, width: CGFloat,
                       theme: MarkdownTheme) -> CGFloat {
        TransclusionMeasureCounter.record()

        let text = attributedString(for: content, theme: theme)
        let measuredWidth = max(1, width - framePadding * 2)
        let textHeight = measure(text, wrappingAt: measuredWidth)
        return textHeight + framePadding * 2
    }

    /// The attributed string that will be drawn for `content`. Every failure
    /// case renders a visible notice string rather than empty text, so its
    /// measured height is never zero — a zero height is a blank gap,
    /// indistinguishable from an empty note.
    private static func attributedString(for content: TransclusionContent,
                                         theme: MarkdownTheme) -> NSAttributedString {
        let font = MarkdownStyleRenderer.baseFont.withSize(theme.bodySize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple

        func string(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ])
        }

        switch content {
        case .content(let text):
            return string(text)
        case .truncated(let text):
            return string(text + "\n\n[content truncated]")
        case .missingFragment(let opening, let fragment):
            return string(opening + "\n\n[missing section: \(fragment)]")
        case .circular:
            return string("[circular embed]")
        case .tooDeep:
            return string("[embed nested too deep]")
        case .unreadable(let message):
            return string("[could not read embed: \(message)]")
        }
    }

    /// The text's rendered height at `width`, from a single `NSTextContainer`
    /// layout pass — matching `MarkdownTableLayout.measure`'s use of
    /// `boundingRect`.
    private static func measure(_ text: NSAttributedString,
                                wrappingAt width: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(1, ceil(bounds.height))
    }
}
