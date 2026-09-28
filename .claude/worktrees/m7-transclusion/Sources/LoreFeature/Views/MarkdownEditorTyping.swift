import AppKit

/// Applies the pure `MarkdownEditing` transforms to a live text view, each as
/// ONE undo group.
///
/// Lives apart from `MarkdownEditor.swift` only because that file is at its
/// line cap; conceptually this is the keyboard half of the editor.
enum MarkdownEditorTyping {

    /// Returns true when the edit was applied, which the caller returns from
    /// `doCommandBy` to stop AppKit also handling the key.
    ///
    /// Goes through `shouldChangeText(in:replacementString:)` so the text
    /// view's own undo registration, delegate notifications and autosave
    /// bookkeeping all run — bypassing it with a direct `textStorage` mutation
    /// is what produces edits the autosave never learns about.
    ///
    /// THAT CALL is what makes the affordance one undo step: it registers the
    /// single reverse action, before the grouping below opens, and the mutation
    /// underneath is one `replaceCharacters`. The explicit grouping is belt and
    /// braces for anything that might later register a second action inside it;
    /// it is not what delivers the guarantee.
    @MainActor
    @discardableResult
    static func apply(_ result: EditResult, to tv: NSTextView) -> Bool {
        // A transform can legitimately return the text unchanged — outdenting
        // at column zero does. That keystroke is still handled (swallowed), but
        // it must not push a do-nothing entry onto the undo stack, or the next
        // Cmd-Z appears to do nothing at all.
        guard result.text != tv.string else {
            tv.setSelectedRange(result.selection)
            return true
        }
        // The MINIMAL edit, not the whole document.
        //
        // The transforms are whole-document functions — `continueList` returns
        // the new text entire — and applying them literally replaced every
        // character on every Enter, Tab and Cmd-B. Semantically correct, and
        // three separate costs: `MarkdownStyleCache.shift` was handed an edit
        // covering the document, which slides every span onto the caret and
        // discards the styling until the debounce lands; `MarkdownEditor`'s
        // renderer re-attributes the entire storage; and AppKit relayouts it.
        // On a long list, pressing Enter therefore cost what retyping the note
        // would.
        //
        // Narrowing changes nothing the user can observe. The RESULTING string
        // is identical by construction (see `changedRange`), the call still
        // goes through `shouldChangeText`/`didChangeText`, and undo still
        // restores the original text in one step — the reverse action AppKit
        // registers covers exactly the range being replaced, which is the same
        // document either way.
        let (range, replacement) = changedRange(from: tv.string as NSString,
                                                to: result.text as NSString)
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return false }
        tv.undoManager?.beginUndoGrouping()
        tv.textStorage?.replaceCharacters(in: range, with: replacement)
        tv.setSelectedRange(result.selection)
        tv.undoManager?.endUndoGrouping()
        tv.didChangeText()
        return true
    }

    /// The smallest replacement that turns `old` into `new`: strip the common
    /// prefix and the common suffix, replace what is left.
    ///
    /// Guarantees, in order of how badly each would bite:
    ///
    /// 1. **Exactness.** `old[0..<lower] + replacement + old[range.upperBound...]`
    ///    is `new`, unit for unit. The prefix and suffix are compared in UTF-16,
    ///    the same unit `NSTextStorage` is indexed in, so there is no encoding
    ///    round trip to lose anything in.
    /// 2. **No split characters.** A naive prefix scan can stop between the two
    ///    halves of a surrogate pair, or in the middle of a combining sequence,
    ///    and handing AppKit such a range is how an emoji becomes two replacement
    ///    glyphs. Both ends are therefore walked OUTWARD — `lower` down, the
    ///    upper bounds up — until they sit on composed-character-sequence
    ///    boundaries in BOTH strings. Widening is always safe: it can only make
    ///    the replacement larger, never wrong.
    /// 3. **Termination.** `lower` is bounded below by 0 and the upper bounds
    ///    above by the two lengths, and each step moves one unit.
    ///
    /// The two upper bounds move together, which is what keeps the untouched
    /// tails the same length in both strings and therefore keeps (1) true.
    static func changedRange(from old: NSString, to new: NSString)
        -> (range: NSRange, replacement: String) {
        var prefix = 0
        let prefixLimit = min(old.length, new.length)
        while prefix < prefixLimit, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        let suffixLimit = min(old.length, new.length) - prefix
        while suffix < suffixLimit,
              old.character(at: old.length - 1 - suffix)
                == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }

        var lower = prefix
        while lower > 0, !isBoundary(old, lower) || !isBoundary(new, lower) { lower -= 1 }
        var upperOld = old.length - suffix
        var upperNew = new.length - suffix
        while !isBoundary(old, upperOld) || !isBoundary(new, upperNew) {
            upperOld += 1
            upperNew += 1
        }
        return (NSRange(location: lower, length: upperOld - lower),
                new.substring(with: NSRange(location: lower, length: upperNew - lower)))
    }

    /// Whether `offset` is a character boundary in `text`. The end of the
    /// string is one; so is any offset that begins its own composed sequence.
    private static func isBoundary(_ text: NSString, _ offset: Int) -> Bool {
        guard offset < text.length else { return true }
        return text.rangeOfComposedCharacterSequence(at: offset).location == offset
    }

    /// Routes an editing selector to its transform. Returns false — meaning
    /// "AppKit, do your default" — whenever the transform declines, which is
    /// what keeps plain newlines, tab insertion and IME behaviour intact.
    @MainActor
    static func handle(_ selector: Selector, in tv: NSTextView) -> Bool {
        let text = tv.string
        let selection = tv.selectedRange()
        let result: EditResult?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            result = MarkdownEditing.continueList(text: text, selection: selection)
        case #selector(NSResponder.insertTab(_:)):
            result = MarkdownEditing.indent(text: text, selection: selection, by: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            result = MarkdownEditing.indent(text: text, selection: selection, by: -1)
        default:
            return false
        }
        guard let result else { return false }
        return apply(result, to: tv)
    }

    /// Auto-pairing for a single typed character. Returns false for everything
    /// else — including multi-character input, which is a paste or an IME
    /// commit and must never be reinterpreted as a bracket.
    @MainActor
    static func typed(_ string: String, in tv: NSTextView) -> Bool {
        guard string.count == 1 else { return false }
        guard let result = MarkdownEditing.autoPair(text: tv.string,
                                                    selection: tv.selectedRange(),
                                                    typing: string) else { return false }
        return apply(result, to: tv)
    }

    /// Cmd-B / Cmd-I. Always produces a result, so it always applies.
    @MainActor
    static func toggleWrap(in tv: NSTextView, with delimiter: String) {
        apply(MarkdownEditing.toggleWrap(text: tv.string,
                                         selection: tv.selectedRange(),
                                         with: delimiter),
              to: tv)
    }
}
