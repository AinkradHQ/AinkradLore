import Foundation
import GRDB

extension LoreIndex {
    // MARK: - Links

    /// Documents containing a link that resolves to `target`.
    func backlinks(to target: URL) throws -> [IndexRow] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                        SELECT DISTINCT d.* FROM documents d
                        JOIN links l ON l.source_path = d.path
                        WHERE l.target_path = ?
                        ORDER BY d.updated DESC;
                    """, arguments: [Self.canonical(target)]
            ).map(Self.row)
        }
    }

    /// Every (file, rawTarget) pair pointing at `target`.
    ///
    /// Distinct from `backlinks(to:)`, which returns one row per SOURCE
    /// DOCUMENT: a rename must rewrite every individual link, so a document
    /// linking twice with two different spellings (`[[Design]]` and
    /// `[[Projects/Design.md]]`) has to yield two rows here, not one.
    func inboundLinks(to target: URL) throws
        -> [(sourceFile: URL, rawTarget: String, syntax: LinkSyntax)]
    {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                        SELECT DISTINCT source_path, raw_target, syntax FROM links
                        WHERE target_path = ?;
                    """, arguments: [Self.canonical(target)]
            ).map { r in
                let source: String = r["source_path"]
                let raw: String = r["raw_target"]
                return (
                    sourceFile: URL(fileURLWithPath: source), rawTarget: raw,
                    syntax: Self.syntax(r["syntax"])
                )
            }
        }
    }

    /// A stored `links.syntax` value. Anything unrecognised reads as
    /// `.wikilink`, the syntax that applies NO percent-decoding — the choice
    /// that treats a target verbatim rather than transforming it on a guess.
    private static func syntax(_ raw: String?) -> LinkSyntax {
        raw.flatMap(LinkSyntax.init(rawValue:)) ?? .wikilink
    }

    /// This document's outbound links that resolve to nothing. A normal state:
    /// it is how a link to a not-yet-written note behaves.
    func unresolvedLinks(from source: URL) throws -> [UnresolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                        SELECT raw_target, syntax FROM links
                        WHERE source_path = ? AND target_path IS NULL;
                    """, arguments: [Self.canonical(source)]
            ).map { r in
                UnresolvedLink(rawTarget: r["raw_target"], syntax: Self.syntax(r["syntax"]))
            }
        }
    }

    func outgoingLinks(from source: URL) throws -> [ResolvedLink] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                        SELECT raw_target, target_path, is_embed, syntax FROM links
                        WHERE source_path = ?;
                    """, arguments: [Self.canonical(source)]
            ).map { r in
                ResolvedLink(
                    rawTarget: r["raw_target"],
                    targetPath: (r["target_path"] as String?).map {
                        URL(fileURLWithPath: $0)
                    },
                    isEmbed: (r["is_embed"] as Int) == 1,
                    syntax: Self.syntax(r["syntax"]))
            }
        }
    }

    // MARK: - Blocks

    /// Where a block anchor sits, or `nil` if that document has no such
    /// anchor. Used to resolve `[[Note#^id]]`.
    func blockOffset(inDocumentAt path: String, id: String) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                        SELECT offset FROM blocks WHERE source_path = ? AND block_id = ? LIMIT 1;
                    """, arguments: [path, id])
        }
    }
}
