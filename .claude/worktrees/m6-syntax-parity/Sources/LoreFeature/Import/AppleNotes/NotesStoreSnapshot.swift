import Foundation

/// A private copy of Apple's Notes database, safe to read while Notes is
/// running.
///
/// Notes keeps the store open in WAL mode. Reading it in place can observe a
/// torn page or block on a writer lock; worse, copying the `.sqlite` file
/// WITHOUT its `-wal` sidecar silently drops every committed-but-not-
/// checkpointed write — which is to say, the user's most recent notes. All
/// three files travel together.
///
/// That failure mode is why this type exists at all rather than being a
/// convenience: it would present as a *successful* migration that happened to
/// be missing whatever the user wrote most recently, which is both the least
/// likely thing to be noticed and the most likely thing to be missed.
public final class NotesStoreSnapshot {
    public let url: URL
    private let directory: URL

    public init(copying storeURL: URL) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-notes-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let name = storeURL.lastPathComponent
        url = directory.appendingPathComponent(name)

        let source = storeURL.deletingLastPathComponent()
        // The main file is required; the sidecars are not. A store that has
        // been checkpointed and closed cleanly has no `-wal` at all, and
        // demanding one would refuse to read a perfectly good database.
        for suffix in ["", "-wal", "-shm"] {
            let from = source.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(
                at: from, to: directory.appendingPathComponent(name + suffix))
        }
    }

    /// The copy is scratch space, not user data — it exists for the duration
    /// of one scan and nothing else refers to it.
    deinit { try? FileManager.default.removeItem(at: directory) }
}
