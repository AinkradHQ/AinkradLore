import Accelerate
import Foundation
import GRDB
import NaturalLanguage

/// Semantic search: one on-device sentence vector per note (Apple's
/// `NaturalLanguage`, no network, no dependency), so a query finds notes that
/// MEAN the same thing without sharing its words.
///
/// Vectors live in the `embeddings` table, keyed by path and stamped with the
/// document's `updated` — a note is re-embedded only when it changed. The
/// table is derived state like the rest of the index; a schema bump drops it
/// with everything else.
///
/// `ponytail:` English model only, one vector per note from its title and first
/// 500 characters, brute-force dot product over every vector. The model's cost
/// is linear in text length (measured: 27 ms at 300 chars, 174 ms at 2,000), so
/// the opening is what a note gets judged by. Add per-language models, chunking
/// or an ANN index when a vault proves it needs them.
enum LoreEmbeddings {
    /// Below this cosine similarity a note is not "about" the query. Measured
    /// on short notes: related pairs 0.36–0.75 ("sourdough baking tips" vs a
    /// bread note: 0.49), unrelated pairs 0.15–0.26.
    static let threshold: Float = 0.35

    static func model() -> NLEmbedding? { NLEmbedding.sentenceEmbedding(for: .english) }

    /// True when at least one word of `query` is in the English vocabulary.
    /// A query of unknown words ("zorkmid", a typo, a product name) still gets
    /// a vector — one that lands near any tiny note (measured 0.43–0.62) — so
    /// it is answered by keywords alone.
    static func hasKnownWord(_ query: String, vocabulary: NLEmbedding) -> Bool {
        query.lowercased().split { !$0.isLetter }.contains { vocabulary.contains(String($0)) }
    }

    /// Unit length, so similarity is a plain dot product.
    static func vector(_ text: String, model: NLEmbedding) -> [Float]? {
        model.vector(for: text).map { normalized($0.map(Float.init)) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm.squareRoot())
    }

    /// Embeds every note that is missing a vector or changed since, drops
    /// vectors for notes that are gone, and returns them all. Off the main actor.
    static func refresh(_ index: LoreIndex) -> [String: [Float]] {
        Log.search.orNil("create the embeddings table") { try index.ensureEmbeddingsTable() }
        if let model = model(),
            let stale = Log.search.orNil("read stale embedding sources", { try index.staleEmbeddingSources() })
        {
            var batch: [(String, Double, [Float])] = []
            for source in stale {
                if Task.isCancelled { break }
                if let v = vector(source.text, model: model) { batch.append((source.path, source.updated, v)) }
                if batch.count == 64 {
                    Log.search.orNil("save embeddings") { try index.saveEmbeddings(batch) }
                    batch = []
                }
            }
            Log.search.orNil("save embeddings") { try index.saveEmbeddings(batch) }
        }
        Log.search.orNil("prune embeddings") { try index.pruneEmbeddings() }
        return Log.search.orNil("read embeddings") { try index.embeddings() } ?? [:]
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Paths closest to `query`, best first, above `threshold`. Both sides
    /// must be unit vectors (`vector`, `embeddings()`).
    static func nearest(to query: [Float], in vectors: [String: [Float]], limit: Int) -> [(String, Float)] {
        vectors.compactMap { path, v -> (String, Float)? in
            guard v.count == query.count else { return nil }
            var s: Float = 0
            vDSP_dotpr(query, 1, v, 1, &s, vDSP_Length(v.count))
            return s >= threshold ? (path, s) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map { $0 }
    }
}

extension LoreIndex {
    func ensureEmbeddingsTable() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS embeddings(
                        path TEXT PRIMARY KEY, updated DOUBLE NOT NULL, vector BLOB NOT NULL);
                    """)
        }
    }

    /// Notes with text whose vector is missing or older than the note.
    func staleEmbeddingSources() throws -> [(path: String, updated: Double, text: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.path, d.updated, d.title || '. ' || substr(d.plaintext, 1, 500) AS text
                    FROM documents d LEFT JOIN embeddings e ON e.path = d.path
                    WHERE length(d.plaintext) > 0 AND (e.path IS NULL OR e.updated != d.updated)
                    """
            ).map { (path: $0["path"], updated: $0["updated"], text: $0["text"]) }
        }
    }

    func saveEmbeddings(_ batch: [(String, Double, [Float])]) throws {
        guard !batch.isEmpty else { return }
        try dbQueue.write { db in
            for (path, updated, vector) in batch {
                let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO embeddings(path, updated, vector) VALUES (?, ?, ?)",
                    arguments: [path, updated, blob])
            }
        }
    }

    func pruneEmbeddings() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE path NOT IN (SELECT path FROM documents)")
        }
    }

    func embeddings() throws -> [String: [Float]] {
        try dbQueue.read { db in
            var out: [String: [Float]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path, vector FROM embeddings") {
                let data: Data = row["vector"]
                out[row["path"]] = LoreEmbeddings.normalized(
                    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
            }
            return out
        }
    }
}
