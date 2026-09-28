import XCTest
@testable import LoreFeature

/// Not a correctness test — a measurement, so the Wave 2 claim about the
/// whole-vault rescan is a number rather than an assertion about the source.
/// Run with `-only-testing:LoreFeatureTests/LoreRebuildBenchmark`.
@MainActor
final class LoreRebuildBenchmark: XCTestCase {

    func testMeasureRebuildStrategies() throws {
        let noteCount = 400   // enough to show the difference; keeps `make test` fast
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<noteCount {
            try "---\ntitle: Note \(i)\ntags: [a, b]\n---\n\(String(repeating: "body text ", count: 40))\n"
                .write(to: root.appendingPathComponent("n\(i).md"), atomically: true, encoding: .utf8)
        }
        let notes = VaultIndexCoordinator.scanVault(at: root)
        XCTAssertEqual(notes.count, noteCount)

        // OLD: one write transaction per note, then one per pruned row.
        let oldIndex = try LoreIndex(path: root.appendingPathComponent("old.sqlite"))
        let oldStart = Date()
        for note in notes { try oldIndex.upsert(note) }
        let oldElapsed = Date().timeIntervalSince(oldStart)

        // NEW: a single transaction for the whole vault.
        let newIndex = try LoreIndex(path: root.appendingPathComponent("new.sqlite"))
        let newStart = Date()
        try newIndex.replaceAll(with: notes)
        let newElapsed = Date().timeIntervalSince(newStart)

        print("""

        ── Lore rescan, \(noteCount) notes ──────────────────────────────
          per-note transactions (old): \(String(format: "%.3f", oldElapsed))s
          single transaction   (new): \(String(format: "%.3f", newElapsed))s
          speedup: \(String(format: "%.1f", oldElapsed / max(newElapsed, 0.0001)))x
        ────────────────────────────────────────────────────────────────

        """)
        XCTAssertEqual(try newIndex.all().count, noteCount)
    }
}
