import Foundation

/// Turns a scanned selection of `ImportItem`s into an `ImportPlan` — target
/// paths, in-selection collision resolution, and already-imported markers.
///
/// Pure by construction: no filesystem access, no database, no actor, no
/// clock, no randomness. The preview re-runs `plan(...)` on every checkbox
/// toggle and hands the resulting `ImportPlan` straight to the applier, so
/// planning the same inputs twice must always produce the same output —
/// that equality is the entire dry-run promise. `nonCollidingURL` is
/// deliberately NOT used here: it resolves against files already on disk,
/// which is the applier's job (Task 11), not the planner's.
public enum ImportPlanner {
    public static func plan(items: [ImportItem],
                            vaultRoot: URL,
                            existingImportIDs: Set<String>) -> ImportPlan {
        var taken: Set<String> = []
        var planned: [PlannedItem] = []

        for item in items {
            let directory = containedDirectory(for: item.folderPath, under: vaultRoot)
            let stem = LoreStore.sanitized(item.title)
            let preferredName = stem + ".md"
            let firstChoice = directory.appendingPathComponent(preferredName)

            if existingImportIDs.contains(item.sourceID) {
                planned.append(PlannedItem(item: item, targetURL: firstChoice,
                                           disposition: .alreadyImported))
                continue
            }

            if taken.contains(firstChoice.path) {
                var candidate = firstChoice
                var counter = 2
                while taken.contains(candidate.path) {
                    candidate = directory.appendingPathComponent("\(stem) \(counter).md")
                    counter += 1
                }
                taken.insert(candidate.path)
                planned.append(PlannedItem(item: item, targetURL: candidate,
                                           disposition: .renamedToAvoidCollision(
                                               original: preferredName)))
            } else {
                taken.insert(firstChoice.path)
                planned.append(PlannedItem(item: item, targetURL: firstChoice,
                                           disposition: .create))
            }
        }
        return ImportPlan(items: planned)
    }

    /// Builds `vaultRoot/comp1/comp2/...` with every component sanitized AND
    /// guaranteed not to be a traversal segment.
    ///
    /// `LoreStore.sanitized` drops leading dots from a component and falls
    /// back to a fixed placeholder (`"attachment"`) when nothing is left —
    /// see its doc comment. That means a component of `"."` or `".."` can
    /// never survive sanitization as a literal `.`/`..`: both drop to empty
    /// and fall back, so `sanitized("..") == "attachment"`, not `".."`. That
    /// fallback is what actually keeps a `folderPath` of `["..", "..", "etc"]`
    /// from producing a traversal segment here.
    ///
    /// The `standardizedFileURL` prefix check below is the real backstop:
    /// it is what the planner's "never a target outside the vault root"
    /// guarantee actually rests on, independent of `sanitized`'s current
    /// behavior — if that fallback ever changed, this check still holds.
    private static func containedDirectory(for folderPath: [String], under vaultRoot: URL) -> URL {
        let directory = folderPath.reduce(vaultRoot) { partial, component in
            partial.appendingPathComponent(LoreStore.sanitized(component))
        }
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedRoot = vaultRoot.standardizedFileURL
        guard standardizedDirectory.path == standardizedRoot.path
            || standardizedDirectory.path.hasPrefix(standardizedRoot.path + "/")
        else {
            return vaultRoot
        }
        return directory
    }
}
