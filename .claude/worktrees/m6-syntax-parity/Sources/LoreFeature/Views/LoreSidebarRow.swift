import SwiftUI
import AinkradAppKit

/// Both kinds of sidebar row, built from the SAME component so their height,
/// padding, hover and selection cannot drift apart.
///
/// Folder rows used to be a bare `Button` wrapping an
/// `HStack(spacing: AinkradSpacing.xs)` with no padding at all, while document
/// rows were `AinkradListRow` (`.md` horizontal, `.sm` vertical, a `.md` gap
/// after the glyph). That is the entire cause of the mismatched spacing: two
/// row kinds with two sets of metrics, neither one wrong on its own.
///
/// The chevron is passed as `AinkradListRow`'s `leading`, which is what puts
/// it in the same column as a document's icon.
@MainActor
enum LoreSidebarRow {

    @ViewBuilder
    static func folder(name: String, depth: Int, isExpanded: Bool,
                       onToggle: @escaping () -> Void) -> some View {
        AinkradListRow(
            isSelected: false,
            onTap: onToggle,
            leading: {
                AinkradIconGlyph(systemName: isExpanded ? "chevron.down" : "chevron.right")
            },
            title: name,
            subtitle: nil,
            trailing: { EmptyView() })
            .padding(.leading, LoreSidebarMetrics.indent(depth: depth))
            .accessibilityElement(children: .combine)
            // The chevron is the only thing that says expanded or collapsed,
            // and a glyph name is not something VoiceOver can read as state.
            .accessibilityLabel("\(name), folder, \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityAddTraits(.isButton)
    }

    /// - Parameters:
    ///   - subtitle: Passed straight through to `AinkradListRow`. `nil` for
    ///     `FolderTreeView`'s tree rows; `NoteListView`'s tag-chip line for its
    ///     flat list.
    ///   - emptyTitleFallback: What to show when `row.title` is empty. `nil`
    ///     (the default) falls back to `row.path.lastPathComponent`, which is
    ///     what `FolderTreeView` wants and already had. `NoteListView` passes
    ///     `"Untitled"` to keep its own existing fallback — the two views
    ///     disagreed on this before the row types were unified, and unifying
    ///     the component is not an excuse to also unify a choice neither view
    ///     asked to change.
    /// - Parameter attributedSubtitle: A search excerpt with its matches
    ///   emphasised. Rendered BENEATH the row rather than inside it, because
    ///   `AinkradListRow.subtitle` is a plain `String` and the kit has no
    ///   attributed variant — and widening the kit would move the SDK
    ///   revision this plugin is pinned to, which is a far larger change than
    ///   a highlighted excerpt is worth. Takes precedence over `subtitle`:
    ///   two subtitles on one row would bury the more useful one.
    @ViewBuilder
    static func document(row: IndexRow, depth: Int, isSelected: Bool,
                         subtitle: String? = nil,
                         attributedSubtitle: AttributedString? = nil,
                         emptyTitleFallback: String? = nil,
                         onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AinkradListRow(
                isSelected: isSelected,
                onTap: onTap,
                leading: { AinkradIconGlyph(systemName: icon(for: row)) },
                title: row.title.isEmpty
                    ? (emptyTitleFallback ?? row.path.lastPathComponent) : row.title,
                subtitle: attributedSubtitle == nil ? subtitle : nil,
                trailing: { EmptyView() })
            if let attributedSubtitle {
                SearchExcerptLine(text: attributedSubtitle)
            }
        }
        // The whole cell taps, excerpt included — an excerpt that is not part
        // of the click target is a strip of dead space in the middle of a list.
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // A NON-COLOUR selection cue, alongside the fill.
        //
        // `AinkradListRow`'s selected state is an accent-tinted background and
        // nothing else, so "which document is open" was carried by colour
        // alone — unreadable for anyone who cannot distinguish the tint from
        // the surface, and marginal for everyone in bright light. The bar is a
        // second, redundant channel for the same fact.
        .overlay(alignment: .leading) {
            if isSelected { SelectionBar() }
        }
        .padding(.leading, LoreSidebarMetrics.indent(depth: depth))
        // ONE element per row, not four (icon, title, subtitle, excerpt).
        // Without this VoiceOver walks the pieces separately and a row reads
        // as a stream of fragments rather than as a document.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: row, subtitle: subtitle,
                                               emptyTitleFallback: emptyTitleFallback))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// What VoiceOver reads for a document row.
    ///
    /// The tag line is folded in rather than left as a separate element, and
    /// an attachment is named as one: "Q1, attachment" tells a screen-reader
    /// user why the row has no Delete in its menu, which the icon conveys
    /// visually and nothing conveyed otherwise.
    static func accessibilityLabel(for row: IndexRow, subtitle: String?,
                                   emptyTitleFallback: String?) -> String {
        let name = row.title.isEmpty
            ? (emptyTitleFallback ?? row.path.lastPathComponent) : row.title
        var parts = [name]
        if row.type == AttachmentEngine.identifier { parts.append("attachment") }
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    static func icon(for row: IndexRow) -> String {
        row.type == AttachmentEngine.identifier ? "doc" : "doc.text"
    }
}

/// The search excerpt beneath a row.
///
/// A view for the same reason `SelectionBar` is one: these row builders are
/// `static` functions with no `self` to hold an `@Environment` on, and the
/// excerpt has to read the host's typography rather than SwiftUI's own
/// `.caption` — otherwise it is the one line in the sidebar that ignores the
/// type scale everything else follows.
private struct SearchExcerptLine: View {
    let text: AttributedString
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        Text(text)
            .font(AinkradFontResolver.font(.caption, typography: typo))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Indented to the row's TITLE column, not its icon, so the excerpt
            // reads as belonging to the title above it.
            .padding(.leading, AinkradSpacing.lg + AinkradSpacing.md)
            .padding(.trailing, AinkradSpacing.md)
            .padding(.bottom, AinkradSpacing.xs)
    }
}

/// The leading accent bar on a selected row.
///
/// A view rather than an inline `Rectangle` because these row builders are
/// `static` functions with no `self` to hold an `@Environment` on — and the
/// bar has to read the live theme, since a hard-coded colour would be the one
/// part of the row that ignores the host's palette.
private struct SelectionBar: View {
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.accentPrimary)
            .frame(width: 2)
            .accessibilityHidden(true)
    }
}
