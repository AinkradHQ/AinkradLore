import Foundation

/// Every persisted UI preference, and the keys they are stored under.
///
/// Split out of `LoreStore.swift` for the 500-line ceiling. These belong
/// together because they share one shape — mutate the property, write the same
/// value to `PluginDocumentStore` under a stable key — and because keeping the
/// keys beside their only readers is what stops a rename of one from silently
/// orphaning the other's stored data.
extension LoreStore {

    static let defaultFolderKey = "defaultNoteFolder"
    static let sidebarModeKey = "sidebarMode"
    static let expandedFoldersKey = "expandedFolders"
    static let backlinksPanelExpandedKey = "backlinksPanelExpanded"
    static let outlinePanelExpandedKey = "outlinePanelExpanded"
    static let showAllFilesKey = "showAllFiles"
    static let sidebarCollapsedKey = "sidebarCollapsed"
    static let editorSettingsKey = "editorSettings"
    static let sidebarWidthKey = "sidebarWidth"

    /// Persist the sidebar's width, clamped to a usable range.
    ///
    /// The clamp lives HERE rather than in the drag gesture so it holds for
    /// every writer, including a restored value from disk: a sidebar dragged
    /// to 20pt is a sliver with no visible content and no grip wide enough to
    /// drag back.
    public func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = LoreMetrics.clampSidebarWidth(width)
        documents.setData("\(sidebarWidth)".data(using: .utf8), forKey: Self.sidebarWidthKey)
    }

    /// Persist the editor's own display preferences.
    public func setEditorSettings(_ settings: EditorSettings) {
        editorSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            documents.setData(data, forKey: Self.editorSettingsKey)
        }
    }

    /// ⌘+ / ⌘− / ⌘0.
    public func zoomEditor(by step: Int) {
        setEditorSettings(editorSettings.zoomed(by: step))
    }

    public func resetEditorZoom() {
        setEditorSettings(editorSettings.zoomReset())
    }

    /// Persist the sidebar's folder-tree-vs-flat-list choice.
    public func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        documents.setData(mode.rawValue.data(using: .utf8), forKey: Self.sidebarModeKey)
    }

    /// Persist which folders are expanded in `FolderTreeView`.
    public func setExpandedFolders(_ folders: Set<String>) {
        expandedFolders = folders
        documents.setData(folders.sorted().joined(separator: "\n").data(using: .utf8),
                          forKey: Self.expandedFoldersKey)
    }

    /// Persist the backlinks panel's collapsed/expanded state.
    public func setBacklinksPanelExpanded(_ expanded: Bool) {
        backlinksPanelExpanded = expanded
        documents.setData((expanded ? "true" : "false").data(using: .utf8),
                          forKey: Self.backlinksPanelExpandedKey)
    }

    /// Persist the outline panel's collapsed/expanded state.
    public func setOutlinePanelExpanded(_ expanded: Bool) {
        outlinePanelExpanded = expanded
        documents.setData((expanded ? "true" : "false").data(using: .utf8),
                          forKey: Self.outlinePanelExpandedKey)
    }

    /// Persist the "Show all files" setting. Takes effect immediately: both
    /// `FolderTreeView` and `NoteListView` read `showAllFiles` live through
    /// `DocumentVisibility.visibleRows` on every redraw, so flipping this
    /// needs no reindex and no relaunch — the index never changes shape, only
    /// what of it gets drawn.
    public func setShowAllFiles(_ show: Bool) {
        showAllFiles = show
        documents.setData((show ? "true" : "false").data(using: .utf8),
                          forKey: Self.showAllFilesKey)
    }

    public func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarCollapsed = collapsed
        documents.setData((collapsed ? "1" : "0").data(using: .utf8),
                          forKey: Self.sidebarCollapsedKey)
    }
    /// Persist the default new-note subfolder (relative to the vault root).
    public func setDefaultNoteFolder(_ relative: String) {
        defaultNoteFolder = relative
        documents.setData(relative.data(using: .utf8), forKey: Self.defaultFolderKey)
    }
}
