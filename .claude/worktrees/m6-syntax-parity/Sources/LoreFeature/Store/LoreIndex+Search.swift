import Foundation
import GRDB

/// Full-text search: the query, the excerpt, and the sanitiser that stands
/// between raw user input and FTS5's expression grammar.
///
/// Split out of `LoreIndex.swift` for the 500-line ceiling. These belong
/// together because they share one hazard — everything here goes through
/// `documents_fts MATCH`, whose argument is parsed as an FTS5 EXPRESSION
/// rather than taken as text, which is what `ftsExpression` exists to make
/// safe. Keeping the sanitiser beside its only callers is what stops a future
/// query being added that forgets it.
extension LoreIndex {

    public func search(_ query: String) throws -> [IndexRow] {
        guard let expression = Self.ftsExpression(for: query) else { return try all() }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.* FROM documents n
                JOIN documents_fts f ON f.rowid = n.rowid
                WHERE documents_fts MATCH ? ORDER BY rank;
            """, arguments: [expression]).map(Self.row)
        }
    }

    /// `search` throwing is never actionable at a call site; this is the shape
    /// every caller already used via `try?`.
    public func searchOrEmpty(_ query: String) -> [IndexRow] {
        (try? search(query)) ?? []
    }

    /// Search, with a matched excerpt per hit.
    ///
    /// The excerpt comes from FTS5's own `snippet()` rather than from reading
    /// the file again: the index already holds the tokenized plaintext, and
    /// re-reading N files to draw one list is exactly the main-actor cost this
    /// codebase spends its comments avoiding.
    ///
    /// Column 1 is `plaintext` — the FTS table is `fts5(title, plaintext)`, so
    /// 0 would excerpt the TITLE, which is already the row's headline and
    /// would produce a snippet that merely repeats it.
    ///
    /// `-1` as the column argument would let FTS pick the best-matching
    /// column, which sounds better and is not: a title-only match would then
    /// return the title as its own excerpt.
    public func searchHits(_ query: String) throws -> [SearchHit] {
        guard let expression = Self.ftsExpression(for: query) else {
            return try all().map { SearchHit(row: $0, snippet: nil) }
        }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.*, snippet(documents_fts, 1, ?, ?, '…', 12) AS excerpt
                FROM documents n
                JOIN documents_fts f ON f.rowid = n.rowid
                WHERE documents_fts MATCH ? ORDER BY rank;
            """, arguments: [SearchSnippet.open, SearchSnippet.close, expression])
            .map { row in
                let marked: String = row["excerpt"] ?? ""
                let parsed = SearchSnippet.parse(marked: marked)
                // No excerpt for a title-only or empty-body match — see
                // `SearchHit.snippet`. `matches.isEmpty` is the test that
                // distinguishes them: FTS still returns a leading fragment of
                // the body when the match was in the title, and showing that
                // as "why this matched" would be a small lie.
                let snippet = parsed.matches.isEmpty || parsed.text.isEmpty ? nil : parsed
                return SearchHit(row: Self.row(row), snippet: snippet)
            }
        }
    }

    public func searchHitsOrEmpty(_ query: String) -> [SearchHit] {
        (try? searchHits(query)) ?? []
    }

    /// Turns raw user input into a safe FTS5 MATCH expression, or `nil` when
    /// there is nothing to search for.
    ///
    /// The binding was already a SQL *parameter*, so this was never SQL
    /// injection — but a parameter passed to `MATCH` is still parsed by SQLite
    /// as an **FTS5 query expression**, and the raw string was handed over
    /// verbatim. So ordinary text broke it:
    ///
    /// * `size: 3` → `:` is the column filter operator → syntax error
    /// * `he said "hi` → unbalanced quote → syntax error
    /// * `AND`, `OR`, `NOT`, `NEAR` → bare operators → syntax error
    /// * `C++` / `a-b` → operator characters → syntax error
    ///
    /// A thrown error here is worse than it sounds: every call site uses
    /// `try?`, so a syntax error becomes an empty result set and the note
    /// browser silently reports "no matches" for a note that exists. Typing a
    /// colon made search look broken.
    ///
    /// Each whitespace-separated term is emitted as a quoted FTS5 string
    /// literal (embedded `"` doubled, per the FTS5 grammar) with a trailing
    /// `*` for prefix matching, joined by implicit AND. Inside a quoted
    /// literal every character is data, so no input can be an operator.
    static func ftsExpression(for query: String) -> String? {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { term -> String in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
