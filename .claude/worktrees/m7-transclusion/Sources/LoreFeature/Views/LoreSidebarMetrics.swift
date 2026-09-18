import CoreGraphics
import AinkradAppKit

/// Sidebar geometry shared by `FolderTreeView` and `NoteListView`.
///
/// Pure and view-free on purpose: the indent is the rule that decides whether
/// a document and its sibling folder line up, and it is asserted directly
/// rather than through a view host — the same reasoning `MarkdownReveal`
/// already applies.
enum LoreSidebarMetrics {

    /// One nesting level. `AinkradSpacing.md`, so the tree steps on the same
    /// scale as every other gap in the app rather than a bare `12`.
    static let indentUnit: CGFloat = AinkradSpacing.md

    /// Leading pad for a row at `depth`.
    ///
    /// Applied identically to folder rows and document rows. A document
    /// inside a folder is at the same depth as a subfolder of that folder,
    /// because it is — the old `(depth + 1)` asymmetry is what put the two
    /// kinds of row in different columns.
    static func indent(depth: Int) -> CGFloat {
        CGFloat(max(depth, 0)) * indentUnit
    }
}
