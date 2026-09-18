import Foundation

/// Caches extracted document text, keyed by `(canonical path, mtime, size)`.
///
/// Without it, every full rescan re-runs PDFKit and AppKit text extraction over
/// every PDF and Word file in the vault — the single most expensive thing M3
/// introduces, and entirely wasted on files that have not changed. A rebuild
/// after a one-note edit should cost one extraction, not hundreds.
///
/// Bounded, and evicted oldest-first: an unbounded cache over a vault of large
/// documents is a memory leak with extra steps.
///
/// `@unchecked Sendable` with an `NSLock`: `scanVault` is `nonisolated` and runs
/// off the main actor, so this is reached concurrently by design.
public final class ExtractionCache: @unchecked Sendable {
    public static let shared = ExtractionCache()
    public static let maxEntries = 512

    /// What gets cached for one file: the capped text AND whether extraction
    /// truncated it.
    ///
    /// Both engines derive `isContentTruncated` by comparing the raw extracted
    /// text against the capped text — a comparison that is only possible at
    /// the moment of extraction, because the raw text is discarded immediately
    /// after (holding a 900-page PDF's full text resident just to answer a
    /// boolean would defeat the cap). If the cache stored only the capped
    /// string, a cache HIT would have no raw text to compare against, and a
    /// truncated document would silently start reporting
    /// `isContentTruncated == false` on the second scan — a truthful flag
    /// going quietly wrong. Caching the flag alongside the text, computed once
    /// at extraction time, is what keeps it truthful on every subsequent hit.
    public struct ExtractionResult: Sendable {
        public let text: String
        public let isTruncated: Bool

        public init(text: String, isTruncated: Bool) {
            self.text = text
            self.isTruncated = isTruncated
        }
    }

    private struct Key: Hashable {
        let path: String
        let mtime: TimeInterval
        let size: Int
    }

    private let lock = NSLock()
    private var storage: [Key: ExtractionResult] = [:]
    /// Insertion order, for oldest-first eviction.
    private var order: [Key] = []

    private init() {}

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }

    /// Returns the cached text for `url`, or runs `extract` and caches it.
    ///
    /// Convenience over `result(for:extract:)` for callers that have no
    /// truncation flag to preserve (and for the plain-string cache-behavior
    /// test). The result is still stored keyed by file identity, in the SAME
    /// underlying table `result(for:extract:)` reads and writes, so a hit
    /// here and a hit there share one entry per file.
    public func text(for url: URL, extract: () -> String) -> String {
        result(for: url) { ExtractionResult(text: extract(), isTruncated: false) }.text
    }

    /// Returns the cached extraction (text + truncation flag) for `url`, or
    /// runs `extract` and caches what it returns.
    ///
    /// A file whose attributes cannot be read is NOT cached — it is extracted
    /// every time. That is the safe direction: caching under a degenerate key
    /// would serve one file's text for another's.
    public func result(for url: URL, extract: () -> ExtractionResult) -> ExtractionResult {
        guard let key = Self.key(for: url) else { return extract() }
        lock.lock()
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Extraction runs OUTSIDE the lock: it is the slow operation this class
        // exists to avoid, and holding a global lock across it would serialize
        // the whole rescan. Two threads racing the same new file both extract,
        // and the second write is identical — wasteful once, never wrong.
        let value = extract()

        lock.lock(); defer { lock.unlock() }
        if storage[key] == nil {
            storage[key] = value
            order.append(key)
            while order.count > Self.maxEntries {
                storage.removeValue(forKey: order.removeFirst())
            }
        }
        return value
    }

    private static func key(for url: URL) -> Key? {
        let path = VaultIndexCoordinator.canonical(url).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return Key(path: path, mtime: mtime.timeIntervalSince1970, size: size)
    }
}
