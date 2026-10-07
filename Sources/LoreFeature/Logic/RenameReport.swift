import Foundation

/// Why one file was left alone by a rewrite pass.
///
/// Carried per file rather than implied by the list it lands in, because
/// `skipped` has THREE causes that are not interchangeable to the person
/// reading the report: "another app edited this file" is a fact about the
/// vault, while "your own tab has unsaved edits" is an instruction to go and
/// save. The first cut of the confirmation UI described every skip as "changed
/// by another app and left alone", which is simply false for the unsaved-edits
/// case — a report that misattributes a cause is worse than one that omits it,
/// because the user acts on it.
enum SkipReason: Sendable, Equatable {
    /// The file's mtime moved past the plan-time baseline: someone edited it
    /// between the preview and the confirmation.
    case changedOnDisk
    /// No usable baseline, or the mtime could not be read. We cannot prove the
    /// file is the one we planned against, so we do not write it.
    case unverifiable
    /// An open tab still holds unsaved edits to it and flushing them refused,
    /// so the file was excluded from the rewrite entirely.
    case unsavedEdits

    /// Completes the sentence "This file …". Present tense, because each of
    /// these is still true when the user reads it.
    var phrase: String {
        switch self {
        case .changedOnDisk: "was changed outside Lore after the preview"
        case .unverifiable: "could not be confirmed unchanged since the preview"
        case .unsavedEdits: "has unsaved edits in an open tab"
        }
    }
}

/// One file a rewrite pass declined to write, with the reason it declined.
struct SkippedFile: Sendable, Equatable {
    let url: URL
    let reason: SkipReason
    init(url: URL, reason: SkipReason) {
        self.url = url
        self.reason = reason
    }
}

/// What actually happened when a plan was applied. Partial success is the
/// EXPECTED case, not an error state: a file that changed on disk is skipped
/// so an edit made seconds ago in another app is not destroyed. `apply` does
/// not throw — the caller decides how to present this.
struct RenameReport: Sendable {
    /// Files whose inbound links were rewritten.
    let rewritten: [URL]
    /// Files left ALONE, each carrying WHY — see `SkipReason`. Their links still
    /// point at the old name; nothing was lost.
    let skipped: [SkippedFile]
    /// Files that were opened and matched nothing — no delimiter-anchored
    /// occurrence of the old target survived to rewrite time. Nothing was
    /// written, so they must not be listed as `rewritten` (an untruthful
    /// report) nor as `skipped` (nothing was refused).
    let unchanged: [URL]
    /// Files that could not be processed, with a human-readable reason. Also
    /// carries plan-time unrewritable links and a refused move.
    let failed: [(url: URL, reason: String)]
    /// The new location, or nil if the file was not moved.
    let movedTo: URL?

    init(
        rewritten: [URL], skipped: [SkippedFile], unchanged: [URL] = [],
        failed: [(url: URL, reason: String)], movedTo: URL?
    ) {
        self.rewritten = rewritten
        self.skipped = skipped
        self.unchanged = unchanged
        self.failed = failed
        self.movedTo = movedTo
    }

    /// True when every file the plan named was handled and the move (if any)
    /// happened. The UI shows a confirmation only for this.
    var isCompleteSuccess: Bool { skipped.isEmpty && failed.isEmpty }
}
