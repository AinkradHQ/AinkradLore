import Foundation

/// Where ↑/↓ move a selection in a list, as arithmetic.
///
/// Pure and view-free, this project's standing rule for anything a view
/// decides. It exists as its own type because the two sidebars and the search
/// bridge all need the SAME answers, and three copies of "clamp, or wrap, or
/// crash on an empty list" is how they end up disagreeing.
///
/// ## The rules, and why each one
///
/// - **No wrap.** Down from the last row stays on the last row. Wrapping to
///   the top is disorienting in a list whose length the user cannot see, and
///   in a long vault it silently teleports the selection off-screen.
/// - **Down from nothing selects the FIRST row**, not the second. This is the
///   ↓-from-the-search-field case: the first press must land on the top hit,
///   which is the one the user is looking at.
/// - **Up from nothing selects the LAST row**, so ↑ into a list from below
///   behaves the way ↓ into it from above does.
/// - **An empty list yields nil**, never an index. Every caller here is about
///   to subscript an array.
enum LoreListNavigation {

    enum Direction { case up, down }

    /// The index `direction` moves to, given `current` in a list of `count`.
    static func move(_ direction: Direction, from current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else {
            return direction == .down ? 0 : count - 1
        }
        switch direction {
        case .down: return min(current + 1, count - 1)
        case .up: return max(current - 1, 0)
        }
    }

    /// The selection after the list's CONTENTS change — a search that
    /// re-ranked, a rename, a delete.
    ///
    /// Re-finds the previously selected item by identity and follows it to its
    /// new position. Falls back to the first row when it is gone entirely,
    /// rather than to nil: after deleting a row, having the selection land on
    /// its neighbour is more useful than having it vanish, and a nil selection
    /// makes the next ↓ start from the top of a list the user has already
    /// scrolled.
    ///
    /// Returns nil only for an empty list.
    static func reconciled<ID: Equatable>(previous: ID?, ids: [ID]) -> Int? {
        guard !ids.isEmpty else { return nil }
        guard let previous, let index = ids.firstIndex(of: previous) else { return 0 }
        return index
    }
}
