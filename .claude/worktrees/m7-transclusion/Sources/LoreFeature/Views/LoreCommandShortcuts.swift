import SwiftUI
import AinkradAppKit

/// Binds every shortcut in `LoreCommands` in one place.
///
/// Replaces the hand-placed, zero-sized `Button` overlays that used to live at
/// each command's point of use — ⌘W inside `TabBarView`, ⌘N and ⌘\ inside the
/// sidebar header. The technique is the same (SwiftUI has no other way to
/// claim a key equivalent without a menu bar, and Lore is a plugin with no
/// menu bar of its own); what changes is that the LIST is now data, so it can
/// be enumerated, shown to the user, and checked for collisions by a test.
///
/// ## Availability gates the BINDING, not just the action
///
/// A command whose requirement is unmet is not mounted at all, rather than
/// mounted and inert. That matters for exactly one reason, and it is the
/// reason ⌘Z is modelled as a command in the first place: while it is bound,
/// it is claimed. `.keyboardShortcut` is dispatched at `performKeyEquivalent`
/// time, BEFORE `keyDown` reaches the first responder, so a permanently-bound
/// ⌘Z would take undo away from the text editor — where it means "undo my
/// typing" and is far more likely to be what the user meant. `LoreStore`
/// disarms the undo record after `undoWindow` seconds precisely so this
/// binding disappears again.
///
/// The same care is why Esc is NOT in the registry: `DocumentPane` claims it
/// only while a panel is open, so it does not steal `cancelOperation` from the
/// `[[`-completion popup.
struct LoreCommandShortcuts: ViewModifier {
    let runner: LoreCommandRunner

    func body(content: Content) -> some View {
        content.overlay {
            // Zero-sized and hidden: this is a key-equivalent claim, not a
            // control. Hidden from accessibility because the palette (⌘K) is
            // the discoverable, screen-reader-navigable route to the same
            // commands — a dozen invisible buttons in the tree would be noise.
            ZStack {
                ForEach(LoreCommands.available(in: runner.context)) { command in
                    if let shortcut = command.shortcut {
                        Button(command.title) { runner.run(command.id) }
                            .keyboardShortcut(KeyEquivalent(shortcut.key),
                                              modifiers: shortcut.eventModifiers)
                    }
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

extension LoreShortcut {
    /// The SwiftUI modifier set. Command is implied for every Lore shortcut —
    /// see `display`, which makes the same assumption so the bound key and the
    /// printed keycap cannot disagree.
    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = .command
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        return modifiers
    }
}

extension View {
    /// Mount once, at the surface root.
    func loreCommandShortcuts(_ runner: LoreCommandRunner) -> some View {
        modifier(LoreCommandShortcuts(runner: runner))
    }
}
