import Foundation

/// Coalesces a burst of calls into one: only the LAST action scheduled within
/// the interval runs, once the burst settles.
///
/// The one main-run-loop `Timer` coalescer in Lore. It replaced two identical
/// copies — the document pane's outline refresh (one call per keystroke) and
/// the editor menu's spelling lookup (one call per caret move) — and the same
/// shape `MarkdownEditor.Coordinator.scheduleParse` uses for its own re-parse.
///
/// A class, not a struct, so a view's `@State` holds the SAME instance — and
/// therefore the same in-flight `Timer` — across every body re-evaluation; a
/// struct copy would lose the pending timer on every redraw and never coalesce
/// anything.
@MainActor
final class MainRunLoopDebouncer {
    // `nonisolated(unsafe)`: `deinit` on a `@MainActor` class is itself
    // nonisolated (it may run once nothing else can reach `self`), so it
    // cannot touch a main-actor-isolated stored property without this. Every
    // OTHER access to `timer` is still on the main actor, through this
    // class's own main-actor-isolated methods.
    private nonisolated(unsafe) var timer: Timer?

    /// A pending action must not fire into an owner that is gone — a dismissed
    /// pane, a closed editor.
    deinit { timer?.invalidate() }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer = t
        // `.common`, not `.default`: the action must still land while the user
        // is scrolling or holding a menu open.
        RunLoop.main.add(t, forMode: .common)
    }
}
