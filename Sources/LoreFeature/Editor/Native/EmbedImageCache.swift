import AppKit

/// Decoded embed images, keyed like `ExtractionCache` — `(canonical path,
/// mtime, size)` — for the same reason that cache exists: a style pass runs
/// on every keystroke, every ancestor redraw and every selection change, and
/// `NSImage(contentsOf:)` is a disk read plus a decode. Without this, opening
/// a note with a handful of screenshots would re-decode every one of them on
/// every caret move — the exact per-render regression `MarkdownStylingBenchmark`
/// exists to catch.
///
/// `@unchecked Sendable` with an `NSLock`, for the same reason `ExtractionCache` is:
/// nothing here touches AppKit's main-actor state, only a private dictionary.
final class EmbedImageCache: @unchecked Sendable {
    static let shared = EmbedImageCache()
    static let maxEntries = 256

    private struct Key: Hashable {
        let path: String
        let mtime: TimeInterval
        let size: Int
    }

    private let lock = NSLock()
    /// `NSImage?` as the VALUE, not just the presence of a key: a file that
    /// fails to decode is cached as a miss too, so a broken image is retried
    /// only when the file itself changes (a new mtime/size), never on every
    /// render in between.
    private var storage: [Key: NSImage?] = [:]
    private var order: [Key] = []

    private init() {}

    func image(for url: URL) -> NSImage? {
        guard let key = Self.key(for: url) else { return NSImage(contentsOf: url) }
        lock.lock()
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Decoding runs OUTSIDE the lock, exactly as `ExtractionCache.result`
        // does: it is the slow part this cache exists to avoid paying twice,
        // and holding a lock across it would serialize every embed's decode.
        let decoded = NSImage(contentsOf: url)

        lock.lock()
        defer { lock.unlock() }
        if storage[key] == nil {
            storage[key] = decoded
            order.append(key)
            while order.count > Self.maxEntries {
                storage.removeValue(forKey: order.removeFirst())
            }
        }
        return decoded
    }

    private static func key(for url: URL) -> Key? {
        // `try?`: a probe — no stat means no key, and the caller decodes uncached.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = attrs[.modificationDate] as? Date,
            let size = attrs[.size] as? Int
        else { return nil }
        return Key(path: url.path, mtime: mtime.timeIntervalSince1970, size: size)
    }
}
