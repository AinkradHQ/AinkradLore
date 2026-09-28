import Foundation
import AinkradAppKit

/// The sink behind Lore's MCP tools: decodes one `{"operation": ..., ...}`
/// payload and drives the `LoreStore` that the on-screen instance is using.
///
/// Deliberately the SAME store the UI holds (see `LoreApp.mcpServer(for:)`), so
/// a note the assistant writes appears in the sidebar immediately and the
/// external-change bookkeeping is shared rather than duplicated.
///
/// ## Why this does not go through `LoreStore.load`
///
/// `load(_:)` is the app's read API, but it has a WRITE side effect: it records
/// the file's modification date in `openMTimes`, which is the baseline
/// `externalChangeDetected(for:)` compares against. Calling it from here would
/// tell the store "the newest on-disk version has been seen" on behalf of an
/// editor that has not seen it — so an agent read of a note that is open in
/// Lore's editor with a stale buffer would silently disarm the guard that stops
/// the editor's next autosave destroying an outside edit. That is precisely the
/// note-losing bug `save(_:overwritingExternalChanges:)` exists to prevent, and
/// re-introducing it through a tool advertised as `readOnly` would be worse than
/// the original.
///
/// So both `read` and `save` parse the file with `Frontmatter.parse` directly.
/// They observe the mtime bookkeeping; they never move it.
@MainActor
struct LoreNoteOperations {
    let store: LoreStore

    /// What every tool says when Lore has no vault yet.
    ///
    /// This is the fresh-install state — `LoreStore.init` only activates a
    /// vault if a security-scoped bookmark resolves — and the assistant WILL
    /// hit it. Choosing a folder requires a real file-picker grant, so no tool
    /// can fix it; the only useful answer is to say plainly what is missing and
    /// who can supply it. Every operation checks this before touching anything,
    /// rather than each one failing differently: without a vault, `search`
    /// silently returns nothing, `create`/`save`/`delete` throw
    /// `LoreError.noVault`, and `allTags`/`subfolders` return empty arrays —
    /// three different confusing answers to one question.
    static let noVaultMessage =
        "Lore has no vault configured, so there are no notes to work with. "
        + "Open the Lore app and choose a vault folder in its settings "
        + "(this needs a folder-picker grant, so it cannot be done from here)."

    /// Backs the `lore://vault` resource: where the vault is and how big it is,
    /// or the same actionable not-configured message the tools give.
    func vaultSummary() -> String {
        guard let root = store.vaultRoot else { return Self.noVaultMessage }
        return """
            vault: \(root.path)
            notes: \(noteRows.count)
            tags: \(store.allTags.count)
            new notes are created in: \(store.defaultNoteFolder.isEmpty ? "(the vault root)" : store.defaultNoteFolder)
            """
    }

    /// `store.rows` is every indexed document — plaintext and other
    /// non-markdown files included, since Task 5 generalized the index beyond
    /// notes. The MCP tools are all named and documented as operating on
    /// NOTES, so every listing/search/resolution path filters down to this
    /// before the caller ever sees a row. Skipping the filter anywhere here
    /// would mean a `*_note` tool silently returning (or resolving an id to) a
    /// `.swift` or `.log` file — the tool lying about its own contract.
    private var noteRows: [IndexRow] {
        store.rows.filter { $0.type == MarkdownEngine.identifier }
    }

    func run(_ json: String) async -> AgentActionResult {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let operation = object["operation"] as? String else {
            return .failure("Lore: malformed request")
        }
        guard store.vaultRoot != nil else { return .failure(Self.noVaultMessage) }

        do {
            switch operation {
            case "search":     return searchNotes(object)
            case "read":       return try readNote(object)
            case "listTags":   return listTags()
            case "listFolders": return listFolders()
            case "create":     return try createNote(object)
            case "save":       return try saveNote(object)
            case "delete":     return try deleteNote(object)
            default:           return .failure("Lore: unknown operation \"\(operation)\"")
            }
        } catch let error as LoreError {
            return .failure(describe(error))
        } catch let OperationError.message(text) {
            return .failure(text)
        } catch {
            return .failure("Lore: \(error.localizedDescription)")
        }
    }

    // MARK: - read

    private func searchNotes(_ object: [String: Any]) -> AgentActionResult {
        let query = (object["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, (object["limit"] as? Int) ?? 25)
        // An empty query is a browse, not a search: the FTS index has nothing
        // to match on, so answer from the already-loaded rows, newest first.
        let rows = query.isEmpty
            ? noteRows.sorted { $0.updated > $1.updated }
            : store.search(query).filter { $0.type == MarkdownEngine.identifier }
        guard !rows.isEmpty else {
            return .success(query.isEmpty ? "The vault has no notes yet." : "No notes match \"\(query)\".")
        }
        let listed = rows.prefix(limit).map(describe(row:))
        let more = rows.count > limit ? "\n(\(rows.count - limit) more not shown)" : ""
        return .success(listed.joined(separator: "\n") + more)
    }

    private func readNote(_ object: [String: Any]) throws -> AgentActionResult {
        let row = try resolve(object)
        let note = try parse(row)
        let tags = note.tags.isEmpty ? "(none)" : note.tags.joined(separator: ", ")
        return .success("""
            id: \(note.id)
            title: \(note.title)
            tags: \(tags)
            path: \(relative(note.path))

            \(note.body)
            """)
    }

    private func listTags() -> AgentActionResult {
        // `store.allTags` walks every indexed row, not just notes. Plaintext
        // rows carry no tags today, but computing this from `noteRows`
        // rather than `store.allTags` keeps the guarantee true by
        // construction instead of by accident of what plaintext happens not
        // to populate.
        let tags = Array(Set(noteRows.flatMap(\.tags))).sorted()
        return .success(tags.isEmpty ? "The vault has no tags." : tags.joined(separator: "\n"))
    }

    private func listFolders() -> AgentActionResult {
        let folders = store.subfolders
        return .success(folders.isEmpty
            ? "The vault root has no subfolders."
            : folders.joined(separator: "\n"))
    }

    // MARK: - write

    private func createNote(_ object: [String: Any]) throws -> AgentActionResult {
        guard let title = object["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("create_note requires a non-empty \"title\".")
        }
        if let rejection = filenameRejection(for: title) { return .failure(rejection) }
        var note = try store.create(title: title)
        // `create` writes an empty note, so fold any body/tags in with one
        // follow-up save rather than making the model call save_note itself.
        // No external change is possible in between: `create` just wrote the
        // file and recorded its mtime.
        if let body = object["body"] as? String { note.body = body }
        if let tags = stringList(object["tags"]) { note.tags = tags }
        if object["body"] != nil || object["tags"] != nil { try store.save(note) }
        return .success("Created \"\(note.title)\" (id \(note.id)) at \(relative(note.path)).")
    }

    private func saveNote(_ object: [String: Any]) throws -> AgentActionResult {
        let row = try resolve(object)
        // PATCH, not replace. Start from what is on disk right now and apply
        // only the fields the caller actually sent, so a call that means "add a
        // tag" cannot blank a body the model never saw. Parsed directly rather
        // than via `store.load` — see this type's doc comment.
        var note = try parse(row)
        if let title = object["title"] as? String { note.title = title }
        if let body = object["body"] as? String { note.body = body }
        if let tags = stringList(object["tags"]) { note.tags = tags }

        // THE SINK the `save_note` / `save_note_overwriting` guard mirrors.
        // `as? Bool` here is the exact coercion `LoreMCPServer`'s
        // `GuardRule("overwritingExternalChanges", .bool(true))` assumes. If
        // this line is ever loosened — a string parse, a "yes" alias — that
        // rule must widen in the same commit, or `save_note` becomes an ungated
        // overwrite of edits made outside Ainkrad.
        let overwriting = (object["overwritingExternalChanges"] as? Bool) ?? false
        try store.save(note, overwritingExternalChanges: overwriting)
        return .success("Saved \"\(note.title)\" (id \(note.id)).")
    }

    private func deleteNote(_ object: [String: Any]) throws -> AgentActionResult {
        let row = try resolve(object)
        // `store.trash` and not the old `store.delete`: this path closed no tab
        // and cancelled no pending save, so `delete_note` could permanently
        // unlink a file AND have the open tab's debounced autosave recreate it
        // 500ms later. `trash` owns all of that, and moves the file to the
        // Trash instead of unlinking it. It can also REFUSE (a tab with
        // unsaved edits that cannot be flushed) where `delete` never did; that
        // arrives here as a `LoreError`, which `run`'s existing catch turns
        // into the same `isError` result shape every other failure uses.
        let inbound = try store.trash(row)
        let warning = inbound == 0 ? "" :
            " \(inbound) note\(inbound == 1 ? "" : "s") still link\(inbound == 1 ? "s" : "") "
            + "to it; those links are now unresolved."
        return .success("Moved \"\(row.title)\" (\(relative(row.path))) to the Trash.\(warning)")
    }

    // MARK: - helpers

    /// The filename slug `LoreStore.create` will derive from `title`.
    ///
    /// Duplicated from the store on purpose: this check must know the exact
    /// path the store is ABOUT to write, and it must run BEFORE the write —
    /// checking afterwards would mean the escape already happened. Kept next to
    /// the boundary rather than changing `create`'s behaviour for the app's own
    /// UI, where the title comes from the person at the keyboard. If the
    /// store's slug rule ever changes, this must change with it.
    private static func slug(for title: String) -> String {
        title.isEmpty ? "untitled" : title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Nil when `title` yields a filename that lands inside the vault; an
    /// actionable message otherwise.
    ///
    /// The MCP layer is a new trust boundary: a title here can come from a
    /// model that read untrusted content, and `create_note` is ungated
    /// (`destructive: false`). Unsanitised, `../../escape` would resolve
    /// outside the vault root, making the tool a primitive for writing an
    /// attacker-chosen file at an attacker-chosen path — and a note written
    /// outside the vault is also indexed and then vanishes on the next
    /// `rebuild()` (which scans only the vault), leaving the assistant holding
    /// an id that no longer resolves.
    ///
    /// The check is on the OUTCOME, not on a character blocklist: build the URL
    /// the store would build, standardize it (which collapses `..` lexically),
    /// and require that it sits DIRECTLY in the intended note folder — the
    /// parent must be the folder itself, so `a/b` (still inside the vault, but
    /// not where the caller was told the note goes) is rejected too. Rejecting
    /// rather than silently mangling, so the model can retry with a sane title.
    private func filenameRejection(for title: String) -> String? {
        guard let root = store.vaultRoot else { return nil }  // `run` already refused.
        let dir = store.defaultNoteFolder.isEmpty
            ? root : root.appendingPathComponent(store.defaultNoteFolder, isDirectory: true)
        let slug = Self.slug(for: title)
        // A leading dot is rejected up front: `.hidden` stays inside the vault,
        // so the containment check cannot catch it, but it writes a file the
        // user cannot see in Finder and that Obsidian ignores.
        guard !slug.hasPrefix(".") else {
            return "create_note refused the title \"\(title)\": a note name cannot start with "
                + "a dot. Retry with a plain title."
        }
        // `.standardizedFileURL` collapses `..` lexically — that is what makes
        // this an outcome check rather than a blocklist — but it must NOT be the
        // thing the two sides are compared through. `stringByStandardizingPath`
        // strips a leading `/private` only when the shortened path can be
        // verified to resolve, i.e. only when it EXISTS: `dir` (a live vault
        // folder) is stripped while `candidate` (a note that does not exist yet)
        // is not, so with a canonical `vaultRoot` the two sides disagree about
        // `/private` and every ordinary title was refused as "outside the
        // vault". Both sides therefore go through `canonical`, the one
        // resolution this codebase uses. The candidate's PARENT is what is
        // canonicalized, because `realpath(3)` fails on a file that does not
        // exist yet — the parent always does.
        let candidate = dir.appendingPathComponent("\(slug).md").standardizedFileURL
        let folder = VaultIndexCoordinator.canonical(dir).path
        let parent = VaultIndexCoordinator.canonical(candidate.deletingLastPathComponent()).path
        guard parent == folder, candidate.lastPathComponent == "\(slug).md" else {
            return "create_note refused the title \"\(title)\": it would write outside the "
                + "vault's note folder. Retry with a title that has no slashes or \"..\" "
                + "path components."
        }
        return nil
    }

    /// Resolves the `note` argument to an indexed row. Accepts the frontmatter
    /// id (what `search_notes` reports) or an absolute file path, because the
    /// assistant frequently already holds a path from the filesystem tools.
    private func resolve(_ object: [String: Any]) throws -> IndexRow {
        guard let identifier = object["note"] as? String, !identifier.isEmpty else {
            throw OperationError.message("This tool requires a \"note\" (an id or an absolute path).")
        }
        // Resolution is scoped to `noteRows` too: a `.swift` file that happens
        // to share an id or path with what the caller passed must not resolve
        // at all, let alone become something `read_note`/`save_note`/
        // `delete_note` then treats as a note.
        if let row = noteRows.first(where: { $0.id == identifier }) { return row }
        // Canonicalized on both sides: row paths are canonical by invariant
        // (see `LoreIndex.canonical(_:)`), while the assistant hands us whatever
        // spelling its filesystem tools produced — commonly `/tmp/...` or
        // `/var/...`. Compared raw, a correct absolute path for an existing note
        // failed to resolve.
        let wanted = VaultIndexCoordinator.canonical(URL(fileURLWithPath: identifier)).path
        if let row = noteRows.first(where: { $0.path.path == wanted }) { return row }
        throw OperationError.message(
            "No note in the vault has id or path \"\(identifier)\". "
            + "Use search_notes to find the note's id.")
    }

    private func parse(_ row: IndexRow) throws -> Note {
        let text = try String(contentsOf: row.path, encoding: .utf8)
        return Frontmatter.parse(text, path: row.path)
    }

    /// Only accepts a genuine array of strings. A bare string is NOT coerced to
    /// a one-element list: `tags: "a, b"` almost certainly means two tags, and
    /// guessing which would silently mangle the note's metadata.
    private func stringList(_ any: Any?) -> [String]? {
        guard let array = any as? [Any] else { return nil }
        return array.compactMap { $0 as? String }
    }

    private func describe(row: IndexRow) -> String {
        let tags = row.tags.isEmpty ? "" : "  [\(row.tags.joined(separator: ", "))]"
        return "\(row.id)  \(row.title)\(tags)  —  \(relative(row.path))"
    }

    /// Vault-relative where possible: an absolute path leaks the user's home
    /// directory into the transcript for no benefit.
    private func relative(_ url: URL) -> String {
        // NOT `.standardizedFileURL` on either side: it strips `/private` from
        // an existing path only, so a canonical `vaultRoot` was shortened while
        // `url` was not, the prefix test failed, and every path the agent saw
        // became absolute — leaking the user's home directory, which is the one
        // thing this function exists to avoid.
        guard let root = store.vaultRoot.map({ VaultIndexCoordinator.canonical($0).path })
        else { return url.path }
        let path = VaultIndexCoordinator.canonical(url).path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private func describe(_ error: LoreError) -> String {
        switch error {
        case .noVault:
            return Self.noVaultMessage
        case .externalChange(let url):
            // The one error whose recovery is a DIFFERENT tool, so name it.
            return "\(relative(url)) was changed outside Ainkrad since Lore last read it. "
                + "Saving now would discard those changes. Use read_note to see the current "
                + "contents and re-apply your edit, or call save_note_overwriting to discard "
                + "them deliberately (that needs approval and cannot be undone)."
        case .trashFailed(let url, let reason):
            return "Could not move \(relative(url)) to the Trash: \(reason)"
        case .unsavedEdits(let url, let reason):
            return "Lore declined to delete \(relative(url)): \(reason)"
        case .outsideVault(let url):
            return "Lore declined to write \(relative(url)) because it is outside the vault."
        case .invalidName(let name):
            return "“\(name)” is not a valid folder name."
        case .alreadyExists(let url):
            return "\(relative(url)) already exists."
        case .notARegularFile(let url):
            return "\(relative(url)) is not a regular file, so it was not copied as an "
                + "attachment."
        // Both restore failures are raised only by `undoTrash()`, which is a UI
        // affordance (the action on a delete's toast) with no MCP tool behind
        // it. Spelled out rather than folded into a `default` so that adding a
        // future error still breaks this switch, which is how every case above
        // came to have a sentence written for it.
        case .restoreBlocked(let url):
            return "\(relative(url)) could not be restored because a file of that name "
                + "exists again."
        case .restoreFailed(let url, let reason):
            return "\(relative(url)) could not be restored from the Trash: \(reason)"
        }
    }

    /// A message-only failure for argument problems, so `run`'s single catch
    /// can format everything.
    private enum OperationError: Error {
        case message(String)
    }
}

private extension AgentActionResult {
    static func success(_ text: String) -> AgentActionResult { .init(text: text, isError: false) }
    static func failure(_ text: String) -> AgentActionResult { .init(text: text, isError: true) }
}
