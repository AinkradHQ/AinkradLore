import Foundation

// The store-side half of the editor's link affordances: which text to WRITE for
// a link so that reading it back finds the same document, and whether a path
// derived from link text really lands inside the vault.
//
// Both are here rather than in the views because both need the resolver or the
// vault root, and neither is a rendering concern. Extracted from `LoreStore.swift`
// to keep that file under the project's 500-line ceiling.
/// Why a link target could not name a note to create. Its own error type
/// rather than a `LoreError` case because it never crosses the MCP boundary —
/// it is reachable only from a "Create note" affordance in the UI.
public struct UncreatableLinkTarget: LocalizedError, Equatable {
    public let target: String
    public var errorDescription: String? { "“\(target)” doesn’t name a note." }
}

extension LoreStore {
    /// Creates the note a dead link names, and opens it.
    ///
    /// THE SINGLE create-from-a-link path. Both callers — the "Create" prompt
    /// on a Cmd-clicked dead link (`DocumentPane`) and the "Create note" button
    /// in the unresolved-links list (`BacklinksPanel`) — go through here.
    ///
    /// They used to have separate implementations, and the second one was still
    /// carrying the bug the first one had already been fixed for: it passed
    /// `LinkResolver.basename(of:)` straight to `create(title:)`, which keeps
    /// both the `/` and the `|alias`. So `[[Projects/Design]]` asked for a note
    /// titled `Projects/Design`, whose slug is a path into a folder that does
    /// not exist — the write threw, the `try?` swallowed it, and the button did
    /// nothing at all. `[[Design|why]]` produced a file called `design|why.md`,
    /// which does not resolve the link it was created for. Two implementations
    /// of one rule is how that survived, so there is now one.
    ///
    /// Two things it must do, in this order:
    ///  - `documentName(of:)`, which strips the `|alias` AND the `#fragment`;
    ///    `LinkResolver.basename` strips only the fragment.
    ///  - split the remaining `/`, because a target with a folder is a PATH
    ///    SUFFIX to `LinkResolver`: a note flattened into the default folder
    ///    would leave the very link the user clicked still unresolved.
    ///
    ///  - percent-DECODE the target first, for a `.markdown`-syntax link only.
    ///    Clicking "Create note" on a dead `[t](Design%20Doc.md)` used to create
    ///    a junk file literally named `design%20doc.md`, which then did not
    ///    resolve the link it was created for — the same class of bug as the
    ///    two above. The decode is not open-coded here: it goes through
    ///    `DocumentLink.resolutionTarget`, the ONE rule that decides what a
    ///    target names, so the created note is by construction the note the
    ///    resolver will look for.
    ///
    /// ## Why `syntax` is a required parameter
    ///
    /// It has no default. A default is what lets a new call site inherit a
    /// decoding rule it never thought about — and every bug in this method's
    /// history is a call site that skipped a step. Both existing callers now
    /// have to state where the syntax came from, and neither has to guess:
    /// `DocumentPane`'s Cmd-click path can only fire on a `[[…]]` span (see
    /// `LinkCompletionContext.target(in:at:)`, which scans for `[[`/`]]` and
    /// nothing else), and `BacklinksPanel` reads it off the `UnresolvedLink`
    /// row the index stored when it parsed the link.
    ///
    /// Throws rather than returning an optional: a create that fails must reach
    /// the user, and the caller's job is only to show it.
    @discardableResult
    public func createAndOpenNote(forLinkTarget target: String,
                                  syntax: LinkSyntax) throws -> Note {
        let note = try createNote(forLinkTarget: target, syntax: syntax)
        open(url: note.path)
        return note
    }

    /// Creates the note a link names WITHOUT opening it.
    ///
    /// Split from `createAndOpenNote` for the completion popup's "Create this
    /// note" row: that fires mid-sentence, and navigating away from the
    /// document being written to the note just referenced in it is the
    /// opposite of what the writer asked for. Every other caller still wants
    /// the open, so they keep it.
    ///
    /// One implementation of the naming rules — the alias/fragment stripping
    /// and the folder split — so the two doors cannot disagree about what
    /// `[[Projects/Q1|the plan]]` should create.
    @discardableResult
    public func createNote(forLinkTarget target: String,
                           syntax: LinkSyntax) throws -> Note {
        let decoded = DocumentLink(rawTarget: target, syntax: syntax).resolutionTarget
        var parts = LinkCompletionContext.documentName(of: decoded)
            .split(separator: "/").map(String.init)
        guard let title = parts.popLast(), !title.isEmpty else {
            throw UncreatableLinkTarget(target: target)
        }
        return try create(title: title, in: parts.joined(separator: "/"))
    }

    /// The wikilink target to write for `row`, guaranteed — where the vault
    /// makes it possible at all — to resolve back to `row` and not to some
    /// other document that happens to share its title.
    ///
    /// Lives here rather than in the view because the guarantee needs the
    /// resolver and the vault root; the decision itself is the pure
    /// `LinkCompletionContext.insertableTarget`.
    public func linkTarget(for row: IndexRow) -> String {
        LinkCompletionContext.insertableTarget(
            for: row,
            relativePath: Self.vaultRelativePath(of: row.path, under: vaultRoot),
            resolves: { [weak self] in self?.resolveLink($0) })
    }

    /// Whether `url` really sits inside `root` once symlinks are resolved.
    ///
    /// Resolves the deepest ancestor that actually exists, so it is meaningful
    /// for a directory that has not been created yet: the symlink that could
    /// redirect the write is by definition already on disk.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        var existing = url.standardizedFileURL
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in trailing { resolved.appendPathComponent(part) }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = resolved.standardizedFileURL.path
        // The `/` matters: without it `/vault-backup` counts as inside `/vault`.
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath
                                                                         : rootPath + "/")
    }

    /// `Projects/Design` for `<vault>/Projects/Design.md`. Empty when the
    /// document is not under the vault root — in which case no path target
    /// could name it anyway.
    static func vaultRelativePath(of url: URL, under root: URL?) -> String {
        guard let root else { return "" }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.deletingPathExtension().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return "" }
        return String(path.dropFirst(prefix.count))
    }

}
