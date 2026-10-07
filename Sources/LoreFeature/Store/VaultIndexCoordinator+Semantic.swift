import Foundation
import NaturalLanguage

extension VaultIndexCoordinator {
    /// Brings the note vectors up to date off the main actor, after every
    /// rebuild. Coalesces like `startBackgroundRebuild`.
    func startEmbedding() {
        guard !isEmbedding, let index else { return }
        isEmbedding = true
        Task { [weak self] in
            let vectors = await Task.detached(priority: .background) {
                LoreEmbeddings.refresh(index)
            }.value
            guard let self else { return }
            if self.index === index {
                self.embeddings = vectors
                self.lastQueryNearest = nil
            }
            self.isEmbedding = false
        }
    }

    /// Test seam: wait until no embedding pass is in flight.
    func settleEmbeddingsForTesting() async {
        while isEmbedding { await Task.yield() }
    }

    /// Notes that mean what `query` says, for search to list AFTER its keyword
    /// hits: keyword matches stay first, meaning fills in what words missed.
    func semanticRows(for query: String, excluding: Set<String>, limit: Int = 20) -> [IndexRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, !embeddings.isEmpty,
            let nearest = queryNearest(trimmed, limit: limit + excluding.count)
        else { return [] }
        let byPath = Dictionary(rows.map { ($0.path.path, $0) }, uniquingKeysWith: { a, _ in a })
        return
            nearest
            .filter { !excluding.contains($0.0) }
            .prefix(limit)
            .compactMap { byPath[$0.0] }
    }

    /// Closest notes by meaning to the note at `path` — used by related notes.
    func semanticNeighbours(of path: String, limit: Int = 8) -> [(String, Float)] {
        guard let vector = embeddings[path] else { return [] }
        return LoreEmbeddings.nearest(to: vector, in: embeddings, limit: limit + 1).filter { $0.0 != path }
    }

    /// The search box re-renders per keystroke and asks twice per render, so
    /// the last query's answer is kept.
    private func queryNearest(_ query: String, limit: Int) -> [(String, Float)]? {
        if let cached = lastQueryNearest, cached.query == query, cached.limit >= limit { return cached.nearest }
        if embeddingModel == nil {
            embeddingModel = LoreEmbeddings.model()
            vocabulary = NLEmbedding.wordEmbedding(for: .english)
        }
        guard let model = embeddingModel, let vocabulary,
            LoreEmbeddings.hasKnownWord(query, vocabulary: vocabulary),
            let v = LoreEmbeddings.vector(query, model: model)
        else { return nil }
        let nearest = LoreEmbeddings.nearest(to: v, in: embeddings, limit: limit)
        lastQueryNearest = (query, limit, nearest)
        return nearest
    }
}
