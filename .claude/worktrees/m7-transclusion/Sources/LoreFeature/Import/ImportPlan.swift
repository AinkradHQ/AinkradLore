import Foundation

/// What the planner decided to do with one item. `.alreadyImported` items are
/// never written by the applier — they exist in the plan purely so the
/// preview can show the user why a row is greyed out.
public enum ImportDisposition: Sendable, Equatable {
    case create
    case renamedToAvoidCollision(original: String)
    case alreadyImported
}

/// One item's planned destination. `targetURL` is always inside `vaultRoot`
/// (see `ImportPlanner`'s containment guard) regardless of what the source's
/// `folderPath` contained.
public struct PlannedItem: Sendable, Equatable {
    public let item: ImportItem
    public let targetURL: URL
    public let disposition: ImportDisposition
}

/// The full, pure result of `ImportPlanner.plan`. The applier (Task 11)
/// consumes exactly this — nothing it does may diverge from what the user
/// previewed and approved.
public struct ImportPlan: Sendable, Equatable {
    public let items: [PlannedItem]

    public init(items: [PlannedItem]) {
        self.items = items
    }

    /// The subset the applier actually needs to write. `.alreadyImported`
    /// rows are informational only.
    public var creating: [PlannedItem] {
        items.filter { $0.disposition != .alreadyImported }
    }
}
