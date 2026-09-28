import Foundation

/// Reads an Obsidian vault as-is: it is already markdown with `[[wikilinks]]`, so nothing
/// is converted here. This source walks the tree and emits one `ImportItem` per file,
/// flagging syntax Lore renders differently (Dataview blocks, callouts) rather than
/// silently rewriting it.
public struct ObsidianSource: ImportSource {
    public static let identifier = "obsidian"
    private let vaultURL: URL

    public init(vaultURL: URL) { self.vaultURL = vaultURL }

    public func scan() async throws -> [ImportItem] {
        let vaultURL = self.vaultURL
        // Off the calling actor: `FileManager.enumerator` walks the whole tree
        // synchronously and can be slow on large vaults.
        return try await Task.detached(priority: .utility) {
            try Self.scanSync(vaultURL: vaultURL)
        }.value
    }

    private static func scanSync(vaultURL: URL) throws -> [ImportItem] {
        // Canonicalise FIRST: Obsidian vaults in iCloud Drive are full of symlinks,
        // and every path computed below is relative to this resolved root.
        let root = URL(fileURLWithPath: vaultURL.resolvingSymlinksInPath().path)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        else { throw ImportSourceError.sourceUnavailable(root.path) }

        let rootComponentCount = root.standardizedFileURL.pathComponents.count
        var items: [ImportItem] = []
        for case let url as URL in walker {
            // `String` replacement on paths is fragile when the root passed through
            // `resolvingSymlinksInPath()` (e.g. /var -> /private/var on macOS) while
            // the enumerator hands back URLs built from a different prefix form —
            // component-count arithmetic is immune to that mismatch.
            let components = Array(
                url.standardizedFileURL.pathComponents.dropFirst(rootComponentCount))
            let relative = components.joined(separator: "/")
            // Skip the Obsidian config directory, and any dot-directory/file at any
            // depth (not just the vault root) — `.trash`, `.git`, editor swap dirs, etc.
            if components.first == ".obsidian" || components.contains(where: { $0.hasPrefix(".") }) {
                walker.skipDescendants()
                continue
            }

            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == false else { continue }

            let folders = Array(components.dropLast())
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()

            if url.pathExtension.lowercased() == "md" {
                items.append(markdownItem(
                    url: url, relative: relative, folders: folders, modified: modified))
            } else {
                items.append(ImportItem(
                    sourceID: "\(identifier):\(relative)",
                    title: url.lastPathComponent,
                    body: .markdown(""),
                    attachments: [ImportAttachment(
                        sourceID: "\(identifier):\(relative)",
                        preferredName: url.lastPathComponent,
                        sourceURL: url)],
                    folderPath: folders,
                    created: modified,
                    modified: modified,
                    fidelity: [],
                    // Declared, not inferred: in an Obsidian vault a non-`.md`
                    // file IS the item, and there is no note to write for it.
                    kind: .file))
            }
        }
        return items
    }

    private static func markdownItem(
        url: URL, relative: String, folders: [String], modified: Date
    ) -> ImportItem {
        var fidelity: [FidelityWarning] = []
        let text: String
        if let data = try? Data(contentsOf: url), let decoded = String(data: data, encoding: .utf8) {
            text = decoded
            fidelity.append(contentsOf: pluginWarnings(in: decoded))
        } else {
            // Unreadable or non-UTF8: importing an empty note in place of the user's
            // real content is exactly the silent-loss failure this milestone guards
            // against, so flag it instead of pretending the note was empty.
            text = ""
            fidelity.append(FidelityWarning(
                kind: .unsupportedElement,
                detail: "could not read \(relative) as UTF-8 text; note imported empty"))
        }
        return ImportItem(
            sourceID: "\(identifier):\(relative)",
            title: url.deletingPathExtension().lastPathComponent,
            body: .markdown(text),
            attachments: [],
            folderPath: folders,
            created: modified,
            modified: modified,
            fidelity: fidelity)
    }

    /// Reported, never rewritten. Lore renders these as plain blockquotes/code, and
    /// silently degrading them would surface months later — the worse failure.
    static func pluginWarnings(in text: String) -> [FidelityWarning] {
        var warnings: [FidelityWarning] = []
        if text.contains("```dataview") {
            warnings.append(FidelityWarning(kind: .pluginSyntax,
                                            detail: "Dataview block kept verbatim"))
        }
        if text.range(of: #"^>\s*\[!"#, options: [.regularExpression, .anchored]) != nil
            || text.contains("\n> [!") {
            warnings.append(FidelityWarning(kind: .pluginSyntax,
                                            detail: "callout renders as a blockquote"))
        }
        return warnings
    }
}
