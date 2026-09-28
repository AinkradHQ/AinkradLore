import Foundation

extension LoreStore {
    /// Notes worth reading next to the one at `url`, best first: its link-graph
    /// neighbours (see `LoreIndex.linkNeighbours`) plus 1 per shared tag, and —
    /// once embeddings exist — how close the two notes are in meaning.
    /// Backlinks are left out: the list right above this one already shows them.
    public func relatedNotes(to url: URL, limit: Int = 8) -> [IndexRow] {
        let path = VaultIndexCoordinator.canonical(url)
        guard let me = rows.first(where: { $0.path == path }) else { return [] }
        var scores = coordinator.linkNeighbours(of: path)
        let tags = Set(me.tags)
        if !tags.isEmpty {
            for row in rows where row.path != path {
                let shared = tags.intersection(row.tags).count
                if shared > 0 { scores[row.path.path, default: 0] += shared }
            }
        }
        let backlinks = Set(coordinator.backlinkRows(to: path).map(\.path.path))
        let byPath = Dictionary(rows.map { ($0.path.path, $0) }, uniquingKeysWith: { a, _ in a })
        return scores
            .filter { $0.key != path.path && !backlinks.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { byPath[$0.key] }
    }
}
