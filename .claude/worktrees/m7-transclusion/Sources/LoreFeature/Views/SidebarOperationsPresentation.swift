import SwiftUI
import AinkradAppKit

/// Every modal the sidebar's rename / move / trash flows need, attached in ONE
/// place so both sidebar modes get identical behaviour and `LoreRootView` stays
/// under the project's line ceiling.
///
/// A single `.sheet` driven by `SidebarOperations.activeSheet` rather than three
/// stacked `.sheet` modifiers: more than one sheet attached to the same view is
/// unreliable on macOS, and the failure mode is a dialog that silently never
/// appears — which, for a confirmation dialog guarding an irreversible bulk
/// mutation, is the worst possible way to fail.
extension View {
    func loreSidebarOperations(_ ops: SidebarOperations, theme: HostTheme) -> some View {
        self
            .overlay { LoreNoticeBridge(ops: ops) }
            .sheet(isPresented: Binding(
                get: { ops.activeSheet != nil },
                set: { if !$0 { ops.dismissAll() } })) {
                    SidebarOperationSheet(ops: ops, theme: theme)
                }
            .ainkradConfirmDialog(
                isPresented: Binding(get: { ops.pendingTrash != nil },
                                     set: { if !$0 { ops.cancelTrash() } }),
                title: "Move to Trash",
                message: ops.pendingTrash.map { ops.trashMessage(for: $0) } ?? "",
                confirmTitle: "Move to Trash",
                isDestructive: true) { ops.confirmTrash() }
            // A SECOND confirm dialog on the same view is safe where a second
            // `.sheet` would not be: `ainkradConfirmDialog` is an `.overlay`,
            // not a presentation, so the two cannot race the way the stacked
            // sheets documented above do. Only one can be armed at a time in
            // practice — a close refusal and a trash confirmation come from
            // different gestures.
            .ainkradConfirmDialog(
                isPresented: Binding(get: { ops.refusedClose != nil },
                                     set: { if !$0 { ops.refusedClose = nil } }),
                title: "Unsaved changes",
                message: ops.refusedCloseMessage,
                confirmTitle: "Close anyway",
                isDestructive: true) { ops.confirmForcedClose() }
    }
}

/// Carries `SidebarOperations.notice` into the toast host.
///
/// A zero-sized view rather than a modifier on `LoreRootView` because
/// `.ainkradToastHost()` injects its center into the subtree BELOW itself:
/// `LoreRootView`'s own `@Environment` is read above that injection and would
/// see a different, unrendered center — the exact trap the kit's own
/// `AinkradToastHostModifier` documents. Living inside the hosted subtree is
/// what makes `show` reach the center that is actually on screen.
///
/// Drains on change and CLEARS the notice, so the same message cannot be
/// re-shown by an unrelated redraw.
private struct LoreNoticeBridge: View {
    @Bindable var ops: SidebarOperations
    @Environment(\.ainkradToastCenter) private var toasts

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: ops.notice) { _, notice in
                guard let notice else { return }
                ops.notice = nil
                toasts.show(notice.text,
                            status: notice.kind == .success ? .success : .danger)
            }
    }
}

/// Resolves `activeSheet` to the right content.
struct SidebarOperationSheet: View {
    @Bindable var ops: SidebarOperations
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        switch ops.activeSheet {
        case .name:
            NameSheet(title: ops.nameTargetTitle, text: $ops.nameText, theme: theme,
                      onConfirm: { ops.commitName() }, onCancel: { ops.cancelName() })
        case .preview:
            if let preview = ops.preview {
                RenamePreviewSheet(preview: preview, report: ops.report, theme: theme,
                                   onConfirm: { ops.confirm() }, onCancel: { ops.dismiss() })
            }
        case .message:
            MessageSheet(text: ops.message ?? "", theme: theme) { ops.message = nil }
        case nil:
            EmptyView()
        }
    }
}

/// Asks for a new name. Nothing is planned until Continue: this collects text,
/// and the store decides whether the text is a NAME (see
/// `LoreStore.nameRejection`) — this sheet deliberately does not pre-judge it,
/// so there is exactly one place that rule lives.
struct NameSheet: View {
    let title: String
    @Binding var text: String
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text(title).font(AinkradFontResolver.font(.headline, typography: typo)).foregroundStyle(theme.tokens.foreground)
            TextField("New name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onConfirm)
            Text("You will see exactly what changes before anything is written.")
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            HStack {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                AinkradButton(title: "Continue", style: .primary, action: onConfirm)
            }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 420)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }
}

/// A refusal or failure the user must see. Exists because the alternative —
/// which is what shipped before this task — was `try?`.
struct MessageSheet: View {
    let text: String
    let theme: HostTheme
    @Environment(\.ainkradTypography) private var typo
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            Text("Not done").font(AinkradFontResolver.font(.headline, typography: typo)).foregroundStyle(theme.tokens.foreground)
            Text(text).foregroundStyle(theme.tokens.foreground.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); AinkradButton(title: "OK", style: .primary, action: onDismiss) }
        }
        .padding(AinkradSpacing.lg)
        .frame(width: 420)
        .background(theme.tokens.surface)
        .environment(\.ainkradTheme, theme.tokens)
    }
}

/// The document row menu, defined ONCE and used by both sidebar modes: a
/// destructive affordance that differs between two views is a destructive
/// affordance that was reviewed once.
///
/// Attachment rows (`.pdf`, `.xlsx`, anything no specific engine claims) get
/// Rename and Move but NO Delete, exactly as the previous milestone left them:
/// they are read-only, so this menu does not arm an irreversible delete
/// against a binary the user has no way to edit or reconstruct.
///
/// Built as `[AinkradMenuItem]` rather than a `View`: `.ainkradContextMenu(_:)`
/// (the kit's chamfer/hover-scan/`AinkradKbd` menu — see
/// `AinkradAppKit/Sources/AinkradAppKitUI/Components/AinkradContextMenu.swift`)
/// takes an item array, not a `@ViewBuilder`, so there is no `Button`/`Divider`
/// tree to build here. The kit has no divider primitive; the visual break
/// `Divider()` gave the destructive row is expressed instead by
/// `AinkradMenuItem.isDestructive`'s own tint, which is what the row-hover
/// design already leans on to separate "safe" actions from the trash one.
/// - Parameter store: Supplied only so the menu can offer Pin / Unpin, which
///   needs to know the CURRENT state to name itself. Optional so the existing
///   call sites that have no store to hand keep working unchanged — the item
///   is simply absent there, which is correct: a menu that cannot read the pin
///   state cannot label itself honestly either.
@MainActor
func loreRowMenuItems(row: IndexRow, ops: SidebarOperations,
                      store: LoreStore? = nil) -> [AinkradMenuItem] {
    var items: [AinkradMenuItem] = []
    if let store {
        let pinned = store.isPinned(row.path)
        items.append(AinkradMenuItem(title: pinned ? "Unpin" : "Pin",
                                     systemName: pinned ? "pin.slash" : "pin") {
            store.togglePinned(row.path)
        })
    }
    items += [
        AinkradMenuItem(title: "Rename…", systemName: "pencil") { ops.beginRename(row) },
        AinkradMenuItem(title: "Move to…", systemName: "folder") { ops.beginMove(row) },
    ]
    if row.type != AttachmentEngine.identifier {
        items.append(AinkradMenuItem(title: "Move to Trash", systemName: "trash",
                                     isDestructive: true) { ops.requestTrash(row) })
    }
    return items
}

/// The folder row menu. Create and trash reuse the same name-prompt and
/// preview machinery rename already uses — `beginNewFolder`/`requestTrashFolder`
/// on `SidebarOperations` — so a folder's three destructive-adjacent
/// affordances share one review surface instead of three.
@MainActor
func loreFolderMenuItems(folder: URL, ops: SidebarOperations) -> [AinkradMenuItem] {
    [
        AinkradMenuItem(title: "Rename Folder…", systemName: "pencil") {
            ops.beginRenameFolder(folder)
        },
        AinkradMenuItem(title: "New Folder…", systemName: "folder.badge.plus") {
            ops.beginNewFolder(in: folder)
        },
        AinkradMenuItem(title: "Move to Trash", systemName: "trash",
                        isDestructive: true) { ops.requestTrashFolder(folder) },
    ]
}

/// The empty-space / root menu: reachable with no subfolder yet or with the
/// tree fully collapsed, where no folder ROW exists to host `loreFolderMenuItems`
/// at all. Just the one action — root has nothing to rename or trash.
@MainActor
func loreRootMenuItems(root: URL, ops: SidebarOperations) -> [AinkradMenuItem] {
    [AinkradMenuItem(title: "New Folder…", systemName: "folder.badge.plus") {
        ops.beginNewFolder(in: root)
    }]
}

extension SidebarOperations {
    enum Sheet { case name, preview, message }

    /// Ordered by urgency, and mutually exclusive by construction: only one of
    /// these three states is ever set at a time by the flows above.
    var activeSheet: Sheet? {
        if nameTarget != nil { return .name }
        if preview != nil { return .preview }
        if message != nil { return .message }
        return nil
    }

    var nameTargetTitle: String {
        switch nameTarget {
        case .document(let url): "Rename “\(url.lastPathComponent)”"
        case .folder(let url): "Rename folder “\(url.lastPathComponent)”"
        case .newFolder: "New Folder"
        case nil: ""
        }
    }

    /// Dismissing the sheet must clear whichever state opened it — otherwise the
    /// same sheet reopens on the next render.
    func dismissAll() {
        cancelName()
        dismiss()
        message = nil
    }
}
