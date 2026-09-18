import SwiftUI
import AinkradAppKit

/// The import surface: pick a source, review what would land, then land it.
///
/// Every state here is terminal-or-recoverable — there is no path that leaves
/// the user looking at a sheet with nothing to do, which is the failure mode
/// the wizard hit twice in the host.
struct ImportEntryView: View {
    @Bindable var coordinator: ImportCoordinator
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo
    let onClose: () -> Void

    var body: some View {
        Group {
            switch coordinator.state {
            case .choosingSource:
                sourcePicker
            case .scanning:
                AinkradEmptyState(
                    icon: "magnifyingglass",
                    title: "Reading the source…",
                    message: "Nothing is written to your vault until you approve it.")
            case .previewing(let selection):
                ImportPreviewSheet(
                    selection: selection,
                    onImport: { plan in Task { await coordinator.apply(plan) } },
                    onCancel: onClose)
            case .finished(let report):
                report_(report)
            case .needsAutomation(let detail):
                AinkradEmptyState(
                    icon: "lock.shield",
                    title: "Lore needs permission to read Notes",
                    message: detail + "\n\nTurn Lore on under Notes, then come back and "
                        + "try again. Nothing has been written to your vault.",
                    actionTitle: "Open Automation settings…",
                    action: coordinator.openAutomationSettings)
            case .failed(let message):
                AinkradEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Import stopped",
                    message: message,
                    actionTitle: "Back",
                    action: coordinator.reset)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }

    /// The two sources that actually work. Neither is offered as a disabled
    /// row — an affordance that cannot be used teaches the user it is broken.
    /// Each appears because the source behind it does.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text("Import into this vault")
                .font(AinkradFontResolver.font(.headline, typography: typo))
                .foregroundStyle(theme.tokens.foreground)
            Text("Lore shows you everything it would write, and writes nothing until you "
                 + "approve it. Anything you have already imported is skipped.")
                .font(.callout)
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            AinkradListRow(
                onTap: coordinator.chooseObsidianVault,
                leading: { AinkradIconGlyph(systemName: "folder") },
                title: "Obsidian vault",
                subtitle: "Copies the vault in and keeps your [[wikilinks]] working.",
                trailing: { Image(systemName: "chevron.right")
                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.indicatorGlyph)) })
            AinkradListRow(
                onTap: coordinator.importAppleNotes,
                leading: { AinkradIconGlyph(systemName: "note.text") },
                title: "Apple Notes",
                subtitle: "Asks Notes for every note in every account. Locked notes and "
                    + "the Recently Deleted folder are left alone.",
                trailing: { Image(systemName: "chevron.right")
                    .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.indicatorGlyph)) })
            Spacer()
        }
        .padding(AinkradSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Named with a trailing underscore to avoid colliding with the `report`
    /// value it renders.
    @ViewBuilder private func report_(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(Self.headline(report))
                .font(AinkradFontResolver.font(.headline, typography: typo))
                .foregroundStyle(theme.tokens.foreground)
            // Skipped and failed are listed, never summarised away. A silent
            // partial import is the one outcome this whole milestone exists to
            // prevent — the user has to be able to see WHICH file did not make
            // it, not just that some number of them did not.
            List {
                // Renames first: this is the one line of the report that
                // contradicts what the preview said, so burying it under the
                // skips would defeat the point of reporting it at all.
                ForEach(report.renamed, id: \.from) { _, from, to in
                    line(from, "already existed — imported as “\(to)”",
                         icon: "pencil", tint: theme.tokens.foreground.opacity(0.8))
                }
                ForEach(report.skipped, id: \.0) { id, reason in
                    line(id, reason, icon: "arrow.turn.down.right", tint: theme.tokens.foreground.opacity(0.6))
                }
                ForEach(report.failed, id: \.0) { id, reason in
                    line(id, reason, icon: "exclamationmark.circle", tint: .red)
                }
            }
            .listStyle(.plain)
            .opacity(report.skipped.isEmpty && report.failed.isEmpty
                     && report.renamed.isEmpty ? 0 : 1)
            HStack {
                Spacer()
                AinkradButton(title: "Done", style: .primary, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AinkradSpacing.lg)
    }

    private func line(_ id: String, _ reason: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.sm) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(id).foregroundStyle(theme.tokens.foreground)
                Text(reason).font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            }
        }
    }

    /// The counts the user is owed, in one sentence.
    ///
    /// `imported` mixes note and attachment URLs (an Obsidian vault imports its
    /// images as files in their own right), so this counts FILES written and
    /// says so, rather than claiming a note count it cannot substantiate.
    static func headline(_ report: ImportReport) -> String {
        var parts = ["\(report.imported.count) file\(report.imported.count == 1 ? "" : "s") imported"]
        if !report.renamed.isEmpty { parts.append("\(report.renamed.count) renamed") }
        if !report.skipped.isEmpty { parts.append("\(report.skipped.count) already imported") }
        if !report.failed.isEmpty { parts.append("\(report.failed.count) failed") }
        return parts.joined(separator: " · ")
    }
}
