import AppKit
import AinkradAppKit

/// Hosts the editor's own context menu in place of `NSTextView`'s.
///
/// The menu is presented by `.ainkradContextMenu(_:)` (see
/// `AinkradContextMenu.swift` in AinkradAppKitUI), which is a SwiftUI view
/// modifier: its right-click catcher sits in an overlay ABOVE whatever it
/// decorates and owns the event outright, and it draws the panel itself —
/// there is no public hook that hands this module the click before the panel
/// is built. So the items it presents cannot be computed from the exact pixel
/// of a right-click; they are kept current instead, via `onSelectionChange`,
/// from wherever the caret already is. In the ordinary flow — type a word,
/// then right-click it — the caret is already sitting where the click lands,
/// which is the case this task's Dev Host walkthrough exercises. Right-clicking
/// a DIFFERENT word than the caret's, without selecting it first, is a known
/// gap: this suggests against the word at the caret, not the word under the
/// pointer. `AinkradFloatingPanelController`, which actually owns the pixel,
/// is `internal` to AinkradAppKitUI and out of reach from here — and
/// `AinkradAppKit/` is not this task's to change.
extension LinkTextView {
    /// Returning nil suppresses AppKit's own menu entirely. Without this both
    /// menus race and the native one usually wins. Spellchecking ITSELF is
    /// untouched — only its menu is gone; `EditorSpellCheck` below rebuilds
    /// the suggestions through the same `NSSpellChecker` the native menu used.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// Suggestions for the word at a UTF-16 offset, via the shared checker.
enum EditorSpellCheck {

    /// `checkSpelling`/`guesses` both take the WORD as its own string, not
    /// the document, so the range each one wants is relative to that
    /// isolated word — `0..<word.length` — not to the document offset
    /// `WordAtPoint` found it at.
    ///
    /// - Parameter tag: `NSTextView.spellCheckerDocumentTag`, fed to ALL
    ///   THREE calls that take one — this gating check, `guesses` below, and
    ///   `MarkdownEditorMenuActions.ignoreSpelling`. The tagLESS
    ///   `checkSpelling(of:startingAt:)` overload consults no spell
    ///   document at all, so a word the user had just told the checker to
    ///   ignore (via that SAME tag) was still reported misspelled here and
    ///   the menu went right on offering replacements for it — the ignore
    ///   action worked, but nothing downstream of it ever asked the document
    ///   that held the answer. Using the tag-aware overload is what makes
    ///   this call agree with the other two rather than merely sit next to
    ///   them.
    static func suggestions(at offset: Int, in text: String, tag: Int) -> (NSRange, [String])? {
        guard let range = WordAtPoint.range(in: text, atUTF16: offset) else { return nil }
        let word = (text as NSString).substring(with: range)
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: nil,
                                               wrap: false, inSpellDocumentWithTag: tag,
                                               wordCount: nil)
        guard misspelled.location != NSNotFound else { return (range, []) }
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                      in: word, language: nil,
                                      inSpellDocumentWithTag: tag) ?? []
        return (range, guesses)
    }
}

/// Debounces the spelling lookup off the caret-move hot path.
///
/// `NSSpellChecker` is backed by a system service — every `checkSpelling`/
/// `guesses` call is an XPC round trip — and `onSelectionChange` fires on
/// EVERY arrow key. Running it there directly is exactly the caret-path cost
/// this module has explicit benchmark discipline against elsewhere (see
/// `MarkdownRevealBenchmark.test_movingTheCaretCostsZeroParses`). There is no
/// public hook to compute this only when the menu is about to be shown (see
/// this file's top-level doc comment on `.ainkradContextMenu`'s presentation
/// constraints), so this mirrors the cheapest correct alternative already
/// used in this codebase for the same class of problem —
/// `MarkdownEditor.Coordinator.scheduleParse`'s debounce — rather than
/// inventing a second scheme: a burst of caret movement costs one lookup,
/// after it settles, not one per keypress.
@MainActor
final class MenuSuggestionDebouncer {
    static let interval: TimeInterval = 0.15

    // `nonisolated(unsafe)`: `deinit` on a `@MainActor` class is itself
    // nonisolated (it may run once nothing else can reach `self`), so it
    // cannot touch a main-actor-isolated stored property without this. Every
    // OTHER access to `timer` is still on the main actor, through this
    // class's own main-actor-isolated methods.
    private nonisolated(unsafe) var timer: Timer?

    deinit { timer?.invalidate() }

    func schedule(text: String, offset: Int, tag: Int,
                 apply: @escaping @MainActor ([String]) -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.interval, repeats: false) { _ in
            MainActor.assumeIsolated {
                apply(EditorSpellCheck.suggestions(at: offset, in: text, tag: tag)?.1 ?? [])
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

/// Builds the `EditorMenuActions` the context menu runs, wired to `tv`'s own
/// commands and to `MarkdownEditing`'s formatting entry points — never a
/// second implementation of marker insertion.
@MainActor
enum MarkdownEditorMenuActions {

    static func build(for tv: NSTextView) -> EditorMenuActions {
        EditorMenuActions(
            cut: { tv.cut(nil) },
            copy: { tv.copy(nil) },
            paste: { tv.paste(nil) },
            selectAll: { tv.selectAll(nil) },
            link: { wrapAsWikiLink(in: tv) },
            code: { MarkdownEditorTyping.toggleWrap(in: tv, with: "`") },
            heading: { toggleHeading(in: tv) },
            replace: { replacement in replaceWordAtCaret(in: tv, with: replacement) },
            // Tag 0 means "no spell document" — `ignoreWord` would silently
            // retain nothing, and the menu item would do nothing while
            // claiming to work. `tv.spellCheckerDocumentTag` is the view's
            // own real, stable tag (AppKit allocates and owns its lifetime),
            // and it is the SAME tag `EditorSpellCheck.suggestions` is fed
            // via `onSelectionChange` — so an ignored word actually stops
            // this document's future lookups from re-suggesting it.
            ignoreSpelling: {
                if let word = wordAtCaret(in: tv) {
                    NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tv.spellCheckerDocumentTag)
                }
            },
            learnSpelling: {
                if let word = wordAtCaret(in: tv) { NSSpellChecker.shared.learnWord(word) }
            })
    }

    private static func wordAtCaret(in tv: NSTextView) -> String? {
        guard let range = WordAtPoint.range(in: tv.string, atUTF16: tv.selectedRange().location)
        else { return nil }
        return (tv.string as NSString).substring(with: range)
    }

    private static func replaceWordAtCaret(in tv: NSTextView, with replacement: String) {
        guard let range = WordAtPoint.range(in: tv.string, atUTF16: tv.selectedRange().location)
        else { return }
        let text = (tv.string as NSString).replacingCharacters(in: range, with: replacement)
        let selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: selection), to: tv)
    }

    /// `[[…]]`, the same wiki-link syntax `MarkdownEditing.linkInsertion`
    /// produces when a completion is accepted — `toggleWrap` cannot make this
    /// edit itself, since its open and close delimiters are always identical.
    /// Internal, not private: the ⌘⇧K shortcut reaches it through
    /// `LoreFormatting`, so the menu item and the key press make the SAME
    /// edit rather than two implementations of "insert a link".
    static func wrapAsWikiLink(in tv: NSTextView) {
        let selection = tv.selectedRange()
        let ns = tv.string as NSString
        let inner = ns.substring(with: selection)
        let text = ns.replacingCharacters(in: selection, with: "[[" + inner + "]]")
        let cursor = NSRange(location: selection.location + 2, length: selection.length)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: cursor), to: tv)
    }

    /// Toggles a level-2 `## ` prefix on the caret's line. There is no
    /// existing heading transform in `MarkdownEditing` to reuse — `toggleWrap`
    /// wraps a SELECTION on both sides, and a heading marker is a LINE prefix.
    static func toggleHeading(in tv: NSTextView) {
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: lineRange)
        let prefix = "## "
        let newLine: String
        // An existing `#{1,6}` marker (followed by whitespace, per CommonMark
        // ATX headings) is stripped BEFORE re-prefixing, so `# Title`
        // toggles to `## Title` rather than `## # Title`, and `### x`
        // toggles to `## x` rather than `## ### x`. A line that merely
        // starts with `#` without the required whitespace (`#tag`) is not a
        // heading at all — `stripHeadingMarker` returns nil for it, and it
        // is prefixed like any other line. Level 2 specifically is the one
        // case that TOGGLES OFF: the marker this command itself would have
        // written, so stripping it and stopping there is what makes this a
        // toggle rather than a one-way "make this level 2" — the strip
        // already leaves any OTHER level re-prefixed to level 2, which reads
        // as promoting/demoting into this command's own level rather than a
        // second, un-toggleable action.
        let stripped = stripHeadingMarker(from: line)
        if line.hasPrefix(prefix) {
            newLine = stripped ?? line
        } else {
            newLine = prefix + (stripped ?? line)
        }
        let delta = (newLine as NSString).length - (line as NSString).length
        let text = ns.replacingCharacters(in: lineRange, with: newLine)
        let cursor = NSRange(location: max(lineRange.location, selection.location + delta),
                             length: selection.length)
        MarkdownEditorTyping.apply(EditResult(text: text, selection: cursor), to: tv)
    }

    /// Strips a leading ATX heading marker (`#` through `######`, followed by
    /// whitespace) from `line`, returning nil if `line` isn't a heading.
    static func stripHeadingMarker(from line: String) -> String? {
        var hashCount = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", hashCount < 6 {
            hashCount += 1
            index = line.index(after: index)
        }
        guard hashCount > 0, index < line.endIndex, line[index] == " " else { return nil }
        return String(line[line.index(after: index)...])
    }
}
