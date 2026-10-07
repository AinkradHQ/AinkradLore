import AinkradAppKit
import SwiftUI

/// What a confirm dialog says and what its two buttons do, as a value.
///
/// Built outside SwiftUI so a test can press both buttons against a real store
/// (`LoreConfirmationTests`); the view only presents it, via
/// `loreConfirmDialog(_:)`. Both closures run on the main actor: they are
/// built in, and only ever called from, main-actor code.
@MainActor
struct LoreConfirmation {
    let title: String
    let message: String
    let confirmTitle: String
    /// The confirm button's work. The dialog then closes through `cancel`.
    let confirm: () -> Void
    /// Closes the dialog. Dismissal only — never store work — because it also
    /// runs after `confirm`, as the dialog's way of closing.
    let cancel: () -> Void

    /// "Create this note?" for a Cmd-clicked link that resolved to nothing —
    /// clicking a dead link must never create a file silently.
    ///
    /// Confirm goes through the store's single create-from-a-link path —
    /// `LoreStore.createAndOpenNote(forLinkTarget:)`, which owns the
    /// alias/fragment stripping and the folder split; this only reports a
    /// failure instead of swallowing it.
    ///
    /// `.wikilink` is not a guess: this prompt is reachable only from
    /// `MarkdownEditor.Coordinator.openLink(atUTF16:)`, whose target comes from
    /// `LinkCompletionContext.target(in:at:)` — a scanner that recognises `[[`
    /// and `]]` and nothing else. A markdown link is not clickable here, so no
    /// percent-decoding applies.
    static func createNote(
        named target: String, store: LoreStore, onFailure: @escaping (String) -> Void,
        dismiss: @escaping () -> Void
    ) -> LoreConfirmation {
        LoreConfirmation(
            title: "Create this note?",
            message: "\"\(target)\" doesn't exist in this vault yet.",
            confirmTitle: "Create",
            confirm: {
                do {
                    try store.createAndOpenNote(forLinkTarget: target, syntax: .wikilink)
                } catch {
                    onFailure("Couldn't create \"\(target)\": \(error.localizedDescription)")
                }
            },
            cancel: dismiss)
    }

    /// A refused or partial title commit, explained. Nothing to decide — the
    /// rename already happened or already did not — so both buttons only close
    /// it, as the alert's lone "OK" did.
    static func titleRefusal(
        title: String, reason: String, dismiss: @escaping () -> Void
    ) -> LoreConfirmation {
        LoreConfirmation(title: title, message: reason, confirmTitle: "OK", confirm: {}, cancel: dismiss)
    }
}

extension View {
    /// Presents `confirmation` as an `AinkradConfirmDialog` scoped to this
    /// view, while it is non-nil.
    ///
    /// Adds the two keys a system alert answered to and the kit dialog does not
    /// claim: Return confirms, Esc cancels. Claimed only while the dialog is
    /// up, so neither steals Return from the editor or Esc from the
    /// `[[`-completion popup otherwise.
    func loreConfirmDialog(_ confirmation: LoreConfirmation?) -> some View {
        ainkradConfirmDialog(
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation?.cancel() } }),
            title: confirmation?.title ?? "",
            message: confirmation?.message ?? "",
            confirmTitle: confirmation?.confirmTitle ?? "",
            onConfirm: { confirmation?.confirm() }
        )
        .background {
            if let confirmation {
                Button("Confirm") {  // design-lint: allow raw-control key-equivalent claim
                    confirmation.confirm()
                    confirmation.cancel()
                }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                Button("Cancel") {  // design-lint: allow raw-control key-equivalent claim
                    confirmation.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }
}
