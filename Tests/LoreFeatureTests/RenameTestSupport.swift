import Foundation

@testable import LoreFeature

/// A fresh vault under the temp directory, named `<prefix>-<UUID>`, with a
/// `LoreStore` already pointed at it. Shared by the rename test classes.
@MainActor
func makeRenameVault(prefix: String) throws -> (URL, LoreStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let s = LoreStore(
        documents: FakeDocs(),
        indexPath: root.appendingPathComponent(".idx.sqlite"))
    try s.setVaultRootForTesting(root)
    return (root, s)
}

/// Writes `text` to `dir/name` and returns the file's URL.
@discardableResult
func writeRenameFixture(_ dir: URL, _ name: String, _ text: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}
