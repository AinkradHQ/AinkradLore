import Foundation

/// What the header says about whether the open document is safely on disk.
///
/// Pure and view-free, for the reason `LoreRootView.emptyState(for:)` and
/// `DocumentPanelState` already establish in this project: SwiftUI views are
/// only smoke-testable here, so the DECISION is asserted directly and the view
/// is left with nothing but layout.
///
/// ## Why this exists at all
///
/// Before this, the only save signal in Lore was a 6pt dot on a tab. That dot
/// answers "are there unsaved edits right now" and nothing else — it cannot
/// distinguish a document that just saved from one that has never been
/// touched, and it says nothing at all while a save is failing (the banner
/// covers that case, but only for the document you are looking at). Autosave
/// is debounced, so "I stopped typing" and "my work is on disk" are up to a
/// second apart, and the user had no way to tell which side of that they were
/// on.
enum DocumentSaveState: Equatable {
    /// Cannot be written back at all — the read-only banner explains why. The
    /// header still says it, because the banner scrolls out of a long
    /// document and the consequence (nothing you type is kept) is permanent.
    case readOnly
    /// The last write failed. Outranks everything below: unsaved edits that
    /// CANNOT be saved are a different situation from unsaved edits that are
    /// merely waiting.
    case failed
    /// Edits exist that are not on disk yet.
    case unsaved
    /// Written to disk at the associated time.
    case saved(Date)
    /// Opened, untouched, never written by this session. Deliberately NOT
    /// `.saved`: claiming a save that never happened is exactly the kind of
    /// small lie that stops people trusting the indicator when it matters.
    case idle

    /// Derives the state from a session.
    ///
    /// Order is the point. `isDirty` is true during a failed save AND during
    /// an ordinary pending one, so testing it first would report "Unsaved" for
    /// a document whose write is erroring — the reassuring reading of the two.
    /// Conflict is not represented here: it has its own banner with its own
    /// three resolutions, and flattening it into a save state would offer the
    /// user a word where they need a choice.
    static func of(readOnly: Bool, hasSaveError: Bool,
                   isDirty: Bool, lastSavedAt: Date?) -> DocumentSaveState {
        if readOnly { return .readOnly }
        if hasSaveError { return .failed }
        if isDirty { return .unsaved }
        if let lastSavedAt { return .saved(lastSavedAt) }
        return .idle
    }

    /// The words the header shows. `now` is injected rather than read from the
    /// clock so the relative phrasing is testable.
    func label(now: Date) -> String {
        switch self {
        case .readOnly: return "Read-only"
        case .failed: return "Not saved"
        case .unsaved: return "Unsaved…"
        case .idle: return ""
        case .saved(let at):
            let elapsed = now.timeIntervalSince(at)
            // Three buckets, not a timestamp. The question behind a glance at
            // this indicator is "is my work safe", whose answer stops changing
            // after about a minute — a live-updating "saved 4 minutes ago" is
            // motion in the corner of the eye that carries no new information.
            if elapsed < 5 { return "Saved" }
            if elapsed < 60 { return "Saved just now" }
            return "Saved"
        }
    }

    /// Whether this state is worth drawing attention to. Drives the header's
    /// colour, so an ordinary save stays quiet and a failure does not.
    var isAlarming: Bool { self == .failed }
}
