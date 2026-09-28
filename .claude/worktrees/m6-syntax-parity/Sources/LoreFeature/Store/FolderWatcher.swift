import Foundation
import CoreServices

/// Watches a vault root RECURSIVELY for filesystem changes, using an
/// `FSEventStream` rather than a single `DispatchSource` on the root vnode.
///
/// A directory vnode (what `DispatchSourceFileSystemObject` watches) only
/// reports changes to entries directly inside it — a write two levels down
/// never touches the root's own vnode, so a single `DispatchSource` on the
/// root is blind to anything happening in a subfolder. `FSEventStream` is
/// recursive by construction: one stream on the root sees every change
/// anywhere below it, which is the only way to notice a note synced in from
/// another machine, a folder created in Finder, or a bulk import landing
/// inside `Vault/Projects/`.
///
/// ## Ownership / lifetime model
///
/// `FSEventStreamCreate` takes a `void *info` context pointer and hands it
/// back, unmodified, on every callback invocation. Two designs are possible
/// for what that pointer refers to:
///
/// 1. Give the C side its OWN strong reference — e.g.
///    `Unmanaged.passRetained(self)` — and release that reference from
///    `deinit`, after tearing the stream down.
/// 2. Give the C side an UNRETAINED reference and let normal Swift ARC
///    ownership (whoever holds this `FolderWatcher` — `VaultIndexCoordinator`,
///    or a test's local `var`) be the only thing keeping it alive.
///
/// (1) is a trap, and an earlier version of this file fell into it: an
/// extra retain that is only released FROM `deinit` can never be released,
/// because `deinit` itself only runs once the retain count reaches zero —
/// and the extra retain is what's holding that count above zero. The result
/// is not a crash but something quieter and worse: the `FolderWatcher`
/// (and its `FSEventStream`) never deallocates, so it keeps running and
/// keeps calling `onChange` for the rest of the process's life — including,
/// in a test, firing into an `XCTestExpectation` that belongs to a
/// completely different, already-finished test. (Caught in review: a
/// `FolderWatcherTests` watcher's delayed second FSEvents delivery landed
/// on `LinkEncodingTests.test_renameToANameWithASpace…`, which was simply
/// whichever test happened to be running on the main queue when the stale
/// callback finally fired.)
///
/// This file uses (2): `Unmanaged.passUnretained(self)`, `retain: nil`,
/// `release: nil` in the `FSEventStreamContext`. `self`'s lifetime is
/// therefore governed ENTIRELY by its owner (normal ARC), and `deinit` —
/// which runs synchronously and immediately once the owner drops its last
/// reference, with no extra retain delaying it — is where the stream is
/// torn down: `FSEventStreamStop`, `FSEventStreamInvalidate`,
/// `FSEventStreamRelease`, in that order.
///
/// This is safe from the callback racing `deinit` for a queue-discipline
/// reason, not a reference-counting one: `FSEventStreamSetDispatchQueue`
/// below schedules every callback on the MAIN queue, and every SANCTIONED
/// caller that can drop the owning reference (`VaultIndexCoordinator.watcher
/// = nil` in `shutdown()`/`activate`, both `@MainActor`; a test's local
/// `var` going out of scope, also on `@MainActor` in this test target) does
/// so FROM the main queue too. The main queue is serial, so "drop the
/// reference" and "run a pending callback" can never execute concurrently
/// there — whichever was enqueued first runs to completion before the
/// other starts.
///
/// `FolderWatcher` itself is NOT `@MainActor` — nothing in the type system
/// enforces this. `deinit` runs wherever the LAST reference dies, and
/// `VaultIndexCoordinator` (the sanctioned owner) only guarantees that on
/// today's call sites. A future off-main release — an autorelease pool
/// draining off-main, a `Task.detached` that ends up holding the store,
/// an Observation registrar callback — would run `FSEventStreamStop`/
/// `Invalidate` concurrently with a callback already executing on main,
/// racing to resolve `info` into a deallocating instance: a real
/// use-after-free the old, thread-safe `DispatchSource.cancel()` never had.
/// `deinit` therefore asserts the invariant explicitly with
/// `dispatchPrecondition(condition: .onQueue(.main))` rather than silently
/// trusting it — turning a hard-to-diagnose race into a loud, immediate,
/// unambiguous crash AT the violation, with a stack trace pointing at the
/// off-main release, instead of an intermittent, hard-to-reproduce
/// use-after-free somewhere downstream. A real retain/release
/// `FSEventStreamContext` (tying `self`'s extra reference to the STREAM's
/// own lifetime rather than to `deinit`) was considered instead, but ties
/// the fix to getting a second, equally subtle ownership protocol right
/// (see the `passRetained`-from-`deinit` mistake above) for a hazard that,
/// today, has no reachable call site — the precondition documents and
/// enforces the actual invariant this codebase runs under (every owner is
/// `@MainActor`) without adding new C-callback machinery to get wrong.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: () -> Void
    /// Captured via `FSEventsGetCurrentEventId()` immediately before
    /// `FSEventStreamCreate` — see `handleEvents` for why this, not a flag
    /// check, is what suppresses stream-startup noise.
    private let startEventId: FSEventStreamEventId

    /// Coalescing latency, in seconds. `FSEventStreamCreate`'s `latency`
    /// parameter does natively what the old `DispatchSource` implementation
    /// hand-rolled with a cancel-and-reschedule `DispatchWorkItem` debounce:
    /// batch a burst of events (a `git checkout`, an rsync, an Obsidian sync
    /// pass) into one delivery instead of one callback per file. 0.3s matches
    /// the value the old debounce used, which was already tuned against this
    /// codebase's other coalescing point (`startBackgroundRebuild`, which
    /// coalesces a rebuild-in-flight against a second request) — reusing it
    /// keeps the two debounce points working towards the same effective
    /// end-to-end latency the app was already shipping with.
    ///
    /// This is a MINIMUM, not an exact delay — FSEvents can and does deliver
    /// more than one batch for a single logical change (e.g. a create
    /// followed shortly by a separate write), so `onChange` should be
    /// treated as "at least one, possibly more" per real change, matching
    /// `startBackgroundRebuild`'s own coalescing of redundant calls.
    static let latency: CFTimeInterval = 0.3

    init?(url: URL, onChange: @escaping () -> Void) {
        // `FSEventStreamCreate`'s paths are matched by PREFIX, not by inode,
        // so the root must be canonical the same way `VaultIndexCoordinator`
        // canonicalizes everywhere else (`Self.canonical` there uses
        // `realpath(3)`) — otherwise a `/tmp`-spelled root (every test vault,
        // and some real ones) would register a stream on one spelling while
        // events arrive spelled `/private/tmp/...`, and every path filter
        // below would silently fail to match.
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return nil }
        self.root = URL(
            fileURLWithPath: String(
                decoding: buffer.map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 }),
                as: UTF8.self),
            isDirectory: true)
        self.onChange = onChange
        // Captured HERE, right before the stream is created, so it reflects
        // "now" as closely as possible — see `handleEvents`'s doc comment.
        self.startEventId = FSEventsGetCurrentEventId()

        // UNRETAINED: see the type's doc comment for why this, and not
        // `passRetained`, is the correct choice here.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents   // per-file, not per-directory,
                                                        // granularity — lets the dot-
                                                        // directory filter below inspect
                                                        // the actual changed path instead
                                                        // of just "something changed
                                                        // somewhere under this directory".
                | kFSEventStreamCreateFlagNoDefer)     // deliver the FIRST event of a
                                                        // burst immediately, then coalesce
                                                        // the rest for `latency` — without
                                                        // this, FSEvents waits a full
                                                        // `latency` period after the FIRST
                                                        // event before delivering anything,
                                                        // which doubles worst-case delay
                                                        // for an isolated, non-bursty change
                                                        // (the common case: one file saved
                                                        // from another machine).

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, info, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleEvents(
                    numEvents: numEvents, eventPaths: eventPaths,
                    eventFlags: eventFlags, eventIds: eventIds)
            },
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), // no historical replay on launch
            Self.latency,
            flags)
        else { return nil }

        // Main queue: `handleVaultChange` (the eventual consumer of
        // `onChange`, via `VaultIndexCoordinator`) is `@MainActor`, and the
        // pre-existing contract (the old `DispatchSource` was created with
        // `queue: .main`) already delivers there. Dispatching FSEvents to
        // any other queue would introduce a background hop this type never
        // had and callers never expected — and would also break the
        // queue-serialization argument the lifetime model above depends on.
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        // `FSEventStreamStart`'s `Bool` result is NOT decorative: on
        // failure the stream exists but will never deliver a single
        // callback — a `FolderWatcher` that returns non-nil here would
        // look alive (`init?` succeeded) while being permanently blind,
        // exactly the silent-failure class this whole rewrite exists to
        // fix. Torn down the same way `deinit` would, then `init?` fails
        // honestly instead of handing back a watcher that watches nothing.
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    /// Runs on the main queue (see `FSEventStreamSetDispatchQueue` above).
    ///
    /// Filters out events entirely inside a dot-prefixed directory component
    /// below the root (`.git`, `.obsidian`, `.lore`, `.trash`, ...) — the
    /// same skip rule `VaultIndexCoordinator.scanVault` and `scanDirectories`
    /// already apply to what they index. Without this, a `git status` or an
    /// Obsidian sync tick (both of which touch files inside their own
    /// dot-directory constantly) would trigger `onChange` -> a full
    /// `startBackgroundRebuild()` -> a whole-vault walk and re-parse, on
    /// every tick. If every path in this batch is filtered out, `onChange`
    /// is not called at all — a batch that touched nothing but `.git` must
    /// produce zero rebuilds, not one that merely does no useful work.
    ///
    /// `kFSEventStreamEventFlagMustScanSubDirs` is FSEvents' own "I dropped
    /// events, you must rescan" signal (an overflowed kernel event queue).
    /// It is honored unconditionally, bypassing the dot-directory filter
    /// entirely for that event: a dropped-events flag on a path we'd
    /// otherwise ignore still means the reported path (and unreported
    /// siblings) may be stale, so it forces `onChange` even if every VISIBLE
    /// path in the batch is inside a dot-directory.
    ///
    /// A path EQUAL to the root itself (empty relative-path components) is
    /// treated as relevant, not filtered — `kFSEventStreamCreateFlagFileEvents`
    /// is best-effort: under load, FSEvents can degrade to directory-level
    /// granularity WITHOUT setting `MustScanSubDirs`, and a degraded report
    /// for a file created directly in the vault root would come back as
    /// the root path itself. An earlier version of this file filtered
    /// root-path events out entirely, to suppress a startup artifact (see
    /// below) — that silently regressed the pre-existing root-level case
    /// under exactly the burst conditions (a sync client, a bulk import)
    /// this task exists to handle, so it was wrong and is not what ships.
    ///
    /// The startup artifact that motivated that filter is real, but it is
    /// NOT reliably distinguished by its flags — measured directly (see the
    /// task report): a temp-vault root created moments before the stream
    /// starts can still be reported, with REAL non-zero flags (creation,
    /// xattr), because `kFSEventStreamEventIdSinceNow`'s boundary is only
    /// as precise as the global FSEvents id counter at the moment
    /// `FSEventStreamCreate` resolves it internally — a filesystem
    /// operation that lands right around that moment can straddle the
    /// boundary either way. So the discriminator here is the event's
    /// OWN id, not its flags or its path: `startEventId` is captured via
    /// `FSEventsGetCurrentEventId()` immediately before `FSEventStreamCreate`,
    /// and any delivered event whose id is NOT strictly greater than that
    /// baseline is stream-startup noise (something that happened at or
    /// before "now" as this instance defines it) and is skipped entirely —
    /// not counted as relevant, and not treated as `MustScanSubDirs` — same
    /// as a `flags == 0` event would have been, but correctly, because it is
    /// keyed to time rather than to a flag pattern real events also produce.
    private func handleEvents(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIds: UnsafePointer<FSEventStreamEventId>
    ) {
        // `Unmanaged.fromOpaque(...).takeUnretainedValue()` states the +0
        // borrow explicitly — `eventPaths` is owned by FSEvents for the
        // duration of this callback only, never by us — where
        // `unsafeBitCast` (the sample-code idiom) leaves that unbalanced-ARC
        // contract implicit.
        guard let pathsArray = Unmanaged<CFArray>.fromOpaque(eventPaths)
            .takeUnretainedValue() as? [String]
        else {
            // Should not happen given `kFSEventStreamCreateFlagUseCFTypes`
            // (which guarantees a `CFArray` of `CFString`), but if the
            // bridge ever failed there would be no way to inspect paths at
            // all — so this deliberately favors an occasional unnecessary
            // rebuild over silently going blind to a batch we cannot even
            // read the contents of. Rare enough (a genuine internal
            // invariant violation, not a normal code path) that it does not
            // meaningfully change steady-state `.git`/`.obsidian` behavior.
            onChange()
            return
        }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var mustRescan = false
        var hasRelevantPath = false
        for i in 0..<numEvents {
            guard eventIds[i] > startEventId else { continue } // stream-startup noise — see doc comment above
            let flags = eventFlags[i]
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                mustRescan = true
            }
            let path = pathsArray[i]
            let components = URL(fileURLWithPath: path)
                .standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if !components.contains(where: { $0.hasPrefix(".") }) {
                hasRelevantPath = true
            }
        }
        guard mustRescan || hasRelevantPath else { return }
        onChange()
    }

    deinit {
        // See the type's doc comment: this class is not `@MainActor`, and
        // the no-use-after-free argument depends entirely on `deinit`
        // running on the main queue, same as event delivery. Asserted here
        // rather than silently trusted, so a future off-main release is a
        // loud, immediate crash at the violation instead of an intermittent
        // use-after-free somewhere inside FSEvents' own delivery machinery.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let stream else { return }
        // Order matters: Stop halts delivery, Invalidate detaches the
        // stream from its dispatch queue (required before Release once a
        // dispatch queue was ever set), Release drops FSEvents' own
        // reference to the stream object. Because `info` was handed to
        // `FSEventStreamContext` UNRETAINED (see the type's doc comment),
        // there is no matching `Unmanaged.release()` to perform here — the
        // only cleanup this instance owns is the stream itself, and once
        // this runs (synchronously, on the main queue — see the doc
        // comment's queue-serialization argument) no further callback can
        // resolve `info` back into this (now-deallocating) instance.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
