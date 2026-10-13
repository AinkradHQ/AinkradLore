import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// E1T3: ten notes in one pane must cost ONE editor surface.
///
/// The acceptance criterion is a process count and a memory figure, not an
/// object graph — a pool that reused views but still spawned WebContent
/// processes would pass an object-identity test and fail the thing the pool
/// exists for.
final class CM6SurfacePoolTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// The pool is a singleton, so one test's leftovers would decide another's
    /// assertions. `@MainActor` cannot be added to `setUp` (it overrides a
    /// nonisolated declaration), so each test resets explicitly.
    @MainActor
    private func freshPool() -> CM6EditorSurfacePool {
        CM6EditorSurfacePool.shared.drainForTesting()
        return CM6EditorSurfacePool.shared
    }

    /// The pid of the WebContent process serving `view`, 0 before it has one.
    ///
    /// Attribution by IDENTITY. This test used to diff the machine's
    /// WebContent pids before and after, which counted every process any other
    /// app (the daily host, Safari, Mail) or a neighbouring test happened to
    /// start meanwhile — it failed on a busy machine with the pool untouched.
    /// `_webProcessIdentifier` is WebKit SPI, read by KVC in a test only.
    /// A FAILURE, not a skip, if the SPI goes away: a skip would silently
    /// retire the guard.
    @MainActor
    private static func contentProcess(of view: WKWebView) -> Int32 {
        let key = "_webProcessIdentifier"
        guard view.responds(to: NSSelectorFromString(key)) else {
            XCTFail("WebKit no longer exposes \(key); re-attribute the process")
            return 0
        }
        return (view.value(forKey: key) as? NSNumber)?.int32Value ?? 0
    }

    /// Every WebContent process, by pid and resident MB.
    ///
    /// Only ever indexed by a pid from `contentProcess(of:)`: WebKit does not
    /// launch content processes as children of the process that opened the
    /// web view, so `ppid` matching finds nothing (measured), and other WebKit
    /// apps on the machine have their own.
    private static func webContentProcesses() -> [Int32: Double] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid=,rss=,command=", "-ax"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var out: [Int32: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("WebKit.WebContent") || line.contains("WebContent.xpc")
            else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let rss = Double(parts[1])
            else { continue }
            out[pid] = rss / 1024
        }
        return out
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Acquire and release ten times, as a pane does when the reader opens ten
    /// notes in turn.
    @MainActor
    func test_tenNotesInOnePaneCostOneSurface() {
        let pool = freshPool()
        for _ in 0..<10 {
            let (view, _) = pool.acquire { _ in }
            pool.release(view, handlerName: "lore")
        }
        XCTAssertEqual(pool.created, 1, "a pane must build ONE surface, not one per note")
        XCTAssertEqual(pool.reused, 9)
    }

    /// And the process count follows, which is the claim that matters.
    @MainActor
    func test_openingTenNotesDoesNotGrowTheProcessCount() throws {
        let pool = freshPool()
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)

        var ours: Set<Int32> = []
        for _ in 0..<10 {
            let (view, isPreloaded) = pool.acquire { _ in }
            if !isPreloaded {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                    styleMask: [.titled], backing: .buffered, defer: false)
                view.frame = window.contentLayoutRect
                window.contentView = view
                windows.append(window)
                view.loadFileURL(
                    index,
                    allowingReadAccessTo: index.deletingLastPathComponent())
                settle(3)
            }
            let pid = Self.contentProcess(of: view)
            XCTAssertGreaterThan(pid, 0, "a loaded surface must have a content process")
            ours.insert(pid)
            pool.release(view, handlerName: "lore")
        }

        let resident = Self.webContentProcesses()
        let total = ours.compactMap { resident[$0] }.reduce(0, +)
        print(
            String(
                format: "POOL notes=10 surfaces=%d procs=%d rss=%.1fMB",
                pool.created, ours.count, total))
        XCTAssertLessThanOrEqual(
            ours.count, 1,
            "ten notes must not open ten content processes")
        XCTAssertLessThan(
            total, 60,
            "one pane's memory must stay near the ~40 MB single-surface "
                + "figure, not multiply by the number of notes opened")
    }

    /// The pool is bounded. A returned surface beyond capacity is dropped
    /// rather than kept, because ~40 MB is too much to hold for a pane nobody
    /// is looking at.
    @MainActor
    func test_thePoolIsBounded() {
        let pool = freshPool()
        var views: [WKWebView] = []
        for _ in 0..<5 { views.append(pool.acquire { _ in }.0) }
        XCTAssertEqual(pool.created, 5, "five simultaneous panes need five surfaces")
        for view in views { pool.release(view, handlerName: "lore") }
        // Only the capacity is retained, so the next five acquisitions cannot
        // all be reuses.
        for _ in 0..<5 { _ = pool.acquire { _ in } }
        XCTAssertGreaterThan(pool.created, 5, "the pool must not retain every surface")
    }

    /// Releasing must detach the old coordinator, or the next pane's edits
    /// arrive at the previous pane's binding — edits landing in the wrong note.
    @MainActor
    func test_releasingDetachesTheMessageHandler() {
        let pool = freshPool()
        let (view, _) = pool.acquire { config in
            config.userContentController.add(Sink(), name: "lore")
        }
        pool.release(view, handlerName: "lore")
        // Re-adding the same name would throw if the old one were still
        // installed, which is precisely the leak being guarded.
        view.configuration.userContentController.add(Sink(), name: "lore")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lore")
    }

    private final class Sink: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ c: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {}
    }
}
