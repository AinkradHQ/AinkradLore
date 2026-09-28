import SwiftUI
import AinkradAppKit

/// The three banners every document type can raise: read-only, conflict, and a
/// failed save.
///
/// Split out of `DocumentPane.swift` for the 500-line ceiling. They belong
/// together because they are one decision — WHICH of the three states the
/// document is in — and because their severities are only meaningful relative
/// to each other: neutral for read-only (nothing is wrong and nothing to fix),
/// warning for a conflict (resolvable, three ways), danger for a save that
/// failed (nothing to offer but the fact). Separating them would let those
/// three drift apart, which is how the pre-`LoreBanner` version ended up
/// colour-coded by whichever brand accent was left over.
extension DocumentPane {

    // Internal rather than private: `body` lives in `DocumentPane.swift` and
    // Swift's `private` is file-scoped. They remain implementation detail
    // outside the module.

    /// Persistent and non-alarming: this file is open, readable and searchable,
    /// it simply cannot be written back. A user typing into a document that
    /// will never save, with no indication, is the failure this prevents.
    ///
    /// `.neutral`, not a warning: nothing is wrong and there is nothing to
    /// fix. The status also picks the icon and colour, which is why these
    /// three banners no longer name either — see `LoreBanner`.
    var readOnlyBanner: some View {
        LoreBanner(message: "Read-only: this file isn't valid UTF-8, so Lore can't write it "
                       + "back without destroying data. Edits here won't be saved.",
                   status: .neutral)
    }

    /// Three resolutions, all reachable, none destructive by default. The old
    /// dialog offered only "load from disk" and treated dismissal as
    /// "overwrite", which meant the safe choice was the one you got by
    /// accident.
    var conflictBanner: some View {
        LoreBanner(message: "This document changed on disk outside Lore.",
                   status: .warning) {
            AinkradButton(title: "Reload from disk", style: .secondary) {
                try? session.resolveByReloading()
            }
            // Labelled to say where editing continues: this tab adopts the copy.
            AinkradButton(title: "Save my copy & edit it", style: .secondary) {
                try? session.resolveBySavingCopy()
            }
            AinkradButton(title: "Overwrite disk", style: .ghost) {
                try? session.resolveByOverwriting()
            }
        }
    }

    /// Disk full, permissions, a read-only volume. There is no resolution to
    /// offer — the only requirement is that it stops being invisible.
    func saveErrorBanner(_ error: Error) -> some View {
        LoreBanner(message: "Couldn't save this document: \(error.localizedDescription)",
                   status: .danger)
    }
}
