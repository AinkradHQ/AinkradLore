import Foundation
import AinkradAppKit

// `load`, `create`, `save` and the mtime bookkeeping that guards `save`
// against clobbering an externally-changed file. Moved out of
// `LoreStore.swift` to keep it under the 500-line ceiling, following the
// same extension-file convention as `LoreStore+Folders.swift`,
// `LoreStore+Trash.swift` and `LoreStore+Rename.swift`.
//
// `load` and `save` stay in the store deliberately: Task 7 did NOT take
// them, and Task 10 kept them because the MCP note tools are their only
// remaining callers (the UI goes through `DocumentSession`). M6 owns the
// redesign that decides where note-level read/write really belongs.
extension LoreStore {

    public func load(_ row: IndexRow) throws -> Note {
        let text = try String(contentsOf: row.path, encoding: .utf8)
        let note = Frontmatter.parse(text, path: row.path)
        openMTimes[Self.pathKey(row.path)] = try mtime(of: row.path)
        return note
    }

    /// - Parameter subfolder: a path relative to the default note folder, created
    ///   if missing. Only used by the "create the note this link points at" flow,
    ///   where `[[Projects/Design]]` names a folder as well as a note; empty
    ///   everywhere else, which is the pre-existing behaviour exactly.
    @discardableResult
    public func create(title: String, in subfolder: String = "") throws -> Note {
        guard let root = vaultRoot, coordinator.hasIndex else { throw LoreError.noVault }
        let slug = title.isEmpty ? "untitled" : title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        var dir = defaultNoteFolder.isEmpty
            ? root : root.appendingPathComponent(defaultNoteFolder, isDirectory: true)
        // `..` and absolute segments are dropped, not rejected: this string
        // comes from document text, so it is untrusted input, and a link must
        // never be able to write outside the vault.
        for part in subfolder.split(separator: "/")
        where part != "." && part != ".." && !part.isEmpty {
            dir.appendPathComponent(String(part), isDirectory: true)
        }
        // Path arithmetic alone is not containment: a SYMLINKED folder inside
        // the vault (common in Obsidian setups) would let
        // `withIntermediateDirectories` follow it and write outside the root.
        // Checked before the directory is created, on the deepest EXISTING
        // ancestor — `resolvingSymlinksInPath` cannot resolve components that
        // do not exist yet, and the link we are worried about does exist.
        guard Self.isContained(dir, in: root) else {
            throw LoreError.outsideVault(dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, slug: slug)
        // Re-checked after creation: now the whole chain exists, so this
        // resolves every component rather than only the pre-existing ones.
        guard Self.isContained(url.deletingLastPathComponent(), in: root) else {
            throw LoreError.outsideVault(url)
        }
        let now = Date()
        let note = Note(path: url, id: UUID().uuidString, title: title, tags: [],
                        created: now, updated: now, body: "")
        try Frontmatter.serialize(note).write(to: url, atomically: true, encoding: .utf8)
        try coordinator.indexDocument(MarkdownEngine.load(url), at: url)
        openMTimes[Self.pathKey(url)] = try mtime(of: url)
        return note
    }

    /// Writes `note` back to its file.
    ///
    /// Refuses when the file changed on disk since it was loaded, unless
    /// `overwritingExternalChanges` is set. `externalChangeDetected(for:)`
    /// already existed and was already correct — `save` simply never consulted
    /// it. So an edit made in Obsidian (or by the agent's `edit_file`, or by a
    /// sync client) while a note sat open in Lore's editor was destroyed by the
    /// editor's next 500ms autosave: silently, with no diff and no undo. That
    /// is a note-taking app losing notes.
    ///
    /// Detection is mtime-based and therefore best-effort — a write inside the
    /// filesystem's timestamp granularity can still slip through. A much
    /// smaller hole than not checking at all.
    public func save(_ note: Note, overwritingExternalChanges: Bool = false) throws {
        guard coordinator.hasIndex else { throw LoreError.noVault }
        if !overwritingExternalChanges, externalChangeDetected(for: note) {
            throw LoreError.externalChange(note.path)
        }
        var updated = note; updated.updated = Date()

        // Suppress the watcher across our own write. Saving fires
        // `FolderWatcher`, whose handler is a FULL `rebuild()` — re-reading and
        // re-indexing every markdown file in the vault, on the main actor, in
        // response to our own single-file write. On a large vault every
        // autosave stalled the editor mid-keystroke.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        try Frontmatter.serialize(updated).write(to: note.path, atomically: true, encoding: .utf8)
        try coordinator.indexDocument(MarkdownEngine.load(note.path), at: note.path)
        openMTimes[Self.pathKey(note.path)] = try mtime(of: note.path)
    }

    /// Drop a deleted document from the legacy note API's mtime map. Left
    /// behind, the entry is keyed by a path that no longer exists — harmless
    /// until a file reappears at that exact path, at which point `save`
    /// compares against a baseline from a different document.
    func forgetOpenMTime(_ url: URL) { openMTimes[Self.pathKey(url)] = nil }

    /// Follow a rename in the legacy note API's mtime map. Left stale, the
    /// entry is keyed by a path that no longer exists, so
    /// `externalChangeDetected(for:)` finds no baseline for the renamed note
    /// and returns false — turning `save`'s external-change guard off for it.
    /// Both keys go through `pathKey`, so the canonical URLs the rename paths
    /// pass in match a baseline stored from a raw `note.path`.
    func transferOpenMTime(from old: URL, to new: URL) {
        guard let known = openMTimes[Self.pathKey(old)] else { return }
        openMTimes[Self.pathKey(old)] = nil
        openMTimes[Self.pathKey(new)] = known
    }

    /// True if the file changed on disk since we last loaded/saved it.
    public func externalChangeDetected(for note: Note) -> Bool {
        guard let known = openMTimes[Self.pathKey(note.path)],
              let disk = try? mtime(of: note.path) else { return false }
        return disk > known
    }

    private func mtime(of url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
    }

    private func uniqueURL(in root: URL, slug: String) -> URL {
        var candidate = root.appendingPathComponent("\(slug).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug)-\(n).md"); n += 1
        }
        return candidate
    }
}
