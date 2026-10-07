import Foundation

/// Whether a document may be dragged into a folder, and why not when it may
/// not.
///
/// ## One rule, two readers
///
/// The drop highlight and the move itself must agree. If the rule lived only
/// inside `SidebarOperations.move(_:toFolder:)`, a folder would light up as a
/// valid target and then refuse the drop with a message — which reads as the
/// app changing its mind. This type is the rule; `move` uses it for its
/// sentences and the drop handler uses it to decide whether to highlight at
/// all, so the two cannot drift.
///
/// Pure and view-free, so every refusal is asserted directly rather than by
/// dragging things in a running app.
enum SidebarDrop {

    /// Why a drop cannot happen.
    enum Rejection: Equatable {
        /// No vault open, so there is nowhere to move anything.
        case noVault
        /// The destination is outside the vault. Refused rather than
        /// performed: the store would happily move the file, but its inbound
        /// links have no vault-relative path to be rewritten to, so every
        /// explicit-path link to it breaks and the file leaves the index.
        case outsideVault
        /// The document already lives there. Not an error — just nothing to do
        /// — but it must not be planned, because a "move" that changes nothing
        /// still produces a preview and a confirmation the user has no reason
        /// to read.
        case alreadyThere
        /// A folder cannot be dropped into itself or into its own descendant.
        /// Left unreachable today (only documents are draggable) and modelled
        /// anyway, because folder dragging is the obvious next step and this is
        /// the check whose absence would silently destroy a subtree.
        case intoItself
    }

    /// The reason this move is refused, or nil if it may proceed.
    static func rejection(moving source: URL, into folder: URL, root: URL?) -> Rejection? {
        guard let root else { return .noVault }
        let rootParts = VaultIndexCoordinator.canonical(root).pathComponents
        let destination = VaultIndexCoordinator.canonical(folder)
        let sourceCanonical = VaultIndexCoordinator.canonical(source)

        guard Array(destination.pathComponents.prefix(rootParts.count)) == rootParts else {
            return .outsideVault
        }
        // Compared as path COMPONENTS, never as a string prefix: `/v/Notes2`
        // has `/v/Notes` as a string prefix while being an unrelated sibling,
        // and a string test would refuse a legitimate move (or, reversed,
        // allow a destructive one).
        let sourceParts = sourceCanonical.pathComponents
        if Array(destination.pathComponents.prefix(sourceParts.count)) == sourceParts {
            return .intoItself
        }
        guard destination.path != sourceCanonical.deletingLastPathComponent().path else {
            return .alreadyThere
        }
        return nil
    }

    /// The index row a dropped file URL names, or nil.
    ///
    /// Matched CANONICALLY against the known rows, which does two jobs at
    /// once: it survives the `/tmp` versus `/private/tmp` spelling difference
    /// that this codebase documents at length, and it REJECTS anything that is
    /// not already a document in this vault. The drop type is `fileURL`, so
    /// without that second half a file dragged in from Finder would be treated
    /// as a move of a document Lore has never seen.
    static func row(for url: URL, in rows: [IndexRow]) -> IndexRow? {
        let key = VaultIndexCoordinator.canonical(url).path
        return rows.first { VaultIndexCoordinator.canonical($0.path).path == key }
    }

    /// The sentence for a refusal, given the names involved.
    static func describe(_ rejection: Rejection, source: URL, folder: URL) -> String {
        switch rejection {
        case .noVault:
            return "No vault is open."
        case .outsideVault:
            return "“\(folder.lastPathComponent)” is outside the vault. "
                + "Lore can only move documents to folders inside it."
        case .alreadyThere:
            return "“\(source.lastPathComponent)” is already in that folder."
        case .intoItself:
            return "“\(source.lastPathComponent)” can't be moved inside itself."
        }
    }
}
