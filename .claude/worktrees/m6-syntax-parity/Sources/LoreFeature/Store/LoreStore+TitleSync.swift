import Foundation

// Keeps a markdown document's frontmatter `title:` and its filename equal —
// the owner's ruling: "renaming either renames both."
//
// TWO ENTRY POINTS, DELIBERATELY DISJOINT, so a rename can never re-trigger
// itself:
//
//  * `commitTitleChange(for:to:)` — the TITLE field committed (blur/Enter/
//    tab-away, never per keystroke). Renames the FILE by routing through the
//    existing `plan(rename:to:)` / `apply(_:)` machinery in
//    `LoreStore+Rename.swift`, which already rewrites every inbound link and
//    already refuses a collision (see the exemption added there for a
//    case-only rename). It layers ONE extra, title-sync-specific legality
//    check (`titleLegalityRejection`, below) in front of that — deliberately
//    NOT folded into the shared `nameRejection`, which sidebar file rename
//    and folder rename also use: see that check's own doc comment.
//
//  * `syncTitleAfterFileRename(at:)` — the FILE was renamed by some other
//    means (sidebar "Rename…" today). Patches the frontmatter `title:` key
//    directly, on disk, and NEVER calls `plan(rename:)` / `apply(_:)` — it
//    cannot move a file, so it cannot re-enter the first entry point. No
//    shared mutable "in progress" flag is needed: the loop is broken by
//    construction, not by a guard that could be forgotten.
//
// Neither entry point calls the other. That is the whole loop-prevention
// strategy — see each function's own doc comment for how its half holds.
extension LoreStore {

    /// What `commitTitleChange` did, and what the caller should do about it.
    ///
    /// Not a plain `String?`: `apply(_:)` can populate `RenameReport.failed`
    /// (from an unrewritable inbound link, computed at PLAN time) and still
    /// perform the move — `failed.isEmpty` is not the same question as
    /// "did the rename happen". Collapsing both into one refusal string made
    /// the caller revert a title field for a file that had ALREADY been
    /// renamed, which is worse than either outcome alone (whole-branch
    /// review, Critical 3).
    public enum TitleCommitOutcome: Sendable, Equatable {
        /// Nothing needed to change, or the rename (if any) and the
        /// frontmatter write both succeeded.
        case success
        /// Refused before anything was written. The caller should revert the
        /// title field to its last committed value — the file was never
        /// touched.
        case refused(String)
        /// The FILE WAS RENAMED (or partially processed), but something
        /// afterward did not fully succeed — e.g. a plan-time unrewritable
        /// link, or the frontmatter write itself was refused (external
        /// change). The caller must NOT revert the title field: the file on
        /// disk already has the new name, and reverting the field would
        /// desynchronize it from a rename that already happened.
        case partial(String)
    }

    /// Called when the title field is COMMITTED (not on every keystroke —
    /// the caller, `MarkdownDocumentEditor`, only calls this on focus loss or
    /// `onSubmit`). `newTitle` is the field's current text; the caller is
    /// expected to have already set `engine.note.title = newTitle` as the
    /// user typed, exactly as it already does today. This function ALSO
    /// re-asserts that value immediately before persisting (see below) —
    /// callers must not rely on it surviving on its own.
    ///
    /// No-op (`.success`, nothing written) unless `newTitle` genuinely
    /// differs from `session.titleSinceLoad` — NEITHER the filename NOR
    /// `session.title` (`cachedTitle`), and the difference between those two
    /// matters:
    ///
    /// Comparing against the FILENAME was fix round 1's Critical 1: for a
    /// note whose title and filename ALREADY diverge (the owner's
    /// explicitly-uncovered case), `trimmed != currentFilename` is true even
    /// with no edit at all, so merely focusing and un-focusing the title
    /// field renamed the file and mass-rewrote every inbound link.
    ///
    /// Comparing against `session.title` (round 1's fix) was fix round 2's
    /// Critical A: `cachedTitle` is refreshed by every `write()`, and
    /// `write()` backs not just `saveNow()` but the 500ms-debounced autosave
    /// that fires after every keystroke via `markChanged()`. The dominant
    /// real gesture — type a new title, pause a beat, click away — lands
    /// that autosave BEFORE this function runs, so `trimmed == session.title`
    /// by the time the guard checks, and a GENUINE retitle was silently
    /// treated as a no-op: no rename, no link rewrite, no alert — while the
    /// autosave had already written the new title into the OLD filename,
    /// creating the exact divergence this feature exists to prevent, and no
    /// future commit of that same text could ever repair it (every later
    /// commit compares the same two now-equal strings).
    ///
    /// `session.titleSinceLoad` is unaffected by any `write()` — only by an
    /// actual load, reload, or a previous, successful sync commit (see
    /// `DocumentSession.noteTitleSynced`) — so it holds still through any
    /// number of autosaves and correctly distinguishes "the user edited the
    /// title since this file was last read" regardless of typing/pause
    /// timing.
    ///
    /// A read-only session (an engine that cannot round-trip its own bytes)
    /// refuses before touching anything — matching every other write path's
    /// treatment of `isReadOnly`.
    @discardableResult
    public func commitTitleChange(for session: DocumentSession, to newTitle: String) -> TitleCommitOutcome {
        guard !session.isReadOnly else {
            return .refused("This document is read-only, so its title cannot be changed.")
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != session.titleSinceLoad else { return .success }

        if let rejection = Self.titleLegalityRejection(trimmed, extension: session.url.pathExtension) {
            return .refused(rejection)
        }

        let plan = plan(rename: session.url, to: trimmed)
        if let refusal = plan.refusal { return .refused(refusal) }
        let report = apply(plan)

        // `movedTo` is the one honest signal for "did the file actually get
        // renamed" — `apply` populates `failed` from plan-time unrewritable
        // links BEFORE it moves anything, and then moves anyway, so a
        // non-empty `failed` does not mean the move was refused. Branching on
        // `report.failed.first` alone (as the first cut of this function did)
        // returned a refusal for a rename that had already happened, and the
        // caller reverted the title on a file that no longer had the old
        // name — whole-branch review, Critical 3.
        guard let moved = report.movedTo else {
            // Nothing moved: any `failed` entry here is a genuine, up-front
            // refusal (a collision, a vanished source, an unwritable folder).
            let reason = report.failed.first?.reason ?? "The rename could not be completed."
            return .refused(reason)
        }

        // The move happened. From here on we report at worst `.partial` —
        // never `.refused` — because reverting the title field now would
        // desynchronize it from the file that has already been renamed.
        var partialReason: String?
        if let failure = report.failed.first { partialReason = failure.reason }

        // Re-assert the title on the engine RIGHT BEFORE persisting, rather
        // than trusting the caller's earlier assignment to have survived.
        // `apply` → `rewriteInboundLinks` → `reloadRewritten` reloads this
        // very session when the plan includes a SELF-link (the note links to
        // itself), which copies the OLD on-disk title back into
        // `engine.note`. A `saveNow()` right after that would silently
        // persist the OLD title into the NEW filename — whole-branch review,
        // Critical 4. `LinkRewriterTests` and `M3AcceptanceTests` already
        // prove self-links are a real, exercised case for this vault, not a
        // hypothetical.
        if let markdown = session.engine as? MarkdownEngine {
            markdown.note.title = trimmed
        }
        // Advance the no-op baseline NOW, since the rename genuinely
        // happened regardless of what `saveNow()` below does — otherwise a
        // LATER, unrelated commit of this same text would be measured
        // against the session's ORIGINAL load and never treated as a no-op.
        session.noteTitleSynced(trimmed)

        // Persist now, on the commit, rather than waiting for the debounced
        // autosave — the owner's ruling is "one rename, one link rewrite, one
        // undo step per commit". The failure is SURFACED, not swallowed: a
        // `saveNow()` that throws (most commonly `LoreError.externalChange`,
        // if another editor touched the file between plan and commit) used
        // to be silenced by `try?`, so the rename and link rewrite would land
        // while the title itself silently never did — whole-branch review,
        // Important 5.
        do {
            try session.saveNow()
        } catch {
            return .partial(
                "“\(moved.lastPathComponent)” was renamed, but its title could not be saved: "
                + error.localizedDescription)
        }

        if let partialReason { return .partial(partialReason) }
        return .success
    }

    /// Title-sync-specific legality check, layered IN FRONT OF
    /// `plan(rename:to:)`'s own `nameRejection` — deliberately NOT merged
    /// into `nameRejection` itself.
    ///
    /// A first cut of this task added these same rules (colon, leading dot,
    /// control characters, length) directly to `nameRejection`, which is
    /// shared by EVERY rename surface — sidebar "Rename…" AND folder rename.
    /// That silently tightened both of those pre-existing features: a colon
    /// is legal in Finder and a real vault may already contain a folder
    /// named with one, so refusing it there was new, stricter behavior the
    /// owner never asked for (whole-branch review, Important 8, explicitly
    /// scoped this to the title-sync path only). This function is that scope
    /// boundary: only `commitTitleChange` calls it.
    ///
    /// `extensionLength` accounts for the extension `plan(rename:to:)` will
    /// re-append — capping only the basename at 255 UTF-8 bytes still lets a
    /// 253-byte basename plus ".md" overflow the real 255-byte filesystem
    /// limit, which then fails later, inside `apply`, AFTER the link rewrite
    /// has already run (whole-branch review, Minor 9).
    static func titleLegalityRejection(_ trimmed: String, extension ext: String) -> String? {
        guard !trimmed.contains(":") else {
            return "A title cannot contain a colon."
        }
        guard !trimmed.hasPrefix(".") else {
            return "A title cannot start with a dot."
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return "A title contains a character that is not allowed in a file name."
        }
        let extensionBytes = ext.isEmpty ? 0 : ext.utf8.count + 1 // the "." plus the extension itself
        guard trimmed.utf8.count + extensionBytes <= 255 else {
            return "That title is too long for a file name."
        }
        return nil
    }

    /// Called after a document was renamed by means OTHER than the title
    /// field (today: the sidebar "Rename…" action, once it calls this after
    /// a successful `apply`). Makes the frontmatter `title:` equal to the new
    /// filename, writing directly to `destination` — never through
    /// `plan(rename:)` — so this cannot itself trigger a second file move.
    ///
    /// Idempotent by construction: it re-derives what `Frontmatter.parse`
    /// would ALREADY produce for the (unchanged) file content at the new
    /// path, and writes only when that differs from the new basename. Calling
    /// it twice in a row, or on a file that already has the "right" title,
    /// is a no-op.
    ///
    /// DECISION on a note with no explicit `title:` key: this function ONLY
    /// touches a note that already has a frontmatter BLOCK
    /// (`note.rawFrontmatter != nil`). A note with no frontmatter at all —
    /// including one whose visible title is derived from an `# Heading` that
    /// no longer matches the filename — is left COMPLETELY untouched.
    ///
    /// This reverses the first cut of this function, which fabricated a full
    /// `id`/`title`/`tags`/`created`/`updated` block (via
    /// `Frontmatter.serializeFromModel`) onto such a note purely because it
    /// was renamed — stamping a synthesised UUID and today's date onto a file
    /// the user had deliberately kept free of frontmatter, and, worse, doing
    /// so WITHOUT actually fixing the visible divergence: the `# Heading`
    /// line (what a heading-derived title actually reads from) still shows
    /// the old name regardless of what frontmatter says, so the fabrication
    /// bought nothing (whole-branch review, Important 7). Editing the BODY
    /// heading itself would be a real content mutation of exactly the kind
    /// this task's brief rules out ("nothing may alter saved document
    /// content... beyond the deliberate frontmatter title change"), so a
    /// heading-derived note's divergence is left for the user to resolve by
    /// actually editing the title field (which routes through
    /// `commitTitleChange` and writes frontmatter deliberately, as a
    /// consequence of a real edit) — consistent with "leave divergence alone
    /// until the user edits one side or the other".
    ///
    /// Deliberately does NOT touch an already-divergent note that has not
    /// been renamed: this function is only ever called as the direct result
    /// of a rename, which the owner's ruling treats as the "edit" that
    /// starts the sync for THAT file's frontmatter `title:` key — vault-wide
    /// reconciliation of pre-existing divergence is explicitly out of scope
    /// and must not happen as a side effect of opening, indexing or scanning
    /// a note.
    public func syncTitleAfterFileRename(at destination: URL) {
        guard MarkdownEngine.canOpen(destination) else { return }
        guard let text = try? String(contentsOf: destination, encoding: .utf8) else { return }
        var note = Frontmatter.parse(text, path: destination)
        // No frontmatter block at all: nothing is invented. See the DECISION
        // in this function's doc comment.
        guard note.rawFrontmatter != nil else { return }
        let newBase = destination.deletingPathExtension().lastPathComponent
        guard note.title != newBase else { return }
        note.title = newBase
        let newText = Frontmatter.serialize(note)
        guard newText != text else { return }

        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        guard (try? newText.write(to: destination, atomically: true, encoding: .utf8)) != nil
        else { return }

        // The file is truth, the index is derived: reindex this one file
        // rather than trusting the watcher (suppressed above) or waiting for
        // the next full rescan to notice the title changed.
        if let engine = try? EngineRegistry.load(destination) {
            try? coordinator.indexDocument(engine, at: destination)
        }
        // An open, CLEAN session on this file would otherwise keep showing
        // the pre-sync title until its next reload. A dirty one CANNOT be
        // reloaded — that would discard unsaved text, the same rule
        // `reloadRewritten` in `LoreStore+Rename.swift` already follows —
        // but leaving it fully alone has a real failure mode (whole-branch
        // review, fix round 2, Minor C): the file on disk now has the
        // synced title, yet the dirty session's `engine.note.title` still
        // holds the STALE one, and its eventual autosave/`saveNow()` would
        // serialize that stale title straight back over the sync just
        // performed, re-diverging the file. Patching ONLY the in-memory
        // title (never the body, never saving) closes that gap safely: it
        // does not touch the user's unsaved text, so no data is lost, and
        // it means whatever save eventually happens carries the corrected
        // title instead of the stale one.
        if let session = tabs.first(where: { LoreStore.pathKey($0.url) == LoreStore.pathKey(destination) }) {
            if session.isDirty {
                (session.engine as? MarkdownEngine)?.note.title = newBase
            } else {
                try? session.resolveByReloading()
            }
        }
    }
}
