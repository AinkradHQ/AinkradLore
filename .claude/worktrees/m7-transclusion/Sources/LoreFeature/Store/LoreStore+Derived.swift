import Foundation

/// Collections DERIVED from the index rather than stored: the tag vocabulary,
/// how often each tag is used, and the vault's immediate subfolders.
///
/// Split out of `LoreStore.swift` for the 500-line ceiling. They belong
/// together because they share a property easy to lose sight of — every one is
/// recomputed on READ, from `rows` or from disk, so a caller that touches one
/// inside a SwiftUI `body` pays for it on every redraw.
extension LoreStore {

    /// Every distinct tag across all indexed notes, sorted — drives the sidebar
    /// tag-filter chips.
    public var allTags: [String] { Array(Set(rows.flatMap(\.tags))).sorted() }

    /// How many notes carry each tag.
    ///
    /// Computed with `allTags` rather than separately: both walk every row's
    /// tag list, and the chip row reads them together on the same render.
    public var tagCounts: [String: Int] {
        rows.reduce(into: [:]) { counts, row in
            for tag in row.tags { counts[tag, default: 0] += 1 }
        }
    }

    /// Immediate subdirectories of the vault root (dotfiles excluded) — the
    /// choices offered for `defaultNoteFolder` in Settings.
    public var subfolders: [String] {
        guard let root = vaultRoot else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
