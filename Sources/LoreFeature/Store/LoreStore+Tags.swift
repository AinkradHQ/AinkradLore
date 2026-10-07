import Foundation
import NaturalLanguage

extension LoreStore {
    /// Tags worth adding to the note at `url`, best first. Suggestions only —
    /// nothing is written until the user accepts one (`addTag`).
    ///
    /// - A tag the vault already uses whose name appears in the note: 3.
    /// - A tag carried by a related note: 1 per note carrying it.
    /// - A noun the note keeps repeating (3+ times) that is not a tag yet: 1,
    ///   at most two of these — the vault's own vocabulary comes first.
    func suggestedTags(for url: URL, limit: Int = 5) -> [String] {
        let path = VaultIndexCoordinator.canonical(url)
        guard let me = rows.first(where: { $0.path == path }),
            // `try?`: an unreadable note has no text to suggest tags from.
            let text = try? String(contentsOf: path, encoding: .utf8)
        else { return [] }
        let have = Set(me.tags.map { $0.lowercased() })
        let lowered = text.lowercased()
        var scores: [String: Int] = [:]

        for tag in allTags where !have.contains(tag.lowercased()) {
            let words = tag.lowercased().replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            if lowered.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: words))\\b",
                options: .regularExpression) != nil
            {
                scores[tag, default: 0] += 3
            }
        }
        for row in relatedNotes(to: path) {
            for tag in row.tags where !have.contains(tag.lowercased()) { scores[tag, default: 0] += 1 }
        }
        let known = Set(allTags.map { $0.lowercased() })
        for noun in Self.repeatedNouns(in: text).prefix(2)
        where !have.contains(noun) && !known.contains(noun) {
            scores[noun, default: 0] += 1
        }
        return
            scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// Lemmatised nouns occurring 3+ times, most frequent first.
    static func repeatedNouns(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var counts: [String: Int] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            guard tag == .noun else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let word = (lemma ?? String(text[range])).lowercased()
            if word.count >= 4, word.allSatisfy(\.isLetter) { counts[word, default: 0] += 1 }
            return true
        }
        return counts.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// Adds `tag` to the markdown note at `url`'s frontmatter.
    ///
    /// An open tab's unsaved edits are flushed first, and a tab that still
    /// cannot save refuses the change — the file is never rewritten under text
    /// the user has not seen saved (the rule `trash` follows). The open tab
    /// then reloads through the same external-change path any save uses.
    func addTag(_ tag: String, to url: URL) throws {
        let path = VaultIndexCoordinator.canonical(url)
        for session in tabs where VaultIndexCoordinator.canonical(session.url) == path && session.isDirty {
            // `try?`: a refused flush leaves the session dirty, and the guard below surfaces it.
            if !session.isReadOnly { try? session.saveNow() }
            guard !session.isDirty else {
                throw LoreError.unsavedEdits(path, "it has unsaved edits. Save the open tab, then add the tag again.")
            }
        }
        var note = try MarkdownEngine.load(path).note
        guard !note.tags.contains(tag) else { return }
        note.tags.append(tag)
        // Read from disk a moment ago, so there is no newer text to protect;
        // a stale legacy mtime baseline must not refuse it.
        try save(note, overwritingExternalChanges: true)
    }
}
