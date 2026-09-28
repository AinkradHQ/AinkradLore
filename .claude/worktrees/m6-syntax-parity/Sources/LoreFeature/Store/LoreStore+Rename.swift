import Foundation

// Renaming and moving a document: the first operation in Lore that writes to
// files the user never opened. Four properties are load-bearing, in order:
//
//  1. ORDERING. Inbound links are rewritten BEFORE the file moves.
//
//     Not because a crash in the middle leaves a better graph — it does not.
//     Half-rewritten links point at a name that does not exist yet, and they
//     are broken until the move happens. The real justification is RECOVERY:
//     the file move is a single atomic `moveItem`, so putting it LAST means the
//     only step that can leave the vault in a state no re-run can describe is
//     also the last thing that can fail. Every earlier step is idempotent —
//     re-running the same rename rewrites already-rewritten links to the same
//     text (no edit is produced when the target is already correct) and then
//     performs the move. So the recovery for a crash at any point is: run it
//     again.
//
//     The realistic failures — the destination already exists, the name is
//     invalid, the source is gone, the destination folder is missing or not
//     writable — are caught by the pre-flight guards at the top of `apply`,
//     before the first link is written at all.
//  2. NEVER OVERWRITE AN EXTERNAL EDIT. Every file is checked against the
//     mtime captured at PLAN time; one that moved is skipped and reported.
//     With Obsidian open on the same vault this is not hypothetical.
//  3. OPEN TABS. A session holding pre-rewrite content would clobber the
//     rewrite on its next autosave, so pending saves are disarmed first and
//     the sessions reloaded after.
//  4. VALIDATE THE NAME AT THE BOUNDARY. `newName` is a basename, never a
//     path: see `nameRejection`.
//
// `rewriteInboundLinks` below is the SINGLE link-rewriting write path, shared
// by single-document rename/move (`apply(_ plan:)`, here) and folder rename
// (`apply(_ plan: FolderRenamePlan)`, in `LoreStore+FolderRename.swift`).
// There is deliberately no second, folder-shaped implementation of properties
// 1–3: a bulk operation is the LAST place to re-derive them.
//
// It lives in its own file because `LoreStore.swift` is near the 500-line
// project ceiling.
extension LoreStore {

    // MARK: - Planning

    /// Computes the change set for renaming `source` to `newName` (a basename,
    /// no extension). Nothing is written.
    public func plan(rename source: URL, to newName: String) -> RenamePlan {
        let canonicalSource = VaultIndexCoordinator.canonical(source)
        let parent = canonicalSource.deletingLastPathComponent()
        if let refusal = nameRejection(newName, in: parent) {
            return RenamePlan(source: canonicalSource, destination: canonicalSource,
                              edits: [], refusal: refusal)
        }
        let destination = parent
            .appendingPathComponent(newName)
            .appendingPathExtension(source.pathExtension)
        return planMove(canonicalSource, to: destination)
    }

    /// Moving is renaming without the name change: it must still rewrite,
    /// because a move changes how an explicit-path link resolves.
    public func plan(move source: URL, toFolder folder: URL) -> RenamePlan {
        planMove(source, to: folder.appendingPathComponent(source.lastPathComponent))
    }

    /// Rejects a `newName` that is not a NAME. Nil means acceptable.
    ///
    /// `newName` reaches this from a text field, and (once Task 10 wires the
    /// UI) potentially from anywhere a name can be pasted. Unvalidated,
    /// `"../X"` builds a destination outside `parent`, and because a folder
    /// rename's destination tree may not exist yet, a
    /// `createDirectory(withIntermediateDirectories: true)` anywhere on the
    /// path would MATERIALIZE that escape where a bare `moveItem` would simply
    /// have failed. The document then moves out of the vault, its inbound
    /// links become unrewritable — and the move still happens.
    ///
    /// Checked syntactically AND on the outcome: the syntactic rules give a
    /// message that names what was wrong, and the containment check is the
    /// backstop for anything they miss. Refused, never mangled into something
    /// "safe" — silently renaming to a different name than the user typed is
    /// its own surprise.
    func nameRejection(_ newName: String, in parent: URL) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "A new name cannot be empty."
        }
        guard !newName.contains("/"), !newName.contains("\\") else {
            return "“\(newName)” is not a name: it contains a path separator."
        }
        guard trimmed != ".", trimmed != ".." else {
            return "“\(newName)” is a relative path component, not a name."
        }
        // Deliberately NOT the home of colon/leading-dot/control-char/length
        // legality rules: those were added here in a first cut of title/
        // filename sync and then reverted (whole-branch review, Important 8)
        // because this function is shared by EVERY rename surface — sidebar
        // file rename AND folder rename — and tightening it here silently
        // tightened both, including refusing a colon that is legal in Finder
        // and may already exist in a real vault's folder names. Title-sync's
        // OWN stricter legality check lives in `LoreStore+TitleSync.swift`
        // (`titleLegalityRejection`), applied ONLY on the title-field commit
        // path, so sidebar rename and folder rename keep their pre-existing,
        // looser behavior unchanged.
        // Containment. Only meaningful once a vault is active; without one
        // there is no root to be inside of and the syntactic rules above are
        // all we can honestly enforce.
        guard let root = vaultRoot else { return nil }
        let rootComponents = VaultIndexCoordinator.canonical(root).pathComponents
        let destination = Self.canonicalizingDestination(
            parent.appendingPathComponent(newName).standardizedFileURL)
        let components = destination.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return "“\(newName)” would move it outside the vault."
        }
        return nil
    }

    /// How many documents currently link to `url` — used by the Trash flow to
    /// warn the caller before deleting.
    public func inboundLinkCount(to url: URL) -> Int {
        coordinator.inboundLinks(to: VaultIndexCoordinator.canonical(url)).count
    }

    /// The single place source, destination and vault root are canonicalized.
    ///
    /// `LinkRewriter` computes a vault-relative target by comparing path
    /// COMPONENTS against `vaultRoot`. If the two sides come from different
    /// resolutions — `FileManager`'s enumerator yields `/private/tmp/...`
    /// while a caller-built URL stays `/tmp/...` — the prefix match fails,
    /// `rewritten` returns nil, and every edit is silently dropped: a plan
    /// with zero edits, a rename that looks clean, and every inbound link
    /// quietly broken. Task 6's review found exactly this. Sourcing all three
    /// through `VaultIndexCoordinator.canonical` is what prevents it.
    func planMove(_ source: URL, to destination: URL) -> RenamePlan {
        let canonicalSource = VaultIndexCoordinator.canonical(source)
        let canonicalDestination = Self.canonicalizingDestination(destination)
        let root = canonicalVaultRoot(fallback: canonicalSource.deletingLastPathComponent())

        let inbound = coordinator.inboundLinks(to: canonicalSource)
        let plan = LinkRewriter.plan(renaming: canonicalSource,
                                     to: canonicalDestination,
                                     inboundLinks: inbound,
                                     vaultRoot: root)
        // Baselines are read HERE, not in `apply`. Reading them inside `apply`
        // (microseconds before comparing them) makes the external-change guard
        // tautological: it can never fire, and requirement 2 silently
        // evaporates while the code still looks like it enforces it.
        return plan.withBaselines(Self.baselines(for: plan.affectedFiles))
    }

    func canonicalVaultRoot(fallback: URL) -> URL {
        VaultIndexCoordinator.canonical(vaultRoot ?? fallback)
    }

    /// THE key for every path-keyed dictionary and set in the rename paths.
    ///
    /// Nothing may key off a raw `url.path`. Since Task 8b, **every path stored
    /// in the index is canonical** — the invariant is enforced at the store
    /// boundary (`LoreIndex.canonical(_:)`, applied in `LoreIndex.write`) and
    /// upstream in `activate`, `scanVault` and `indexDocument`, so index rows,
    /// `vaultRoot`, session URLs, plan sources and plan destinations now all
    /// carry ONE spelling. Read that doc comment for the mechanism
    /// (`/tmp` vs `/private/tmp`) and the three silent M1 failures it caused.
    ///
    /// This function therefore is no longer load-bearing for anything the store
    /// writes — it is deliberate belt-and-braces for what a CALLER can
    /// construct. `RenamePlan` and `LinkEdit` are public, so Task 10's preview
    /// UI can hand `apply` an edit file spelled however it likes; keyed raw, a
    /// set membership test then misses and the consequence is silent (an edit
    /// dropped from the plan, a dirty tab's file written anyway) because a
    /// missing key looks exactly like "nothing to do". Routing both sides of
    /// every comparison through one function keeps that unrepresentable at the
    /// boundary the invariant does not reach.
    /// Covered by `LinkRewriterTests.test_dirtyTabBlocksTheRewriteEvenWhenTheIndexSpellsTheFileDifferently`.
    static func pathKey(_ url: URL) -> String {
        VaultIndexCoordinator.canonical(url).path
    }

    /// Plan-time mtimes for every file an operation will write. Shared by
    /// single-document and folder planning so both get requirement 2.
    static func baselines(for files: [URL]) -> [String: Date] {
        var baselines: [String: Date] = [:]
        for file in files { baselines[pathKey(file)] = mtimeOnDisk(file) }
        return baselines
    }

    /// `realpath(3)` fails on a path that does not exist yet — and a rename
    /// destination never exists yet. A folder rename compounds this: the
    /// destination's PARENT directory does not exist yet either (that
    /// directory is exactly what "rename the folder" creates), so
    /// canonicalizing only the immediate parent still fails and hands back
    /// an unresolved path. That unresolved path's root prefix (`/var/...`)
    /// then fails to match the already-canonical vault root (`/private/var
    /// /...`) inside `LinkRewriter.vaultRelativePath`, and every explicit-path
    /// or explicit-extension inbound link for that document is dropped as
    /// "outside the vault" — silently, since a caller sees an empty edit
    /// list rather than an error. So this walks UP to the nearest ancestor
    /// that actually exists, canonicalizes only that, and re-appends every
    /// component below it — however many levels of not-yet-created
    /// directory that is.
    static func canonicalizingDestination(_ destination: URL) -> URL {
        var existingAncestor = destination.deletingLastPathComponent()
        var trailingComponents: [String] = [destination.lastPathComponent]
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.pathComponents.count > 1 {
            trailingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        return trailingComponents.reduce(VaultIndexCoordinator.canonical(existingAncestor)) {
            $0.appendingPathComponent($1)
        }
    }

    static func mtimeOnDisk(_ url: URL) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// True when `a` and `b` name the SAME on-disk file — by inode and
    /// device number, not by comparing path text. This is the ONLY reliable
    /// way to tell "a case-only rename target, same file" apart from "a
    /// different file whose name happens to collide case-insensitively":
    /// see the caller's doc comment (Minor E). `false` whenever either
    /// attribute read fails (including "`b` does not exist yet", the common
    /// case for an ordinary, non-colliding rename) — failing closed here
    /// means an unreadable attribute is treated as "not proven the same
    /// file", never as "assume it's fine, skip the collision guard".
    static func sameFileOnDisk(_ a: URL, _ b: URL) -> Bool {
        guard let attrsA = try? FileManager.default.attributesOfItem(atPath: a.path),
              let attrsB = try? FileManager.default.attributesOfItem(atPath: b.path),
              let inodeA = attrsA[.systemFileNumber] as? Int,
              let inodeB = attrsB[.systemFileNumber] as? Int,
              let deviceA = attrsA[.systemNumber] as? Int,
              let deviceB = attrsB[.systemNumber] as? Int
        else { return false }
        return inodeA == inodeB && deviceA == deviceB
    }

    // MARK: - The shared link-rewriting pass

    /// Everything one rewrite pass produced. Carries session bookkeeping as
    /// well as the report fields, because the reload decision (below) is keyed
    /// off session IDENTITY paired with each session's PRE-MOVE path, and only
    /// the pass knows both.
    struct LinkRewritePass {
        var rewritten: [URL] = []
        var skipped: [SkippedFile] = []
        var unchanged: [URL] = []
        var failed: [(url: URL, reason: String)] = []
        /// Sessions on a file that is about to move, with its pre-move path.
        var movingSessions: [(session: DocumentSession, path: String)] = []
        /// Every session touched, with its pre-move path.
        var affected: [(session: DocumentSession, path: String)] = []
        /// Paths actually WRITTEN, so only those sessions are reloaded.
        var writtenPaths: Set<String> = []
    }

    /// Prepares every open session and then rewrites inbound links — the one
    /// implementation of load-bearing properties 2 and 3, used by both
    /// single-document rename and folder rename.
    ///
    /// `movingPaths` are the canonical pre-move paths of files the caller is
    /// about to relocate; a session on one of them is flushed and disarmed even
    /// when no link in it needs rewriting.
    ///
    /// Does NOT move anything and does NOT reload anything: the caller performs
    /// its move (links first, always) and then calls `reloadRewritten`.
    func rewriteInboundLinks(edits: [LinkEdit],
                             baselines: [String: Date],
                             movingPaths: Set<String>) -> LinkRewritePass {
        var pass = LinkRewritePass()
        var baselines = baselines
        // Keyed by `pathKey`, NOT by `edit.file.path`. Index-sourced edits are
        // canonical by invariant since Task 8b, but `LinkEdit` is public and a
        // caller-built plan can spell its edit file any way it likes. Keyed raw,
        // such an edit never matches its own open tab, so `blockedByUnsavedEdits`
        // below never fires and the exclude-dirty-tabs protection quietly does
        // nothing.
        let editedByFile = Dictionary(grouping: edits, by: { Self.pathKey($0.file) })

        // Disarm every debounced autosave that could land on top of a rewrite,
        // INCLUDING a moving document's own. A session holding unsaved text is
        // flushed first so its edits are on disk before we touch the file —
        // cancelling alone would leave them to be overwritten by the rewrite
        // and then erased by the reload. Because that flush is OUR write, the
        // baseline is refreshed with it: it is not an external change.
        //
        // Session identity is paired with the path held BEFORE the move. Every
        // later decision (reload, skip) keys off this, never off `session.url`:
        // `adoptRenamed` repoints that URL, so a self-linking document — both
        // a move source AND a rewrite target — would never match its own
        // pre-move path afterwards, keep pre-rewrite text, and revert its own
        // self-link to the old, now-dangling name on the next save.
        //
        // Files a tab still holds unsaved edits to are NOT written at all.
        var blockedByUnsavedEdits: Set<String> = []
        for session in tabs {
            let path = Self.pathKey(session.url)
            let isMoving = movingPaths.contains(path)
            let isEdited = editedByFile[path] != nil
            if isMoving { pass.movingSessions.append((session, path)) }
            guard isEdited || isMoving else { continue }
            pass.affected.append((session, path))
            if session.isDirty && !session.isReadOnly {
                if (try? session.saveNow()) != nil, baselines[path] != nil {
                    baselines[path] = Self.mtimeOnDisk(session.url)
                }
            }
            session.cancelPendingSave()
            // The flush can REFUSE: a session that was already `conflict` when
            // the plan was computed re-throws `externalChange` and stays dirty.
            // The plan-time baseline was captured AFTER that external edit, so
            // the mtime guard would happily write the file, and the reload
            // below would then replace the engine's contents — destroying the
            // user's unsaved text with no dialog and no report entry. So a
            // still-dirty session takes its file out of the rewrite set
            // entirely: nothing is written, nothing is reloaded, and the
            // session keeps its `isDirty`/`conflict` for the user to resolve.
            if isEdited && session.isDirty { blockedByUnsavedEdits.insert(path) }
        }

        for (path, fileEdits) in editedByFile {
            let file = fileEdits[0].file
            guard !blockedByUnsavedEdits.contains(path) else {
                pass.skipped.append(SkippedFile(url: file, reason: .unsavedEdits))
                continue
            }
            do {
                switch try LinkRewriter.applyEdits(fileEdits, to: file,
                                                   baseline: baselines[path]) {
                case .written:   pass.rewritten.append(file); pass.writtenPaths.insert(path)
                case .unchanged: pass.unchanged.append(file)
                case .skipped(let reason):
                    pass.skipped.append(SkippedFile(url: file, reason: reason))
                }
            } catch {
                pass.failed.append((file, error.localizedDescription))
            }
        }
        return pass
    }

    /// Reloads sessions whose file we actually WROTE, so the editor does not
    /// keep showing pre-rewrite text and then save it back.
    /// `resolveByReloading` bumps `reloadGeneration`, which the editor's view
    /// identity uses. Matched by session identity against the pre-move path.
    /// The `isDirty` guard is belt-and-braces: such a session is already
    /// excluded from `writtenPaths`, and reloading one would discard unsaved
    /// text. Call this AFTER `adoptRenamed`, so a moved session reloads from
    /// its new location.
    func reloadRewritten(_ pass: LinkRewritePass) {
        for entry in pass.affected where pass.writtenPaths.contains(entry.path) {
            guard !entry.session.isDirty else { continue }
            try? entry.session.resolveByReloading()
        }
    }

    /// Plan-time links that have no rewrite, as report failures. A rename that
    /// leaves a link broken must not report success.
    static func unrewritableFailures(_ links: [UnrewritableLink]) -> [(url: URL, reason: String)] {
        links.map { ($0.sourceFile,
                     "Could not rewrite the link “\($0.rawTarget)” — "
                     + "the new location is outside the vault.") }
    }

    // MARK: - Applying

    /// Applies `plan`. Never throws: partial success is the expected outcome,
    /// and the caller (the confirmation UI, Task 10) decides how to present it.
    @discardableResult
    public func apply(_ plan: RenamePlan) -> RenameReport {
        // A refused plan writes nothing and creates nothing.
        if let refusal = plan.refusal {
            return RenameReport(rewritten: [], skipped: [],
                                failed: [(plan.source, refusal)], movedTo: nil)
        }

        var failed = Self.unrewritableFailures(plan.unrewritable)
        let isMove = plan.source.path != plan.destination.path

        // Refusals are checked BEFORE anything is written. The obvious
        // implementation rewrites first and discovers the collision after, at
        // which point every inbound link has been repointed at a name that
        // will never exist — a self-inflicted mass link break.
        if isMove {
            guard FileManager.default.fileExists(atPath: plan.source.path) else {
                failed.append((plan.source, "The file no longer exists."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
            // A case-ONLY rename (`chapter one` → `Chapter One`) is not a
            // collision: APFS/HFS+ are case-insensitive but case-preserving,
            // so `fileExists` at the destination finds the SAME file `moveItem`
            // is about to recapitalize, and `moveItem` handles that rename
            // natively. Without this exemption every capitalization fix was
            // refused as "already exists" — whole-branch review, Important 6.
            //
            // Identity is checked by INODE, not by a case-insensitive string
            // compare of the two paths. A string compare cannot tell "this is
            // the same file, just re-cased" apart from "this is a genuinely
            // DIFFERENT file whose name happens to differ only by case" — the
            // second is a real collision on a case-SENSITIVE volume, and a
            // string-only exemption let it slip past this guard straight into
            // `moveItem`, which then failed with a raw, unfriendly
            // `NSFileWriteFileExists` message instead of this function's own
            // wording (whole-branch review, fix round 2, Minor E).
            let isCaseOnlyRename = Self.sameFileOnDisk(plan.source, plan.destination)
            if !isCaseOnlyRename, FileManager.default.fileExists(atPath: plan.destination.path) {
                failed.append((plan.destination, "A file with that name already exists."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
            // The collision guard above is not the only way `moveItem` can
            // fail. A move into a folder that does not exist, or one we cannot
            // write to, reaches the SAME mass-link-break through the other
            // entry point: every inbound link repointed at a location the file
            // never arrives at. Checked here, before the first write.
            //
            // The destination folder is NOT created here. Pre-creating it (as
            // the first cut of folder rename did) leaves an empty directory
            // behind for every operation that then refuses — residue in no
            // report, from an operation that did nothing else.
            let parent = plan.destination.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            let parentExists = FileManager.default.fileExists(
                atPath: parent.path, isDirectory: &parentIsDirectory)
            guard parentExists, parentIsDirectory.boolValue else {
                failed.append((parent, "The destination folder does not exist."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                failed.append((parent, "The destination folder is not writable."))
                return RenameReport(rewritten: [], skipped: [], failed: failed, movedTo: nil)
            }
        }

        // Our own writes would otherwise wake `FolderWatcher` once per file and
        // each callback is a whole-vault rescan. One `rebuild()` at the end is
        // the correct amount.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)

        // Links FIRST, then the move.
        let pass = rewriteInboundLinks(edits: plan.edits, baselines: plan.baselines,
                                       movingPaths: isMove ? [Self.pathKey(plan.source)] : [])
        failed += pass.failed

        var moved: URL?
        if isMove {
            do {
                try FileManager.default.moveItem(at: plan.source, to: plan.destination)
                moved = plan.destination
                // Resolved BEFORE the move (inside the pass), never after:
                // `canonical` is `realpath(3)`, which FAILS on a path that no
                // longer exists and then hands back the unresolved URL.
                // Matching the source tab after `moveItem` therefore compared
                // `/var/...` against `/private/var/...` and silently found
                // nothing — the renamed document's own tab kept pointing at a
                // file that was gone.
                for entry in pass.movingSessions { entry.session.adoptRenamed(plan.destination) }
                transferOpenMTime(from: plan.source, to: plan.destination)
            } catch {
                failed.append((plan.source, error.localizedDescription))
            }
        }

        reloadRewritten(pass)

        // Re-armed: the window is a fixed 1s from the START of `apply`, and a
        // rename touching many files can outlive it — the watcher would then
        // wake mid-apply and queue a whole-vault rescan that our own `rebuild()`
        // is about to make redundant.
        coordinator.suppressWatcher(for: VaultIndexCoordinator.selfWriteSuppressionWindow)
        // The index still holds the old path and the old link targets.
        try? rebuild()

        // The moved file's own entry must be reported at its NEW path: it was
        // rewritten under the old name, which no longer exists by the time the
        // UI renders the report.
        let reportedRewrites = pass.rewritten.map {
            (moved != nil && $0.path == plan.source.path) ? plan.destination : $0
        }
        return RenameReport(rewritten: reportedRewrites.sorted { $0.path < $1.path },
                            skipped: pass.skipped.sorted { $0.url.path < $1.url.path },
                            unchanged: pass.unchanged.sorted { $0.path < $1.path },
                            failed: failed, movedTo: moved)
    }
}
