import Foundation

/// What kind of raw-text region a `CodeRegion` came from.
///
/// Kinds exist because "is this code?" has two different right answers depending
/// on who is asking. A styler wants every raw-text region. The LINK GRAPH wants
/// only the regions the old hand-written scanner recognised — fenced and inline
/// code — because widening it silently deletes links from real notes: a
/// CommonMark type-6 HTML block runs to the next BLANK line, so `[[R]]` in an
/// ordinary prose line after a `</div>` would stop being a link at all.
enum CodeRegionKind: Sendable, Equatable, Hashable {
    case fencedCodeBlock
    case indentedCodeBlock
    case inlineCode
    case htmlBlock
}

struct CodeRegion: Sendable, Equatable {
    let range: NSRange
    let kind: CodeRegionKind
}

/// "Is this offset inside code?" answered in O(log n) instead of O(n).
///
/// The linear `codeRegions.contains { … }` it replaces was 85% of the cost of
/// parsing a large note: `LinkParser` asks once per candidate link, so a note
/// with L links and R regions cost O(L × R). A 230 KB note has thousands of
/// each.
///
/// The trick that makes a binary search legal is that the QUESTION is about a
/// UNION, not about individual regions: "inside any region of these kinds" is
/// exactly "inside the union of those ranges". So the ranges are sorted and
/// COALESCED into disjoint half-open intervals at construction, and a single
/// binary search for the last interval starting at or before `offset` settles
/// it. Kinds are applied by FILTERING before coalescing, which is why the
/// kind-filtered and all-kinds questions need two different indexes rather than
/// one index consulted differently — merging first would let an
/// `.indentedCodeBlock` extend a `.fencedCodeBlock`'s interval and silently
/// widen link suppression.
///
/// Zero-length regions are dropped: `NSLocationInRange` is false for every
/// offset against them, so they can never have contributed an answer.
struct CodeRegionIndex: Sendable {
    /// Disjoint, ascending, half-open. `starts[i]..<ends[i]`.
    private let starts: [Int]
    private let ends: [Int]

    /// - Parameter kinds: `nil` means every kind — the all-regions question.
    init(regions: [CodeRegion], kinds: Set<CodeRegionKind>?) {
        let intervals = regions
            .lazy
            .filter { kinds?.contains($0.kind) ?? true }
            .map { ($0.range.location, $0.range.location + $0.range.length) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(intervals.count)
        ends.reserveCapacity(intervals.count)
        for (lower, upper) in intervals {
            // `lower <= ends.last` merges overlapping AND touching intervals.
            // Touching ones are safe to merge because the intervals are
            // half-open: `[0,3)` ∪ `[3,5)` covers exactly `[0,5)`.
            if let last = ends.last, lower <= last {
                ends[ends.count - 1] = max(last, upper)
            } else {
                starts.append(lower)
                ends.append(upper)
            }
        }
        self.starts = starts
        self.ends = ends
    }

    var isEmpty: Bool { starts.isEmpty }

    func contains(_ offset: Int) -> Bool {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return false }
        return offset < ends[low - 1]
    }
}

/// Counts markdown parses so the editor's caching can be asserted on rather
/// than asserted about. Test-only: the increment is `#if DEBUG`, so a release
/// build carries neither the lock nor the call.
///
/// Not an actor: `MarkdownDocumentModel.init` is synchronous and `Sendable`, and
/// making the count `await`-able would change every call site to prove a
/// property no shipping code reads.
/// Internal, not public: nothing outside this module has any business reading
/// it, and `@testable import` reaches it exactly as it is.
enum MarkdownParseCounter {
    private static let lock = NSLock()
    /// `nonisolated(unsafe)` with an `NSLock`: every read and write holds `lock`.
    nonisolated(unsafe) private static var stored = 0

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stored = 0
    }

    static func record() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }
}
