import AinkradAppKit
import Foundation
import Testing

@testable import LoreFeature

private final class MemoryDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

/// A temp vault, with a `LoreStore` already active over it and its initial
/// (empty) background rescan settled — see `LoreNoteOperationsTests.makeVault`
/// for the harness this reuses.
@MainActor
private func makeVault() async throws -> (URL, LoreStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-fp-\(UUID())", isDirectory: true)
        .appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(
        documents: MemoryDocs(),
        indexPath: root.appendingPathComponent(".index.sqlite"))
    try store.setVaultRootForTesting(root)
    await store.settleForTesting()
    return (root, store)
}

@discardableResult
private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct VaultFingerprintTests {

    /// The base case: after a full index, the cheap walk and the index's own
    /// stored fingerprints agree exactly. If they don't, nothing else in this
    /// suite can be trusted either.
    @Test func fingerprintsMatchAfterAFullIndex() async throws {
        let (root, store) = try await makeVault()
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nworld")
        try store.rebuild()

        let onDisk = VaultIndexCoordinator.scanFingerprints(at: root)
        let index = try #require(store.coordinator.indexForTesting)
        let indexed = try index.fingerprints()
        #expect(onDisk == indexed)
        #expect(onDisk.count == 2)
    }

    /// A note's content (and so its mtime/size) changing must change its
    /// fingerprint — the exact signal the fast path relies on to notice it.
    ///
    /// Looked up by the CANONICAL path, not the raw temp URL: `scanFingerprints`
    /// canonicalizes its root (`Self.canonical(root)`, mirroring `scanVault`),
    /// so on macOS (where `/var` is itself a symlink into `/private`) every key
    /// in its result is spelled `/private/var/...` while a naively-built temp
    /// URL is `/var/...` — a raw-path lookup would silently miss and both
    /// sides would read `nil`, making this test pass vacuously.
    @Test func aModifiedFileChangesItsFingerprint() async throws {
        let (root, store) = try await makeVault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try store.rebuild()
        let canonicalPath = VaultIndexCoordinator.canonical(a).path
        let before = VaultIndexCoordinator.scanFingerprints(at: root)[canonicalPath]
        #expect(before != nil)

        // Nudge the mtime forward explicitly: a rewrite within the same
        // filesystem-mtime tick would otherwise make this test flaky.
        try "---\nid: a\ntitle: A\n---\nhello, much longer now, with more bytes"
            .write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: a.path)

        let after = VaultIndexCoordinator.scanFingerprints(at: root)[canonicalPath]
        #expect(after != nil)
        #expect(before != after)
    }

    @Test func anAddedFileAppears() async throws {
        let (root, store) = try await makeVault()
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try store.rebuild()
        #expect(VaultIndexCoordinator.scanFingerprints(at: root).count == 1)

        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nworld")
        #expect(VaultIndexCoordinator.scanFingerprints(at: root).count == 2)
    }

    @Test func aRemovedFileDisappears() async throws {
        let (root, store) = try await makeVault()
        let a = try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nworld")
        try store.rebuild()
        #expect(VaultIndexCoordinator.scanFingerprints(at: root).count == 2)

        try FileManager.default.removeItem(at: a)
        #expect(VaultIndexCoordinator.scanFingerprints(at: root).count == 1)
    }

    /// The test that stops `scanVault` and `scanFingerprints` drifting apart:
    /// both must apply IDENTICAL skip rules, or the fast path (which trusts
    /// `scanFingerprints` alone) can decide "unchanged" while `scanVault` would
    /// have indexed something different.
    @Test func scanFingerprintsAppliesTheSameSkipRulesAsScanVault() async throws {
        let (root, _) = try await makeVault()
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        let dotDir = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
        try write(dotDir, "workspace.json", "{}")

        let scanned = VaultIndexCoordinator.scanVault(at: root)
        let fingerprints = VaultIndexCoordinator.scanFingerprints(at: root)

        #expect(scanned.count == 1, "scanVault must ignore the dot-directory")
        #expect(fingerprints.count == 1, "scanFingerprints must ignore the dot-directory too")
        #expect(!fingerprints.keys.contains { $0.contains(".obsidian") })
    }

    /// The behavioural case: an unchanged vault skips the rebuild entirely.
    /// `rebuildsPerformedForTesting` is the seam the brief calls for — there is
    /// no other clean way to assert "no re-parse happened" without asserting
    /// on timing.
    ///
    /// The watcher is suppressed for the whole test: these are raw
    /// `FileManager` writes to a REAL directory, so a live `FolderWatcher`
    /// would fire its own asynchronous `startBackgroundRebuild()` from FSEvents
    /// alongside the explicit calls below, racing the counter this test reads.
    /// Existing tests never noticed this noise because nothing else counted
    /// background rebuild invocations; this one does, so it has to shut the
    /// watcher out to get a deterministic answer.
    @Test func anUnchangedVaultSkipsTheRebuild() async throws {
        let (root, store) = try await makeVault()
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try store.rebuild()
        let before = store.coordinator.rebuildsPerformedForTesting

        store.rebuildInBackground()
        await store.settleForTesting()

        #expect(
            store.coordinator.rebuildsPerformedForTesting == before,
            "an unchanged vault triggered a full rescan")
    }

    /// A content-only edit re-indexes just that file: no full rescan, the new
    /// text is searchable, and a link from the edited note still resolves.
    @Test func aContentEditIsReindexedIncrementally() async throws {
        let (root, store) = try await makeVault()
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nsee [[A]]")
        try store.rebuild()
        let full = store.coordinator.rebuildsPerformedForTesting

        try await Task.sleep(for: .milliseconds(20))  // a distinct mtime
        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nsee [[A]] zorkmid")
        store.rebuildInBackground()
        await store.settleForTesting()

        #expect(
            store.coordinator.rebuildsPerformedForTesting == full,
            "a content edit took the full rescan")
        #expect(store.coordinator.incrementalRebuildsForTesting == 1)
        #expect(store.search("zorkmid").map(\.title) == ["B"])
        let a = try #require(store.rows.first { $0.title == "A" })
        #expect(store.coordinator.backlinkRows(to: a.path).map(\.title) == ["B"])
    }

    /// A changed title can re-point links in OTHER notes, so it is not an
    /// "edit only" — it must take the full rebuild.
    @Test func aTitleChangeStillRebuildsFully() async throws {
        let (root, store) = try await makeVault()
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try store.rebuild()
        let full = store.coordinator.rebuildsPerformedForTesting

        try await Task.sleep(for: .milliseconds(20))
        try write(root, "a.md", "---\nid: a\ntitle: Renamed\n---\nhello")
        store.rebuildInBackground()
        await store.settleForTesting()

        #expect(store.coordinator.rebuildsPerformedForTesting == full + 1)
        #expect(store.coordinator.incrementalRebuildsForTesting == 0)
        #expect(store.rows.map(\.title) == ["Renamed"])
    }

    /// A CHANGED vault must still take the full rebuild path.
    @Test func aChangedVaultStillRebuilds() async throws {
        let (root, store) = try await makeVault()
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try store.rebuild()
        let before = store.coordinator.rebuildsPerformedForTesting

        try write(root, "b.md", "---\nid: b\ntitle: B\n---\nworld")
        store.rebuildInBackground()
        await store.settleForTesting()

        #expect(
            store.coordinator.rebuildsPerformedForTesting == before + 1,
            "an added file did not trigger a full rescan")
        #expect(store.rows.count == 2)
    }

    /// THE PRODUCTION SHAPE, which no other test reproduces: a populated index
    /// plus a FRESH coordinator whose in-memory `directoryPaths` is still empty,
    /// exactly as it is in a new process. The first version of this feature
    /// passed every other test and was a complete no-op in the field because of
    /// this gap.
    @Test func aFreshCoordinatorWithAPopulatedIndexStillSkipsTheRebuild() async throws {
        let (root, store) = try await makeVault()
        let indexPath = root.appendingPathComponent(".index.sqlite")
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        try store.rebuild()
        #expect(!store.coordinator.directoryPaths.isEmpty)

        // A SECOND, brand-new coordinator over the SAME index path — the
        // production shape of a fresh process opening an already-indexed
        // vault. Its `directoryPaths` starts empty, same as `activate`
        // leaves it in every real launch.
        let freshStore = LoreStore(documents: MemoryDocs(), indexPath: indexPath)
        freshStore.coordinator.suppressWatcher(for: 60)
        try freshStore.setVaultRootForTesting(root)
        #expect(
            freshStore.coordinator.directoryPaths.isEmpty,
            "the fresh coordinator's in-memory directoryPaths must start empty, or this test isn't reproducing the production shape"
        )
        await freshStore.settleForTesting()

        #expect(
            freshStore.coordinator.rebuildsPerformedForTesting == 0,
            "a fresh coordinator over an already-indexed, unchanged vault performed a full rescan")
        #expect(
            !freshStore.coordinator.directoryPaths.isEmpty,
            "the fast-path hit must still publish the persisted directory set into memory")
    }

    /// A directory whose NAME CONTAINS A COMMA must survive the round-trip.
    /// Comma-joining silently split such a path into two entries, so the stored
    /// set could never equal the scanned set and the fast path was permanently
    /// dead for any vault with a comma in a folder name — which is not exotic.
    @Test func aDirectoryNameContainingACommaRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-fp-\(UUID())", isDirectory: true)
            .appendingPathComponent("vault", isDirectory: true)
        let commaDir = root.appendingPathComponent(
            "Sessions/2026-07-18 sweep — closed #245, shipped #285", isDirectory: true)
        try FileManager.default.createDirectory(at: commaDir, withIntermediateDirectories: true)

        let index = try LoreIndex(
            path: root.deletingLastPathComponent()
                .appendingPathComponent(".index-\(UUID()).sqlite"))
        let scanned = Set(VaultIndexCoordinator.scanDirectories(under: root))
        try index.setIndexedDirectories(scanned)

        let roundTripped = try #require(try index.indexedDirectories())
        #expect(roundTripped == scanned)
        #expect(roundTripped.count == scanned.count)
        #expect(roundTripped.contains { $0.contains("closed #245, shipped #285") })
    }

    /// The fast-path behavioural case for the same bug: an unchanged vault
    /// containing a comma-in-name directory must still skip the rebuild, not
    /// just round-trip in isolation.
    @Test func anUnchangedVaultWithACommaInADirectoryNameStillSkipsTheRebuild() async throws {
        let (root, store) = try await makeVault()
        store.coordinator.suppressWatcher(for: 60)
        try write(root, "a.md", "---\nid: a\ntitle: A\n---\nhello")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "Sessions/2026-07-18 sweep — closed #245, shipped #285", isDirectory: true),
            withIntermediateDirectories: true)
        try store.rebuild()
        let before = store.coordinator.rebuildsPerformedForTesting

        store.rebuildInBackground()
        await store.settleForTesting()

        #expect(
            store.coordinator.rebuildsPerformedForTesting == before,
            "an unchanged vault with a comma in a directory name triggered a full rescan")
    }
}
