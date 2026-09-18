import Foundation

/// One GFM task-list checkbox, located precisely enough to toggle.
///
/// `markerRangeUTF16` covers EXACTLY the one character between the brackets —
/// the `" "` of `[ ]` or the `x` of `[x]` — never the brackets themselves. That
/// is what makes a toggle a one-character replacement rather than a rewrite of
/// the item, which in turn is what lets it ride the editor's ordinary edit path
/// (one undo step, one dirty mark, one debounced autosave) instead of needing a
/// write of its own.
/// Internal, not public: the only producer is `TaskCheckbox`, which is
/// internal, and nothing outside this module toggles a checkbox.
struct TaskItem: Equatable, Sendable {
    let isChecked: Bool
    /// UTF-16 offsets into the string it was located against — the editor's
    /// LIVE text on the toggle path. Length is always 1.
    let markerRangeUTF16: NSRange

    init(isChecked: Bool, markerRangeUTF16: NSRange) {
        self.isChecked = isChecked
        self.markerRangeUTF16 = markerRangeUTF16
    }
}

/// The one place the shape of a checkbox marker is known — and, since the M2a
/// merge review, the one place "where is the checkbox" is ANSWERED.
///
/// There used to be two answers. `MarkdownDocumentModel.taskItems` and
/// `MarkdownDocumentModel.toggle(_:in:)` were public API with zero production
/// callers, while the shipped click path walked `styleCache.spans` and called
/// `markerRange` itself. They agreed only because both happened to route
/// through this type; nothing made them. The model-side pair is gone and
/// `MarkdownEditor.toggleTask` now goes through `items(in:text:)` and
/// `replacement(for:in:)` below, so the locator has exactly one implementation
/// and it is the one that ships.
///
/// Every function here is parameterised by the STRING to check against, because
/// the two calls hold different ones: a parse-time string when locating, and
/// the live text under the caret — which may have moved on by up to one styling
/// debounce — when toggling. That parameter is what stops the answers drifting,
/// and the drift is exactly the failure mode that would toggle an arbitrary
/// character of a user's note.
enum TaskCheckbox {
    /// The marker character's range, given the `[x]` bracket span a
    /// `.checkbox` style span covers — but ONLY if `text` really still holds a
    /// bracketed marker there.
    ///
    /// Every part is verified against `text` rather than trusted from
    /// arithmetic: the span must be three units long, in bounds, opened by `[`,
    /// closed by `]`, and hold one of the three legal marker spellings between
    /// them. A span that fails any of these describes a string that has moved
    /// on, and the honest answer is `nil` — no toggle — not a guess.
    static func markerRange(forBracketSpan span: Range<Int>, in text: NSString) -> NSRange? {
        guard span.count == 3, span.lowerBound >= 0, span.upperBound <= text.length else {
            return nil
        }
        guard text.character(at: span.lowerBound) == 0x5B,        // [
              text.character(at: span.upperBound - 1) == 0x5D     // ]
        else { return nil }
        // The `]` must be followed by whitespace or end-of-text. GFM requires a
        // space after a task-list checkbox, so every REAL marker satisfies this
        // — but `[x](url)` does not, and that was the one live hole left in a
        // guard whose entire job is refusing stale offsets: a `.checkbox` span
        // that had drifted onto a markdown inline link passed all four checks
        // and a click rewrote the link's display text to `[ ](url)`.
        if span.upperBound < text.length {
            let next = text.character(at: span.upperBound)
            guard next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D else {
                return nil
            }
        }
        let marker = NSRange(location: span.lowerBound + 1, length: 1)
        guard toggled(text.substring(with: marker)) != nil else { return nil }
        return marker
    }

    /// Every toggleable checkbox described by `spans`, in span order, validated
    /// against `text`.
    ///
    /// The editor's locator and the model's used to be separate readings of the
    /// same spans; this is the single one. It takes SPANS rather than a model
    /// because the editor has no model — it holds `MarkdownStyleCache.spans`,
    /// which lag the live text by up to a debounce and are shifted rather than
    /// re-derived. Passing them here with the LIVE text is what turns a cached
    /// offset from an authority into a candidate.
    ///
    /// A malformed item contributes nothing: `- [] a` and `- [y] a` are not
    /// task items to swift-markdown, so they carry no `.checkbox` span at all,
    /// and one whose span no longer matches `text` is dropped by `markerRange`.
    /// The AST also never produces a `.checkbox` inside a fenced block, so a
    /// fence's lookalikes are absent for the same reason they are unstyled.
    static func items(in spans: [StyleSpan], text: NSString) -> [TaskItem] {
        spans.compactMap { span in
            guard case .checkbox(let isChecked) = span.kind,
                  let marker = markerRange(forBracketSpan: span.range, in: text)
            else { return nil }
            return TaskItem(isChecked: isChecked, markerRangeUTF16: marker)
        }
    }

    /// The one-character edit that toggles `item`, re-validated against `text`.
    ///
    /// `nil` means refuse. The brackets are re-read here and not just the
    /// marker character, because the marker alphabet is not distinctive enough
    /// on its own: `"x"` and `"X"` are ordinary letters, so a stale offset
    /// landing in prose has a real chance of finding one and "toggling" a word.
    ///
    /// `item.isChecked` is deliberately NOT consulted — it came from the parse,
    /// and the parse is the thing that may be stale. The character actually
    /// sitting in `text` decides what it becomes.
    static func replacement(for item: TaskItem, in text: NSString)
        -> (range: NSRange, string: String)? {
        let range = item.markerRangeUTF16
        guard range.length == 1, range.location >= 1, NSMaxRange(range) < text.length,
              let marker = markerRange(
                  forBracketSpan: (range.location - 1)..<(range.location + 2), in: text),
              let string = toggled(text.substring(with: marker))
        else { return nil }
        return (marker, string)
    }

    /// What the marker character becomes when clicked, or `nil` when the
    /// character is not a marker at all.
    static func toggled(_ current: String) -> String? {
        switch current {
        case " ": return "x"
        case "x", "X": return " "
        default: return nil
        }
    }
}

// `MarkdownDocumentModel.taskItems` and `.toggle(_:in:)` lived here. Both were
// public API with ZERO production callers: the shipped toggle path is
// `MarkdownEditor.toggleTask(atUTF16:)`, which walks its own style-span cache.
// Two implementations of "where is the checkbox" that agreed only by both
// happening to call `TaskCheckbox` — a coincidence, not a constraint, in a
// milestone whose premise is one source of truth per question. The editor is
// wired through `TaskCheckbox.items(in:text:)` / `.replacement(for:in:)`
// instead, so the surviving answer is the one that ships.
