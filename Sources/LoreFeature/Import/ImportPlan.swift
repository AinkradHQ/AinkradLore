import Foundation

/// What the planner decided to do with one item. `.alreadyImported` items are
/// never written by the applier — they exist in the plan purely so the
/// preview can show the user why a row is greyed out.
enum ImportDisposition: Sendable, Equatable {
    case create
    case renamedToAvoidCollision(original: String)
    case alreadyImported
}

/// One item's planned destination. `targetURL` is always inside `vaultRoot`
/// (see `ImportPlanner`'s containment guard) regardless of what the source's
/// `folderPath` contained.
struct PlannedItem: Sendable, Equatable {
    let item: ImportItem
    let targetURL: URL
    let disposition: ImportDisposition
}

/// The full, pure result of `ImportPlanner.plan`. The applier (Task 11)
/// consumes exactly this — nothing it does may diverge from what the user
/// previewed and approved.
struct ImportPlan: Sendable, Equatable {
    let items: [PlannedItem]

    init(items: [PlannedItem]) {
        self.items = items
    }

    /// The subset the applier actually needs to write. `.alreadyImported`
    /// rows are informational only.
    var creating: [PlannedItem] {
        items.filter { $0.disposition != .alreadyImported }
    }
}
