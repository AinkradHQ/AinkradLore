import Foundation
import GRDB

extension LoreIndex {
    /// Link-graph neighbours of the note at `url`, scored — the half of
    /// "related notes" the index can answer on its own:
    ///
    /// - 3 per link FROM this note to the candidate: the author connected them.
    /// - 2 per link target they share: both notes cite the same thing.
    ///
    /// Backlinks are not scored here — they already have their own list.
    func linkNeighbours(of url: URL) throws -> [String: Int] {
        let path = VaultIndexCoordinator.canonical(url).path
        return try dbQueue.read { db in
            var scores: [String: Int] = [:]
            let outgoing = try String.fetchAll(
                db,
                sql: """
                    SELECT target_path FROM links
                    WHERE source_path = ? AND target_path IS NOT NULL AND target_path != ?
                    """, arguments: [path, path])
            for target in outgoing { scores[target, default: 0] += 3 }
            let cocited = try Row.fetchAll(
                db,
                sql: """
                    SELECT l2.source_path AS path, COUNT(*) AS shared
                    FROM links l1 JOIN links l2 ON l2.target_path = l1.target_path
                    WHERE l1.source_path = ? AND l2.source_path != ? AND l1.target_path IS NOT NULL
                    GROUP BY l2.source_path
                    """, arguments: [path, path])
            for row in cocited { scores[row["path"], default: 0] += 2 * (row["shared"] as Int) }
            return scores
        }
    }
}
