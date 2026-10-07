import Foundation

// The path keys and disk probes the rename paths share, split from
// `LoreStore+Rename.swift` to keep it under the 500-line ceiling.
extension LoreStore {
    /// THE key for every path-keyed dictionary and set in the rename paths.
    ///
    /// Nothing may key off a raw `url.path`. Since Task 8b, **every path stored
    /// in the index is canonical** — the invariant is enforced at the store
    /// boundary (`LoreIndex.canonical(_:)`, applied in `LoreIndex.write`) and
    /// upstream in `activate`, `scanVault` and `indexDocument`, so index rows,
    /// `vaultRoot`, session URLs, plan sources and plan destinations now all
    /// carry ONE spelling. Read that doc comment for the mechanism
    /// (`/tmp` vs `/private/tmp`) and the three silent M1 failures it caused.
    ///
    /// This function therefore is no longer load-bearing for anything the store
    /// writes — it is deliberate belt-and-braces for what a CALLER can
    /// construct. `RenamePlan` and `LinkEdit` are caller-built, so Task 10's preview
    /// UI can hand `apply` an edit file spelled however it likes; keyed raw, a
    /// set membership test then misses and the consequence is silent (an edit
    /// dropped from the plan, a dirty tab's file written anyway) because a
    /// missing key looks exactly like "nothing to do". Routing both sides of
    /// every comparison through one function keeps that unrepresentable at the
    /// boundary the invariant does not reach.
    /// Covered by `LinkRewriterTests.test_dirtyTabBlocksTheRewriteEvenWhenTheIndexSpellsTheFileDifferently`.
    static func pathKey(_ url: URL) -> String {
        VaultIndexCoordinator.canonical(url).path
    }

    /// Plan-time mtimes for every file an operation will write. Shared by
    /// single-document and folder planning so both get requirement 2.
    static func baselines(for files: [URL]) -> [String: Date] {
        var baselines: [String: Date] = [:]
        for file in files { baselines[pathKey(file)] = mtimeOnDisk(file) }
        return baselines
    }

    /// `realpath(3)` fails on a path that does not exist yet — and a rename
    /// destination never exists yet. A folder rename compounds this: the
    /// destination's PARENT directory does not exist yet either (that
    /// directory is exactly what "rename the folder" creates), so
    /// canonicalizing only the immediate parent still fails and hands back
    /// an unresolved path. That unresolved path's root prefix (`/var/...`)
    /// then fails to match the already-canonical vault root (`/private/var
    /// /...`) inside `LinkRewriter.vaultRelativePath`, and every explicit-path
    /// or explicit-extension inbound link for that document is dropped as
    /// "outside the vault" — silently, since a caller sees an empty edit
    /// list rather than an error. So this walks UP to the nearest ancestor
    /// that actually exists, canonicalizes only that, and re-appends every
    /// component below it — however many levels of not-yet-created
    /// directory that is.
    static func canonicalizingDestination(_ destination: URL) -> URL {
        var existingAncestor = destination.deletingLastPathComponent()
        var trailingComponents: [String] = [destination.lastPathComponent]
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
            existingAncestor.pathComponents.count > 1
        {
            trailingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        return trailingComponents.reduce(VaultIndexCoordinator.canonical(existingAncestor)) {
            $0.appendingPathComponent($1)
        }
    }

    static func mtimeOnDisk(_ url: URL) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// True when `a` and `b` name the SAME on-disk file — by inode and
    /// device number, not by comparing path text. This is the ONLY reliable
    /// way to tell "a case-only rename target, same file" apart from "a
    /// different file whose name happens to collide case-insensitively":
    /// see the caller's doc comment (Minor E). `false` whenever either
    /// attribute read fails (including "`b` does not exist yet", the common
    /// case for an ordinary, non-colliding rename) — failing closed here
    /// means an unreadable attribute is treated as "not proven the same
    /// file", never as "assume it's fine, skip the collision guard".
    static func sameFileOnDisk(_ a: URL, _ b: URL) -> Bool {
        guard let attrsA = try? FileManager.default.attributesOfItem(atPath: a.path),
            let attrsB = try? FileManager.default.attributesOfItem(atPath: b.path),
            let inodeA = attrsA[.systemFileNumber] as? Int,
            let inodeB = attrsB[.systemFileNumber] as? Int,
            let deviceA = attrsA[.systemNumber] as? Int,
            let deviceB = attrsB[.systemNumber] as? Int
        else { return false }
        return inodeA == inodeB && deviceA == deviceB
    }
}
