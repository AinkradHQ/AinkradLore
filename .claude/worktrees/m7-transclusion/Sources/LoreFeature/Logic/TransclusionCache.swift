import Foundation

/// Identifies one cached embed target: the file it came from, that file's
/// mtime at the time it was read, and the fragment (heading/block) sliced
/// out of it, if any. Two different fragments of the same file are distinct
/// entries; a bumped mtime makes an old entry unreachable by key, so the
/// cache never has to actively scan for staleness.
public struct TransclusionKey: Hashable, Sendable {
    public let path: URL
    public let mtime: Date
    public let fragment: String?

    public init(path: URL, mtime: Date, fragment: String?) {
        self.path = path
        self.mtime = mtime
        self.fragment = fragment
    }
}

/// Counts embed measurements. Declared here so the cache and the eventual
/// measurement site (Task 5) share one counter type; `record()` is called
/// from exactly one place, added in Task 5 — not from this file.
@MainActor
public enum TransclusionMeasureCounter {
    public static private(set) var count = 0

    public static func reset() {
        count = 0
    }

    public static func record() {
        count += 1
    }
}

/// One measured embed height, TOGETHER WITH the geometry it was measured at.
///
/// The geometry travels with the number because a height is only true for the
/// width and type metrics it was laid out against: `TransclusionLayout` wraps
/// at `width - 2 * framePadding` and sizes from the theme's `bodySize` and
/// `lineHeightMultiple`. `TransclusionKey` carries none of those — it is
/// (path, mtime, fragment) — so a cache keyed on it alone would hand back a
/// height measured at the old window width after a resize, and the content
/// would re-wrap inside a gap sized for a different measure. That is the exact
/// defect this milestone exists to prevent, and an ordinary window resize
/// reaches it.
///
/// So the reader COMPARES: a measurement whose geometry does not match the one
/// being asked about is a MISS, and the caller re-measures. Correctness is
/// therefore self-correcting, the way `MarkdownTableStyling.prepare` is by
/// re-measuring at `maxWidth` every render — it does not depend on every
/// future site that can change the width remembering to call
/// `invalidateMeasurements()`. That call remains, and Task 7 still wires it,
/// but it is now an optimisation (drop work known to be stale early) rather
/// than the mechanism that makes the cache correct.
public struct TransclusionMeasurement: Equatable, Sendable {
    public let height: CGFloat
    /// The OUTER width passed to `TransclusionLayout`, before frame padding.
    public let width: CGFloat
    public let bodySize: CGFloat
    public let lineHeightMultiple: CGFloat

    public init(height: CGFloat, width: CGFloat,
                bodySize: CGFloat, lineHeightMultiple: CGFloat) {
        self.height = height
        self.width = width
        self.bodySize = bodySize
        self.lineHeightMultiple = lineHeightMultiple
    }

    /// Whether this measurement describes `other`'s geometry — i.e. whether
    /// its height may be reused for it.
    public func matchesGeometry(of other: TransclusionMeasurement) -> Bool {
        width == other.width && bodySize == other.bodySize
            && lineHeightMultiple == other.lineHeightMultiple
    }
}

/// An LRU cache of resolved embed content, keyed by `TransclusionKey`.
///
/// Two independent things are cached per entry: the parsed `TransclusionContent`
/// (expensive: a full re-parse of the target note) and an optional
/// `TransclusionMeasurement` (expensive in a different way: a full second
/// layout pass). They're stored together in one `Entry` rather than two
/// parallel caches, because they always share a key and a lifetime — a `mtime`
/// bump invalidates both, a path invalidation drops both. Only the
/// *measurement* half needs its own narrower invalidation
/// (`invalidateMeasurements()`), which the measure-width and theme-change
/// triggers use because they never change what a target's content is, only how
/// tall it renders — and, since `TransclusionMeasurement` carries its own
/// geometry, a missed invalidation costs a re-measure rather than a wrong gap.
@MainActor
public final class TransclusionCache {
    private struct Entry {
        var content: TransclusionContent
        var measurement: TransclusionMeasurement?
    }

    private let capacity: Int
    private var storage: [TransclusionKey: Entry] = [:]
    /// Most-recently-used keys, back to front (front = least recently used).
    private var order: [TransclusionKey] = []

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Returns the cached content for `key`, computing and storing it via
    /// `make()` on a miss. A hit never calls `make`.
    public func content(for key: TransclusionKey, make: () -> TransclusionContent) -> TransclusionContent {
        if let entry = storage[key] {
            touch(key)
            return entry.content
        }
        let content = make()
        storage[key] = Entry(content: content, measurement: nil)
        touch(key)
        evictIfNeeded()
        return content
    }

    /// The height already measured for `key` AT `geometry`'s width and type
    /// metrics, or `nil` when there is none.
    ///
    /// A stored measurement taken at a DIFFERENT geometry is a miss, not a
    /// hit: reusing it would reserve a gap sized for a window the reader is no
    /// longer looking at. See `TransclusionMeasurement`.
    public func measuredHeight(for key: TransclusionKey,
                               matching geometry: TransclusionMeasurement) -> CGFloat? {
        guard let stored = storage[key]?.measurement,
              stored.matchesGeometry(of: geometry) else { return nil }
        return stored.height
    }

    /// Records a measurement against an EXISTING entry. Silently does nothing
    /// when there is no entry — a height with no content to belong to would be
    /// unreachable anyway, and inventing an entry for it would need a
    /// `TransclusionContent` this call does not have.
    public func setMeasurement(_ measurement: TransclusionMeasurement,
                               for key: TransclusionKey) {
        guard storage[key] != nil else { return }
        storage[key]?.measurement = measurement
        touch(key)
    }

    /// Drops every entry whose key's `path` matches `path`, regardless of
    /// mtime or fragment — used when a file watcher reports a change but the
    /// exact new mtime isn't known to the caller yet.
    public func invalidate(path: URL) {
        let staleKeys = storage.keys.filter { $0.path == path }
        for key in staleKeys {
            storage.removeValue(forKey: key)
        }
        order.removeAll { staleKeys.contains($0) }
    }

    /// Drops measured heights only, keeping parsed content. Serves the
    /// measure-width and theme-change triggers, which change how tall an
    /// embed renders but never what its content is — so re-parsing on those
    /// triggers would be pure waste.
    ///
    /// An OPTIMISATION, not the correctness mechanism: a measurement carries
    /// the geometry it was taken at, so one that survives a width change is
    /// already ignored by `measuredHeight(for:matching:)`. This call just
    /// stops the stale bytes being carried around.
    public func invalidateMeasurements() {
        for key in storage.keys {
            storage[key]?.measurement = nil
        }
    }

    private func touch(_ key: TransclusionKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, !order.isEmpty {
            let lruKey = order.removeFirst()
            storage.removeValue(forKey: lruKey)
        }
    }
}
