import AinkradAppKit
import Foundation

/// Lore's notification vocabulary, in one place so the kinds stay consistent
/// and every emission decision is visible together.
///
/// **Derived from what Lore actually tracks, not from what a document editor
/// might plausibly report.** Three things here are genuinely worth a
/// notification, and they are the three the code already models as terminal
/// states: an import finishing, an import needing a permission the user must
/// grant, and a vault rescan failing.
///
/// Everything else Lore does — opening, editing, saving a document — happens
/// while the user is looking at it, and the editor already says so in its own
/// chrome. A feed row for a save the user just watched succeed is noise.
@MainActor
public struct LoreSignalReporter {
    let signals: PluginSignalEmitter

    /// `public` only because `ImportCoordinator`'s initialiser is public and
    /// takes one. The methods stay internal — nothing outside this module
    /// should be filing Lore's notifications.
    public init(signals: PluginSignalEmitter) { self.signals = signals }

    /// An import finished.
    ///
    /// Always reported, unlike most successes: an import is the archetypal
    /// look-away operation — the user picks a vault of several thousand notes
    /// and goes to do something else. There is no duration threshold to apply
    /// because there is no version of this that is too quick to mention.
    ///
    /// Severity follows the report rather than the outcome: an import that
    /// wrote 400 files and failed on 3 is not a success, and calling it one
    /// hides the three the user would want to look at.
    func importFinished(imported: Int, skipped: Int, failed: Int) {
        let hadFailures = failed > 0
        var parts: [String] = ["\(imported) file\(imported == 1 ? "" : "s") imported"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if hadFailures { parts.append("\(failed) failed") }

        signals.emit(
            kind: hadFailures ? "import.finished-with-errors" : "import.finished",
            severity: hadFailures ? .warning : .success,
            title: hadFailures ? "Import finished with errors" : "Import finished",
            body: parts.joined(separator: ", ") + ".",
            importance: .normal,
            // Per import run, not per file: a run is one thing that happened.
            dedupeKey: nil)
    }

    /// An import could not run at all.
    func importFailed(reason: String) {
        signals.emit(
            kind: "import.failed",
            severity: .failure,
            title: "Import failed",
            body: reason,
            importance: .normal)
    }

    /// An import stopped because macOS automation permission is missing.
    ///
    /// **The one `.urgent` kind Lore has.** It is not merely a failure: the
    /// import is halted, waiting, and the fix is a switch the user can flip
    /// right now. That is the same shape as an agent blocked on input — the
    /// case where not knowing costs the whole wait — and it is exactly what
    /// `.urgent` is for.
    func importNeedsAutomation(detail: String) {
        signals.emit(
            kind: "import.needs-permission",
            severity: .warning,
            title: "Import needs permission to continue",
            body: detail,
            importance: .urgent)
    }

    /// A background vault rescan failed.
    ///
    /// `.warning` and never `.urgent`: the vault on disk is fine, the INDEX is
    /// stale, so search and the sidebar may be out of date until the next
    /// rescan succeeds. Worth knowing, not worth interrupting for.
    ///
    /// Deduped per reason, because a rescan that fails once usually fails every
    /// time — a watched folder that vanished produces one row with a count
    /// rather than one row per filesystem event.
    func vaultRescanFailed(reason: String) {
        signals.emit(
            kind: "index.rescan-failed",
            severity: .warning,
            title: "Lore could not re-read the vault",
            body: reason + " Search results may be out of date until this succeeds.",
            importance: .normal,
            dedupeKey: "lore.rescan:\(reason)")
    }
}
