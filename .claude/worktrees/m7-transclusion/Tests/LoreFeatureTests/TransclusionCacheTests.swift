import XCTest
@testable import LoreFeature

@MainActor
final class TransclusionCacheTests: XCTestCase {

    private func key(_ name: String, mtime: TimeInterval = 0,
                     fragment: String? = nil) -> TransclusionKey {
        TransclusionKey(path: URL(fileURLWithPath: "/vault/\(name)"),
                        mtime: Date(timeIntervalSince1970: mtime),
                        fragment: fragment)
    }

    func test_missParses_hitDoesNot() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("a.md"), make: make)
        XCTAssertEqual(made, 1, "a cache hit re-parsed the target")
    }

    func test_mtimeBumpInvalidates() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md", mtime: 0), make: make)
        _ = cache.content(for: key("a.md", mtime: 1), make: make)
        XCTAssertEqual(made, 2, "an edited target served stale content")
    }

    func test_differentFragmentsOfOneFileAreDistinctEntries() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md", fragment: "one"), make: make)
        _ = cache.content(for: key("a.md", fragment: "two"), make: make)
        XCTAssertEqual(made, 2)
    }

    func test_invalidatingOnePathLeavesOthersAlone() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("b.md"), make: make)
        cache.invalidate(path: URL(fileURLWithPath: "/vault/a.md"))
        _ = cache.content(for: key("b.md"), make: make)
        XCTAssertEqual(made, 2, "an unrelated watcher event dropped a good entry")
    }

    func test_exceedingCapacityEvictsOldestAndReparsesOnNextAccess() {
        let cache = TransclusionCache(capacity: 2)
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("b.md"), make: make)
        _ = cache.content(for: key("c.md"), make: make) // pushes capacity to 3, should evict a.md
        XCTAssertEqual(made, 3)
        _ = cache.content(for: key("a.md"), make: make)
        XCTAssertEqual(made, 4, "an entry evicted under capacity pressure should be a miss on next access")
    }

    func test_evictionTakesLeastRecentlyUsedNotOldestInserted() {
        let cache = TransclusionCache(capacity: 2)
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make) // insert A
        _ = cache.content(for: key("b.md"), make: make) // insert B
        _ = cache.content(for: key("a.md"), make: make) // read A again -> A is now most-recent, B is least-recent
        XCTAssertEqual(made, 2, "re-reading A should have been a hit, not a re-parse")
        _ = cache.content(for: key("c.md"), make: make) // insert C, should evict B (least-recently-used), not A
        XCTAssertEqual(made, 3)

        _ = cache.content(for: key("a.md"), make: make)
        XCTAssertEqual(made, 3, "A was touched most recently and must still be cached, not evicted")

        _ = cache.content(for: key("b.md"), make: make)
        XCTAssertEqual(made, 4, "B was least-recently-used and should have been evicted")
    }

    func test_anExternalChangeToATargetInvalidatesItsEntries() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        let a = URL(fileURLWithPath: "/vault/a.md")
        let k = TransclusionKey(path: a, mtime: Date(timeIntervalSince1970: 0), fragment: nil)
        _ = cache.content(for: k, make: make)
        cache.invalidate(path: a)
        _ = cache.content(for: k, make: make)
        XCTAssertEqual(made, 2, "an external edit served stale embed content")
    }

    func test_measureWidthChangeDropsHeightsButKeepsContent() {
        let cache = TransclusionCache()
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        let k = TransclusionKey(path: URL(fileURLWithPath: "/vault/a.md"),
                                mtime: Date(timeIntervalSince1970: 0), fragment: nil)
        _ = cache.content(for: k, make: make)
        cache.invalidateMeasurements()
        _ = cache.content(for: k, make: make)
        XCTAssertEqual(made, 1, "a width change re-parsed content it already had")
    }

    func test_cacheHitDoesNotItselfTriggerEviction() {
        let cache = TransclusionCache(capacity: 2)
        var made = 0
        let make: () -> TransclusionContent = { made += 1; return .content("x") }
        _ = cache.content(for: key("a.md"), make: make)
        _ = cache.content(for: key("b.md"), make: make)
        XCTAssertEqual(made, 2)

        // Repeated hits on both entries, at capacity, must never evict either one.
        for _ in 0..<5 {
            _ = cache.content(for: key("a.md"), make: make)
            _ = cache.content(for: key("b.md"), make: make)
        }
        XCTAssertEqual(made, 2, "cache hits at capacity must not evict live entries")
    }
}
