import SwiftUI
import AinkradAppKit

/// One row of the import dry-run preview: a checkbox, the item's title, its
/// planned target path, and any `FidelityWarning`s — the user's only signal
/// that a conversion will lose something, so they are always shown, never
/// collapsed behind a disclosure.
struct ImportPreviewRow: View {
    let item: ImportItem
    /// Nil only when the item was excluded from the plan's input (i.e. it is
    /// currently deselected); in that case there is no target path to show.
    let planned: PlannedItem?
    let isAlreadyImported: Bool
    let isSelected: Bool
    let toggle: () -> Void

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        AinkradListRow(
            isSelected: isSelected,
            onTap: isAlreadyImported ? nil : toggle,
            leading: { checkbox },
            title: item.title,
            subtitle: subtitle,
            trailing: { EmptyView() }
        )
        .opacity(isAlreadyImported ? 0.5 : 1)
    }

    /// Deliberately an INDICATOR, not a control. `AinkradToggle` is a `Button`,
    /// and a button nested inside `AinkradListRow`'s `onTapGesture` gave the row
    /// two independent toggle paths: clicking the checkbox fired both and the
    /// selection landed back where it started. The row owns the single tap
    /// target; this only reports what that tap did.
    @ViewBuilder private var checkbox: some View {
        Image(systemName: isAlreadyImported || isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isAlreadyImported
                ? theme.foreground.opacity(LoreMetrics.indicatorGlyph)
                : (isSelected ? theme.accentPrimary
                              : theme.foreground.opacity(LoreMetrics.indicatorGlyph)))
            .accessibilityLabel(isAlreadyImported ? "Already imported"
                : (isSelected ? "Selected for import" : "Not selected"))
    }

    private var subtitle: String {
        var lines: [String] = []
        if isAlreadyImported {
            lines.append("Already imported")
        } else if let planned {
            switch planned.disposition {
            case .create:
                lines.append(planned.targetURL.lastPathComponent)
            case .renamedToAvoidCollision(let original):
                lines.append("\(planned.targetURL.lastPathComponent) (renamed from \(original) to avoid a collision)")
            case .alreadyImported:
                lines.append("Already imported")
            }
        }
        if !item.fidelity.isEmpty {
            lines.append(item.fidelity.map(\.detail).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
