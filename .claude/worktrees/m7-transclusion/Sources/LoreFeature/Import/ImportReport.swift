import Foundation

/// Per-item outcome of `ImportApplier.apply`. One item can land in at most one
/// of `imported`/`skipped`, but can ALSO contribute to `failed` even when it
/// otherwise succeeded — an item whose note wrote fine but whose attachment
/// could not be copied still counts as imported, with the attachment failure
/// reported separately (see `ImportApplierTests.testOneFailedItemDoesNotAbortTheRun`).
public struct ImportReport: Sendable {
    /// Every file written, notes and attachments alike — an Obsidian vault
    /// imports its images as files in their own right, so this is a count of
    /// FILES, not of notes.
    ///
    /// These are the paths things ACTUALLY landed at, which is not always what
    /// the previewed plan proposed: the planner is pure and resolves collisions
    /// only within the selection, while the applier re-resolves against the
    /// real directory. Where the two differ, `renamed` says so.
    public var imported: [URL] = []
    public var skipped: [(id: String, reason: String)] = []
    public var failed: [(id: String, reason: String)] = []
    /// Names that changed at apply time because something already on disk held
    /// them — the preview said `Plan.md`, `Plan 2.md` landed.
    ///
    /// Reported rather than absorbed silently. The dry-run promise is that the
    /// user sees what will happen; when reality diverges from the plan (a file
    /// appearing between preview and apply, or a collision the pure planner
    /// could not see), the honest move is to say which name moved and where it
    /// went, not to quietly write somewhere else.
    public var renamed: [(id: String, from: String, to: String)] = []

    public init(imported: [URL] = [],
                skipped: [(id: String, reason: String)] = [],
                failed: [(id: String, reason: String)] = [],
                renamed: [(id: String, from: String, to: String)] = []) {
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.renamed = renamed
    }
}
