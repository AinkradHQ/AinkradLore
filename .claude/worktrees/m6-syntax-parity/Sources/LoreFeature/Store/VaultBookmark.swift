import Foundation
import AinkradAppKit

enum VaultBookmark {
    static let key = "vaultRootBookmark"

    static func save(_ url: URL, to documents: PluginDocumentStore) throws {
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        documents.setData(data, forKey: key)
    }

    static func resolve(from documents: PluginDocumentStore) -> URL? {
        guard let data = documents.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
