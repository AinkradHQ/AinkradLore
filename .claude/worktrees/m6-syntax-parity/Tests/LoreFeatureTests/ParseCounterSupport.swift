import XCTest
@testable import LoreFeature

extension XCTestCase {

    /// Resets the parse counter AFTER letting in-flight parses land.
    ///
    /// ## The flake this removes
    ///
    /// `MarkdownParseCounter` is process-global, and `applyStyles()` schedules
    /// its parse OFF the main actor. So an earlier test in the same class can
    /// still have a parse in flight when the next one calls `reset()` — the
    /// stray increment lands a moment later and the next assertion reads 1
    /// where it demands 0.
    ///
    /// It is intermittent by construction (it depends on whether the
    /// background parse beats the next test's assertion), which is the worst
    /// property a test can have: these are the guards protecting the main
    /// actor from parsing, and a guard that fails at random is one people
    /// learn to re-run instead of read.
    ///
    /// ## Why draining rather than isolating the counter
    ///
    /// Per-thread counting was the obvious fix and is wrong: several tests
    /// assert `count == 1` for a parse that deliberately happened OFF the main
    /// actor, and a thread-local counter reads 0 for exactly those. The
    /// counter has to stay global, so the fix is to make the reset mean "from
    /// here", which requires no work to still be outstanding.
    ///
    /// Waits for QUIESCENCE rather than a fixed interval.
    ///
    /// The first version drained for a flat 350ms, which fixed the common case
    /// and left a rarer one: the benchmarks parse deliberately LARGE documents,
    /// and a parse that takes longer than the drain still lands after the
    /// reset. Watching until the count stops moving covers both, because it
    /// measures the thing that actually matters — is anything still arriving —
    /// rather than guessing how long that takes.
    ///
    /// Spins the run loop rather than sleeping: the pending work is dispatched
    /// back to the main queue, so a `sleep` would block the very thread that
    /// has to run it and drain nothing at all.
    ///
    /// The cap is a backstop, not a timeout to rely on. Reaching it means work
    /// is still arriving after two seconds, which is a real problem worth
    /// seeing as a failure rather than papering over with a longer wait.
    func resetParseCounter(quietFor quiet: TimeInterval = 0.15,
                           cap: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(cap)
        var lastCount = MarkdownParseCounter.count
        var quietSince = Date()
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            let now = MarkdownParseCounter.count
            if now != lastCount {
                lastCount = now
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quiet {
                break
            }
        }
        MarkdownParseCounter.reset()
    }
}
