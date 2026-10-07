import Foundation

// The frontmatter scanner and YAML scalar quoting, split from
// `Frontmatter.swift` to keep it under the 500-line ceiling.
extension Frontmatter {
    // MARK: - scanner

    /// One top-level mapping entry and the exact line range it occupies.
    ///
    /// `end > start` for block sequences (`key:` then `- item` lines) and block
    /// scalars (`key: |` then indented lines) — the shapes the old parser
    /// dropped on the floor.
    struct Entry {
        let key: String
        let inlineValue: String
        let continuation: [String]
        let start: Int
        let end: Int

        /// A single-line rendering for the index's `properties` column. Never
        /// used for serialization.
        var flattenedValue: String {
            guard inlineValue.isEmpty, !continuation.isEmpty else { return Frontmatter.unquoted(inlineValue) }
            return "[" + Frontmatter.sequenceItems(continuation).joined(separator: ", ") + "]"
        }
    }

    /// Scans header lines into top-level entries. Lines no entry owns —
    /// comments and blanks outside any block, and anything unrecognised — are
    /// never touched by `serialize`, which is why they survive.
    ///
    /// An entry's extent runs to its LAST continuation line, and interior
    /// comments and blank lines are swallowed along the way. Ending the extent
    /// at the first comment instead would leave the tail of a block sequence
    /// orphaned behind a replaced key — `tags:\n  - one\n# c\n  - two` patched
    /// to `[z]` would emit `tags: [z]` followed by a stray `  - two`: invalid
    /// YAML plus phantom data. Trailing comments after the last item are NOT
    /// swallowed, because nothing follows them to prove they are interior.
    static func scan(_ lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        var i = 0
        while i < lines.count {
            guard let (key, value) = keyValue(lines[i]) else {
                i += 1
                continue
            }
            var j = i + 1
            var last = i
            while j < lines.count {
                let line = lines[j]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    j += 1
                    continue
                }  // provisional
                guard
                    line.hasPrefix(" ") || line.hasPrefix("\t")
                        || trimmed.hasPrefix("- ") || trimmed == "-"
                else { break }
                last = j
                j += 1
            }
            entries.append(
                Entry(
                    key: key, inlineValue: value,
                    continuation: last > i ? Array(lines[(i + 1)...last]) : [],
                    start: i, end: last))
            i = last + 1
        }
        return entries
    }

    /// A top-level `key: value` line, or nil for blanks, comments, sequence
    /// items, indented continuation and anything else we refuse to interpret.
    private static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- "), trimmed != "-",
            !line.hasPrefix(" "), !line.hasPrefix("\t")
        else { return nil }
        // Prefer a colon that YAML would accept as a key terminator (followed
        // by a space or end of line) so `title: a: b` keys on the first colon
        // and `url: https://x` does not key on the scheme colon.
        let chars = Array(line)
        var colon: Int?
        for (idx, ch) in chars.enumerated() where ch == ":" {
            if idx == chars.count - 1 || chars[idx + 1] == " " {
                colon = idx
                break
            }
        }
        guard let c = colon ?? chars.firstIndex(of: ":") else { return nil }
        let key = String(chars[..<c]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(chars[(c + 1)...]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - scalars

    /// Characters that, leading a plain scalar, change how YAML reads it.
    private static let unsafeLeading = Set("-?:[]{}&*!|>%@`,\"'#")
    /// Characters that make a plain scalar ambiguous anywhere in the value.
    private static let unsafeAnywhere = Set(":#,[]{}\n\r\t")
    private static let yamlKeywords: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]

    /// Renders a value so that `parse(serialize(x)) == x` for ARBITRARY text.
    ///
    /// Reachable with zero validation from `LoreNoteOperations.saveNote`
    /// (`object["title"] as? String`) and from `LoreStore.create`, so this must
    /// hold for hostile input, not just tidy input. `Meeting: Q3` is an
    /// entirely ordinary title.
    static func yamlScalar(_ value: String) -> String {
        var needsQuotes =
            value.isEmpty
            || yamlKeywords.contains(value.lowercased())
            || value != value.trimmingCharacters(in: .whitespaces)
            || value.contains(where: unsafeAnywhere.contains)
        if let first = value.first, unsafeLeading.contains(first) { needsQuotes = true }
        guard needsQuotes else { return value }

        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// The inverse of `yamlScalar` for the two quoting styles YAML defines.
    static func unquoted(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2, let fence = s.first, s.last == fence else { return s }
        let inner = s.dropFirst().dropLast()
        if fence == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        guard fence == "\"" else { return s }
        var out = ""
        var escaped = false
        for ch in inner {
            guard escaped else {
                if ch == "\\" { escaped = true } else { out.append(ch) }
                continue
            }
            switch ch {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            default: out.append(ch)
            }
            escaped = false
        }
        return out
    }
}
