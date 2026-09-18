import Foundation

/// Pinned documents — the sidebar's answer to "the handful I keep coming back
/// to".
///
/// ## Stored as paths, resolved against the live index
///
/// The set holds vault-relative paths, filtered through
/// `store.rows` before display. That is what keeps them honest across renames,
/// moves and deletes: a stale entry simply stops resolving and disappears,
/// rather than sitting in the sidebar as a row that errors when clicked. It
/// also means neither list needs updating when a file moves — the next render
/// just fails to resolve the old path.
///
/// The cost is that a RENAMED document falls out of the pinned set rather than
/// following its new name. That is the right trade for a list this size: the
/// alternative is another consumer of the rename plan, and a rename already
/// rewrites links across the whole vault without having to also patch a
/// preferences blob.
extension LoreStore {

    static let pinnedKey = "pinnedDocuments"

    // MARK: - Pinned

    public func isPinned(_ url: URL) -> Bool {
        pinnedPaths.contains(Self.pathKey(url))
    }

    public func togglePinned(_ url: URL) {
        let key = Self.pathKey(url)
        if pinnedPaths.contains(key) {
            pinnedPaths.remove(key)
        } else {
            pinnedPaths.insert(key)
        }
        persistPinned()
    }

    /// Pinned documents that still exist, in title order.
    ///
    /// Sorted by TITLE rather than by pin order: pinning is a set, not a
    /// sequence, and remembering the order someone pinned things in implies a
    /// meaning the UI never offered a way to change.
    public var pinnedRows: [IndexRow] {
        rows.filter { pinnedPaths.contains(Self.pathKey($0.path)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func persistPinned() {
        documents.setData(pinnedPaths.sorted().joined(separator: "\n").data(using: .utf8),
                          forKey: Self.pinnedKey)
    }

    /// Decodes the pinned set at startup.
    func loadShortcutLists() {
        if let data = documents.data(forKey: Self.pinnedKey),
           let text = String(data: data, encoding: .utf8) {
            pinnedPaths = Set(text.split(separator: "\n").map(String.init))
        }
    }
}
