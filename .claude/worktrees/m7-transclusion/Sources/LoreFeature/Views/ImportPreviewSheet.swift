import SwiftUI
import AinkradAppKit

/// The selection behind the dry-run preview. An `ObservableObject` on purpose:
/// it is testable without instantiating SwiftUI, which is deliberate after an
/// M3 lesson where view-embedded logic got "tested" through a helper that
/// never exercised the real path.
///
/// `.alreadyImported` items are permanently excluded from selection — toggling
/// one is a no-op. They can never be created regardless of the user's choice,
/// so offering a checkbox that appears to control them would be dishonest.
@MainActor
public final class ImportSelection: ObservableObject {
    @Published public private(set) var deselected: Set<String> = []
    /// Recomputed from the surviving selection on every change, never patched.
    /// Patching would let the previewed plan drift from the plan that
    /// executes — the entire dry-run promise rests on those being identical.
    @Published public private(set) var plan: ImportPlan

    public let items: [ImportItem]
    let vaultRoot: URL
    let existingImportIDs: Set<String>

    public init(items: [ImportItem], vaultRoot: URL, existingImportIDs: Set<String>) {
        self.items = items
        self.vaultRoot = vaultRoot
        self.existingImportIDs = existingImportIDs
        self.plan = ImportPlanner.plan(items: items, vaultRoot: vaultRoot,
                                       existingImportIDs: existingImportIDs)
    }

    /// Whether `sourceID` will be handed to the planner. False for items
    /// already imported (see type doc) or explicitly deselected.
    public func isSelected(_ sourceID: String) -> Bool {
        !existingImportIDs.contains(sourceID) && !deselected.contains(sourceID)
    }

    public func toggle(_ sourceID: String) {
        guard !existingImportIDs.contains(sourceID) else { return }
        if deselected.contains(sourceID) { deselected.remove(sourceID) }
        else { deselected.insert(sourceID) }
        plan = ImportPlanner.plan(items: items.filter { isSelected($0.sourceID) },
                                  vaultRoot: vaultRoot, existingImportIDs: existingImportIDs)
    }
}

/// Confirms an import before anything is written to the vault. Every row is
/// deselectable except already-imported ones; the header count and the
/// Import button both track `plan.creating`, never `plan.items`, so the
/// preview never claims credit for rows that are informational only.
public struct ImportPreviewSheet: View {
    @ObservedObject var selection: ImportSelection
    let onImport: (ImportPlan) -> Void
    let onCancel: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    public init(selection: ImportSelection, onImport: @escaping (ImportPlan) -> Void,
                onCancel: @escaping () -> Void) {
        self.selection = selection
        self.onImport = onImport
        self.onCancel = onCancel
    }

    private var creatingCount: Int { selection.plan.creating.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(headline)
                .font(AinkradFontResolver.font(.headline, typography: typo))
                .foregroundStyle(theme.foreground)
            // Lazy: a few thousand notes is an ordinary Apple Notes library,
            // and this list must not be the thing that makes import feel broken.
            List {
                ForEach(selection.items, id: \.sourceID) { item in
                    ImportPreviewRow(
                        item: item,
                        planned: selection.plan.items.first { $0.item.sourceID == item.sourceID },
                        isAlreadyImported: selection.existingImportIDs.contains(item.sourceID),
                        isSelected: selection.isSelected(item.sourceID),
                        toggle: { selection.toggle(item.sourceID) }
                    )
                }
            }
            .listStyle(.plain)
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                AinkradButton(title: "Import", style: .primary, action: { onImport(selection.plan) })
                    .disabled(creatingCount == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(minWidth: 620, minHeight: 460)
        .background(theme.surface)
    }

    private var headline: String {
        creatingCount == 0
            ? "Nothing selected to import"
            : "\(creatingCount) item\(creatingCount == 1 ? "" : "s") will be imported"
    }
}
