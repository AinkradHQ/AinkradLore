import Foundation

/// Line-level markdown formatting: list markers, checkboxes, quotes, headings.
///
/// Pure, like `MarkdownEditing`'s wrap and indent transforms and for the same
/// reason — every one of these is fiddly at exactly the boundaries a running
/// app makes hard to reach (an empty line, a multi-line selection, a line that
/// already carries the marker), and those are the cases a test can state in one
/// line each.
///
/// Split from `MarkdownEditing` rather than added to it: that file is at 239
/// lines and owns the CHARACTER-level transforms (wrap, auto-pair, link
/// insertion). These operate on whole lines, which is a different unit and a
/// different set of edge cases.
enum MarkdownLineFormatting {

    /// Adds `prefix` to every line the selection touches, or removes it from
    /// all of them if every line already has it.
    ///
    /// "All or nothing", not per-line: with a mixed selection (some lines
    /// bulleted, some not) the useful outcome is to make them ALL bulleted,
    /// because that is what someone selecting a ragged block and pressing the
    /// list key is asking for. Toggling each line independently would leave
    /// the block exactly as ragged as it started, just inverted.
    static func toggleLinePrefix(text: String, selection: NSRange,
                                 prefix: String) -> EditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        // `omittingEmptySubsequences: false` keeps blank lines as lines, so a
        // selection spanning a paragraph break does not silently drop it.
        let lines = block.components(separatedBy: "\n")
        // A trailing newline in the block produces a final empty component
        // that is not a line at all — prefixing it would insert a stray marker
        // on the line AFTER the selection.
        let hasTrailingNewline = block.hasSuffix("\n")
        let content = hasTrailingNewline ? Array(lines.dropLast()) : lines

        let allPrefixed = !content.isEmpty && content.allSatisfy {
            $0.isEmpty || $0.hasPrefix(prefix)
        }
        let rewritten = content.map { line -> String in
            if allPrefixed {
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
            }
            // An already-prefixed line in a mixed selection is left alone
            // rather than double-prefixed.
            return line.hasPrefix(prefix) || line.isEmpty ? line : prefix + line
        }
        var replacement = rewritten.joined(separator: "\n")
        if hasTrailingNewline { replacement += "\n" }

        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        let delta = (replacement as NSString).length - lineRange.length
        // The selection follows the text it was on. Clamped at the line start
        // so removing a marker from the first line cannot pull the caret in
        // front of it.
        let location = max(lineRange.location, selection.location + (allPrefixed ? -prefix.count : prefix.count))
        let length = max(0, selection.length + (delta - (allPrefixed ? -prefix.count : prefix.count)))
        return EditResult(text: updated,
                          selection: NSRange(location: min(location, (updated as NSString).length),
                                             length: min(length,
                                                         (updated as NSString).length - min(location, (updated as NSString).length))))
    }

    /// Sets the heading level of the lines the selection touches.
    ///
    /// `level == 0` means body text: the existing `#`s come off. Setting the
    /// level a line ALREADY has also removes them, so the same key toggles —
    /// pressing ⌘1 twice on an h1 returns it to a paragraph, which is what
    /// every editor with heading shortcuts does.
    ///
    /// Existing markers are REPLACED rather than added to, so ⌘2 on an h1
    /// produces an h2 and never `#​##`.
    static func setHeading(text: String, selection: NSRange, level: Int) -> EditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        let lines = block.components(separatedBy: "\n")
        let content = hasTrailingNewline ? Array(lines.dropLast()) : lines

        let clamped = min(max(level, 0), 6)
        let alreadyAtLevel = !content.isEmpty && content.allSatisfy {
            $0.isEmpty || headingLevel(of: $0) == clamped
        }
        let target = alreadyAtLevel ? 0 : clamped

        let rewritten = content.map { line -> String in
            let stripped = strippingHeading(line)
            guard target > 0, !stripped.isEmpty || !line.isEmpty else { return stripped }
            return String(repeating: "#", count: target) + " " + stripped
        }
        var replacement = rewritten.joined(separator: "\n")
        if hasTrailingNewline { replacement += "\n" }

        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        // Caret to the end of the edited block: heading changes shift every
        // character on the line, so preserving a column offset would put the
        // caret somewhere arbitrary inside the new marker.
        let end = lineRange.location + (replacement as NSString).length
        return EditResult(text: updated,
                          selection: NSRange(location: min(end, (updated as NSString).length),
                                             length: 0))
    }

    /// The ATX heading level of a line, or 0 for body text.
    static func headingLevel(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard count > 0, count <= 6 else { return 0 }
        // `#hashtag` is not a heading — ATX requires a space (or end of line)
        // after the run. Without this check, typing a tag at the start of a
        // line would read as an h1 and ⌘1 would "toggle" it into nonsense.
        let rest = line.dropFirst(count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return 0 }
        return count
    }

    /// A line with its heading marker removed, if it had one.
    static func strippingHeading(_ line: String) -> String {
        let level = headingLevel(of: line)
        guard level > 0 else { return line }
        return String(line.dropFirst(level)).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }
}
