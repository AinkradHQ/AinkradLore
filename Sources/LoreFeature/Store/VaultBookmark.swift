import AinkradAppKit
import Foundation

enum VaultBookmark {
    static let key = "vaultRootBookmark"

    static func save(_ url: URL, to documents: PluginDocumentStore) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        documents.setData(data, forKey: key)
    }

    static func resolve(from documents: PluginDocumentStore) -> URL? {
        guard let data = documents.data(forKey: key) else { return nil }
        var stale = false
        guard
            let url = Log.store.orNil(
                "resolve the vault bookmark",
                {
                    try URL(
                        resolvingBookmarkData: data, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
                })
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    #if DEBUG
    /// `-LoreFixtureVault <path>` (Debug only): open that folder as the vault,
    /// unbookmarked, so a fixture-rooted Debug host can be shot on a known vault
    /// (`Designs/parity/AinkradLore/fixture/LoreVault`) with no folder panel.
    static func debugFixtureVault(
        _ value: (String) -> String? = { UserDefaults.standard.string(forKey: $0) }
    ) -> URL? {
        guard let raw = value("LoreFixtureVault")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.store.error("LoreFixtureVault '\(url.path, privacy: .public)' is not a directory")
            return nil
        }
        return url
    }
    #endif
}
