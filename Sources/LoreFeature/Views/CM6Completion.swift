import AppKit

/// `[[` and `#` completion for the CodeMirror surface.
///
/// ## What is reused, and why that matters
///
/// The DECISIONS are the native editor's, unchanged:
///
/// - `LinkCompletionContext.trigger(in:at:)` decides whether the caret is
///   completing a wikilink or a tag, and what the query is. It already knows
///   that `[[` owns any `#` that follows, so `[[Note#Head` is a heading
///   fragment rather than a tag.
/// - `LinkCompletionContext.headingQuery(inPrefix:)` splits a heading query.
/// - `MarkdownEditing.linkInsertionRange(text:caret:prefixLength:)` decides
///   what range an accepted row replaces, including absorbing an already-typed
///   `]]` so an accepted completion never reads `[[Target]]]]`.
///
/// None of that is reimplemented here and none of it is reimplemented in
/// JavaScript. A second scanner would disagree with the first the moment either
/// changed, and it would disagree about which text is a link — which is the one
/// thing the two surfaces must never differ on.
///
/// ## What this adds
///
/// Only the translation: CodeMirror positions are UTF-16 offsets and
/// `LinkCompletionContext` works in CHARACTER offsets, so a caret past an emoji
/// means different things to the two. Getting that wrong is not a cosmetic bug
/// — it replaces the wrong range on accept.
enum CM6Completion {

    /// One row offered to the page.
    struct Item: Equatable {
        let label: String
        let detail: String
        /// The text that replaces `range`, closing delimiter included.
        let insert: String
        /// A "create this note" row. The note must be made in Swift BEFORE the
        /// text is inserted, so a refused create leaves the document untouched
        /// rather than writing a link to a note that was never made — the same
        /// order the native `accept(_:)` uses.
        let createsNote: String?
    }

    /// What the page is told: the rows, and the UTF-16 range they replace.
    struct Query: Equatable {
        let from: Int
        let to: Int
        let items: [Item]
    }

    /// The caret's UTF-16 offset as a CHARACTER offset.
    ///
    /// Returns nil for an offset that does not land on a character boundary —
    /// the middle of a surrogate pair — rather than guessing, because a guess
    /// here silently shifts every range that follows.
    static func characterOffset(ofUTF16 offset: Int, in text: String) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        guard
            let index = String.Index(utf16Offset: offset, in: text)
                .samePosition(in: text)
        else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }

    /// The rows for the caret at `utf16Caret`, or nil when nothing is being
    /// completed.
    ///
    /// - Parameters kept as closures rather than a context object so this stays
    ///   testable without building an `EditorContext`.
    @MainActor
    static func query(
        text: String, utf16Caret: Int,
        documents: (String) -> [IndexRow],
        headings: (String, String) -> HeadingCompletions?,
        tags: (String) -> [String],
        linkTarget: (IndexRow) -> String,
        canCreate: Bool
    ) -> Query? {
        guard let caret = characterOffset(ofUTF16: utf16Caret, in: text),
            let trigger = LinkCompletionContext.trigger(in: text, at: caret)
        else { return nil }

        switch trigger.kind {
        case .tag:
            // The `#` through the caret. No closing delimiter to absorb — a tag
            // is the `#` and the word after it.
            let from = utf16Caret - trigger.query.utf16.count - 1
            guard from >= 0 else { return nil }
            let items = tags(trigger.query).map {
                Item(label: "#" + $0, detail: "tag", insert: "#" + $0, createsNote: nil)
            }
            return items.isEmpty ? nil : Query(from: from, to: utf16Caret, items: items)

        case .wikilink:
            let range = MarkdownEditing.linkInsertionRange(
                text: text, caret: utf16Caret, prefixLength: trigger.query.utf16.count)
            var items: [Item] = []

            if let heading = LinkCompletionContext.headingQuery(inPrefix: trigger.query),
                let found = headings(heading.document, heading.heading)
            {
                // The document name is re-emitted with the fragment: the caret
                // sits after the `#`, and inserting only the heading would
                // leave `[[Design#Design#Overview]]`.
                // The VERIFIED target, not what was typed: `insertTarget` is
                // resolver-checked so the finished link cannot land on a
                // namesake in another folder. The native path takes the same
                // care (`found?.insertTarget ?? query.document`).
                let target =
                    found.insertTarget.isEmpty
                    ? heading.document
                    : found.insertTarget
                items = found.headings.map {
                    Item(
                        label: $0, detail: target,
                        insert: "\(target)#\($0)]]", createsNote: nil)
                }
                return items.isEmpty
                    ? nil
                    : Query(from: range.location, to: range.location + range.length, items: items)
            }

            let rows = documents(trigger.query)
            items = rows.map {
                Item(
                    label: $0.title.isEmpty ? $0.path.lastPathComponent : $0.title,
                    detail: $0.path.deletingLastPathComponent().lastPathComponent,
                    insert: linkTarget($0) + "]]", createsNote: nil)
            }
            let trimmed = trigger.query.trimmingCharacters(in: .whitespaces)
            if canCreate, !trimmed.isEmpty {
                let exists = rows.contains { row in
                    let name = row.title.isEmpty ? row.path.lastPathComponent : row.title
                    return name.compare(trimmed, options: .caseInsensitive) == .orderedSame
                }
                // LAST, never first: the common case is picking a note that
                // exists, and a create row at the top is one stray Return away
                // from a duplicate. The native `items(for:)` says the same.
                if !exists {
                    items.append(
                        Item(
                            label: "Create \u{201C}\(trimmed)\u{201D}",
                            detail: "new note",
                            insert: trimmed + "]]", createsNote: trimmed))
                }
            }
            return items.isEmpty
                ? nil
                : Query(from: range.location, to: range.location + range.length, items: items)
        }
    }

    /// The query as the JavaScript literal the page is handed.
    static func json(_ query: Query?) -> String {
        guard let query else { return "null" }
        let items: [[String: Any]] = query.items.map {
            var item: [String: Any] = [
                "label": $0.label, "detail": $0.detail,
                "insert": $0.insert,
            ]
            if let create = $0.createsNote { item["create"] = create }
            return item
        }
        let payload: [String: Any] = ["from": query.from, "to": query.to, "items": items]
        // `try?`: strings and ints always encode; `null` shows no list.
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }
}
