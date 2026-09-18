import Foundation

/// YAML frontmatter, read and written PRESERVE-AND-PATCH.
///
/// THE GUIDING RULE: Lore preserves what it does not model; it does not need to
/// understand a property in order to keep it.
///
/// The previous design parsed frontmatter into `Note` and then re-emitted the
/// whole block from that model. That is structurally lossy: anything the model
/// does not understand cannot survive a save. It destroyed YAML block sequences
/// — Obsidian's DEFAULT shape for `aliases`, `cssclasses` and `tags` — because
/// their item lines contain no colon and were skipped, and it rewrote any
/// `created:` it could not parse to today's date.
///
/// Instead, `parse` keeps the ENTIRE original block verbatim on
/// `Note.rawFrontmatter`, and `serialize` starts from that text and surgically
/// replaces only the lines whose modelled value actually changed. Comments,
/// blank lines, key order, indentation, quoting, block sequences and block
/// scalars are copied through byte for byte because nothing ever rewrites them.
///
/// Values that ARE rewritten go out through `yamlScalar`, because a title is
/// arbitrary user (or agent) text: `Meeting: Q3` emitted raw produces invalid
/// YAML and Obsidian then shows NO properties at all for the note, and a title
/// containing a newline would inject a whole new top-level property.
public enum Frontmatter {
    /// Keys `Note` models. Everything else is preserved but never interpreted.
    static let modelledKeys = ["id", "title", "tags", "created", "updated"]

    // MARK: - parse

    public static func parse(_ text: String, path: URL) -> Note {
        let layout = splitLines(text)
        guard let split = splitBlock(layout) else { return fallback(path: path, layout: layout) }
        let entries = scan(split.headerLines)
        func entry(_ key: String) -> Entry? { entries.last { $0.key == key } }

        let now = Date()
        let body = split.body
        let extra = entries
            .filter { !modelledKeys.contains($0.key) }
            .map { FrontmatterPair(key: $0.key, rawValue: $0.flattenedValue) }

        /// Scalars are unquoted on read for EVERY modelled key, not just tags
        /// and dates. Otherwise `title: "Quoted"` shows literal quotes in the
        /// UI, the index and MCP `read_note`.
        func scalar(_ key: String) -> String? {
            guard let raw = entry(key)?.inlineValue else { return nil }
            let value = unquoted(raw)
            return value.isEmpty ? nil : value
        }

        return Note(
            path: path,
            id: scalar("id") ?? UUID().uuidString,
            title: scalar("title") ?? deriveTitle(body, path: path),
            tags: entry("tags").map(list(of:)) ?? [],
            aliases: entry("aliases").map(list(of:)) ?? [],
            created: entry("created").flatMap { date(from: $0.inlineValue)?.date } ?? now,
            updated: entry("updated").flatMap { date(from: $0.inlineValue)?.date } ?? now,
            body: body,
            extra: extra,
            rawFrontmatter: split.header,
            lineEnding: layout.ending,
            hasByteOrderMark: layout.bom
        )
    }

    /// Splits text into lines, reporting the document's line ending and whether
    /// it carried a byte order mark.
    ///
    /// Both are stripped here and put back verbatim by `serialize`. Both exist
    /// for the same reason: a document whose FIRST line does not compare equal
    /// to `"---"` has no frontmatter as far as `splitBlock` is concerned, so the
    /// whole file becomes `body` and `serialize` PREPENDS a second
    /// Lore-invented block above the user's real one — every property lost from
    /// Obsidian's view, on a file Obsidian renders perfectly.
    ///
    /// - CRLF documents come from Windows-authored vaults, sync clients and git
    ///   checkouts with `core.autocrlf`; splitting on `"\n"` alone leaves the
    ///   fence reading as `"---\r"`.
    /// - A leading U+FEFF comes from PowerShell redirects, older Notepad and
    ///   several exporters; it leaves the fence reading as `"\u{FEFF}---"`.
    ///   NOTE: the BOM half is currently exercised only by tests. Every read
    ///   site in the product decodes with `String(contentsOf:encoding:.utf8)`,
    ///   which strips the BOM before this function is reached, so `bom` is
    ///   always `false` in production and a BOM-prefixed file loses its mark on
    ///   save (see `Note.hasByteOrderMark` for why that is accepted). The CRLF
    ///   half is fully live.
    ///
    /// LINE ENDINGS, PRECISELY: any `"\r\n"` anywhere in the document wins for
    /// the WHOLE document. A file with consistent endings — every real-world
    /// case — round-trips byte-exact. A file with MIXED endings is emitted
    /// entirely as CRLF. That is a deliberate, defensible simplification, not a
    /// promise to leave each line as it was found; do not build on a per-line
    /// guarantee, because there is none.
    static func splitLines(_ text: String) -> Layout {
        var text = text
        let bom = text.hasPrefix("\u{FEFF}")
        if bom { text.removeFirst() }

        guard text.contains("\r\n") else {
            return Layout(lines: text.components(separatedBy: "\n"), ending: "\n", bom: bom)
        }
        let lines = text.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        return Layout(lines: lines, ending: "\r\n", bom: bom)
    }

    struct Layout {
        let lines: [String]
        let ending: String
        let bom: Bool

        /// The document with its BOM removed and its line endings intact — what
        /// `body` must be when there is no frontmatter, since `serialize` puts
        /// the mark back itself.
        var strippedText: String { lines.joined(separator: ending) }
    }

    /// Finds the `---` fenced block. Line-based rather than substring-based so
    /// that an EMPTY block (`---\n---\n`) is still recognised as frontmatter.
    private static func splitBlock(_ layout: Layout) -> (header: String, headerLines: [String], body: String)? {
        let lines = layout.lines
        guard let close = closingFenceIndex(layout) else { return nil }
        let headerLines = Array(lines[1..<close])
        let body = lines[(close + 1)...].joined(separator: layout.ending)
        return (headerLines.joined(separator: layout.ending), headerLines, body)
    }

    /// Index of the closing `---` line, or nil when there is no frontmatter.
    static func closingFenceIndex(_ layout: Layout) -> Int? {
        guard layout.lines.first == "---" else { return nil }
        return layout.lines.dropFirst().firstIndex(of: "---")
    }

    // MARK: - serialize

    public static func serialize(_ note: Note) -> String {
        guard let raw = note.rawFrontmatter else { return serializeFromModel(note) }

        let le = note.lineEnding
        var lines = raw.isEmpty ? [] : splitLines(raw).lines
        let entries = scan(lines)
        var edits: [(range: ClosedRange<Int>, replacement: String)] = []
        var appended: [String] = []

        for key in modelledKeys {
            let existing = entries.last { $0.key == key }
            switch patch(key: key, note: note, entry: existing) {
            case .leave:
                continue
            case .replace(let text):
                if let e = existing { edits.append((e.start...e.end, "\(key): \(text)")) }
                else { appended.append("\(key): \(text)") }
            }
        }

        // Apply back to front so earlier ranges keep their indices.
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            lines.replaceSubrange(edit.range, with: [edit.replacement])
        }
        lines.append(contentsOf: appended)
        return note.leadingMark
            + "---" + le + lines.joined(separator: le) + le + "---" + le + note.body
    }

    private enum Patch {
        /// Leave the original bytes exactly as they are.
        case leave
        /// The value after `key: ` to write.
        case replace(String)
    }

    /// Decides, per modelled key, whether the on-disk text still represents the
    /// model's value. If it does, the original bytes are left alone — that is
    /// what keeps block sequences, quoting and ISO-8601 dates intact. Only a
    /// value that genuinely CHANGED is rewritten, and only that key's lines.
    ///
    /// A key ABSENT from the original is appended only when the model holds
    /// something real to say about it. `id` always qualifies — without it Lore
    /// invents a new identity on every load. A title that is merely derived
    /// from the body heading or the filename, an empty tag list, and a
    /// `created`/`updated` that defaulted to "now" because the file never had
    /// one are all fabrications, and writing them into a user's vault is the
    /// same corruption class this task exists to remove.
    private static func patch(key: String, note: Note, entry: Entry?) -> Patch {
        switch key {
        case "id":
            guard let entry else { return .replace(yamlScalar(note.id)) }
            return unquoted(entry.inlineValue) == note.id ? .leave : .replace(yamlScalar(note.id))
        case "title":
            // An empty title is not a value, it is the ABSENCE of one: `parse`
            // always derives a title from the body heading or the filename, so
            // `title: ""` could never survive a reload anyway. Writing it would
            // just put a meaningless key in the user's vault.
            guard !note.title.isEmpty else { return .leave }
            guard let entry else {
                return note.title == deriveTitle(note.body, path: note.path)
                    ? .leave : .replace(yamlScalar(note.title))
            }
            return unquoted(entry.inlineValue) == note.title
                ? .leave : .replace(yamlScalar(note.title))
        case "tags":
            guard let entry else { return note.tags.isEmpty ? .leave : .replace(inline(note.tags)) }
            return list(of: entry) == note.tags ? .leave : .replace(inline(note.tags))
        case "created", "updated":
            guard let entry else { return .leave }
            // Unparseable dates are NEVER rewritten: Lore does not corrupt a
            // timestamp it merely failed to understand.
            guard let onDisk = date(from: entry.inlineValue) else { return .leave }
            let model = key == "created" ? note.created : note.updated
            guard onDisk.date != model else { return .leave }
            // Re-emit in the format the file already used. Downgrading an
            // ISO-8601 `updated:` to `yyyy-MM-dd` would truncate it to UTC
            // midnight on every save, permanently degrading any external tool
            // that sorts on it to day granularity.
            return .replace(onDisk.formatter.string(from: model))
        default:
            return .leave
        }
    }

    private static func inline(_ values: [String]) -> String {
        "[" + values.map(yamlScalar).joined(separator: ", ") + "]"
    }

    /// Emission for a note that never had a frontmatter block (a brand new note
    /// or a plain markdown file). Nothing to preserve, so the model is the
    /// whole truth.
    ///
    /// `extra` is deliberately NOT emitted here. It is a DERIVED, lossy,
    /// index-only rendering — a block sequence flattens to `[one, two]` and
    /// quoted scalars are unquoted — so re-emitting it would write back
    /// something that is not what the file said. `rawFrontmatter` is the sole
    /// source of truth for serialization, and by construction a note that
    /// reaches this path has no `rawFrontmatter` and therefore no `extra`
    /// either. The old `"\(key): \(rawValue)"` line was both dead and
    /// unescaped: one caller away from re-introducing the property-injection
    /// bug the `yamlScalar` writer exists to prevent.
    private static func serializeFromModel(_ note: Note) -> String {
        let le = note.lineEnding
        let lines = [
            "id: \(yamlScalar(note.id))",
            "title: \(yamlScalar(note.title))",
            "tags: \(inline(note.tags))",
            "created: \(dayFormatter.string(from: note.created))",
            "updated: \(dayFormatter.string(from: note.updated))",
        ]
        return note.leadingMark
            + "---" + le + lines.joined(separator: le) + le + "---" + le + note.body
    }

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
            guard let (key, value) = keyValue(lines[i]) else { i += 1; continue }
            var j = i + 1
            var last = i
            while j < lines.count {
                let line = lines[j]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { j += 1; continue }  // provisional
                guard line.hasPrefix(" ") || line.hasPrefix("\t")
                        || trimmed.hasPrefix("- ") || trimmed == "-" else { break }
                last = j
                j += 1
            }
            entries.append(Entry(key: key, inlineValue: value,
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
              !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
        // Prefer a colon that YAML would accept as a key terminator (followed
        // by a space or end of line) so `title: a: b` keys on the first colon
        // and `url: https://x` does not key on the scheme colon.
        let chars = Array(line)
        var colon: Int?
        for (idx, ch) in chars.enumerated() where ch == ":" {
            if idx == chars.count - 1 || chars[idx + 1] == " " { colon = idx; break }
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
        var needsQuotes = value.isEmpty
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

    // MARK: - lists

    /// A list value in either shape: inline `[a, b]` or a block sequence.
    private static func list(of entry: Entry) -> [String] {
        entry.inlineValue.isEmpty ? sequenceItems(entry.continuation) : inlineList(entry.inlineValue)
    }

    static func sequenceItems(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t == "-" else { return nil }
            t = String(t.dropFirst(t == "-" ? 1 : 2)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : unquoted(t)
        }
    }

    /// Splits `[a, "b, c"]` on commas OUTSIDE quotes, so an item that legally
    /// contains a comma is not torn in half.
    private static func inlineList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var items: [String] = []
        var current = ""
        var fence: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if fence == "\"", ch == "\\" { current.append(ch); escaped = true; continue }
            if let f = fence {
                current.append(ch)
                if ch == f { fence = nil }
            } else if ch == "\"" || ch == "'" {
                fence = ch; current.append(ch)
            } else if ch == "," {
                items.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items.map { unquoted($0) }.filter { !$0.isEmpty }
    }

    // MARK: - dates

    private static let dayFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    /// Lenient date parsing. `yyyy-MM-dd` is what Lore writes; ISO-8601 (with
    /// or without fractional seconds, with or without a zone) is what sync
    /// tools, templater plugins and generators write. Anything else returns nil
    /// and is then left untouched on disk rather than overwritten with today.
    ///
    /// The matching formatter is returned as well so a value that DOES change
    /// can be re-emitted in the format the file already used.
    static func date(from raw: String) -> (date: Date, formatter: DateFormatter)? {
        let value = unquoted(raw)
        guard !value.isEmpty else { return nil }
        for f in dateFormatters {
            if let d = f.date(from: value) { return (d, f) }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = [
        "yyyy-MM-dd",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
    ].map(formatter)

    // MARK: - no frontmatter

    private static func fallback(path: URL, layout: Layout) -> Note {
        let now = Date()
        let text = layout.strippedText
        return Note(path: path, id: UUID().uuidString, title: deriveTitle(text, path: path),
                    tags: [], aliases: [], created: now, updated: now, body: text, extra: [],
                    rawFrontmatter: nil, lineEnding: layout.ending, hasByteOrderMark: layout.bom)
    }

    private static func deriveTitle(_ body: String, path: URL) -> String {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return path.deletingPathExtension().lastPathComponent
    }
}
