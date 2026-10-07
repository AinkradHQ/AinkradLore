import XCTest

@testable import LoreFeature

/// The one main-run-loop coalescer both the outline refresh and the spelling
/// lookup go through: a burst of schedules runs only its last action.
@MainActor
final class MainRunLoopDebouncerTests: XCTestCase {
    func test_twoSchedulesWithinTheIntervalFireOnce() async throws {
        let debouncer = MainRunLoopDebouncer()
        var fired: [Int] = []
        let done = expectation(description: "the last action ran")
        debouncer.schedule(after: 0.05) { fired.append(1) }
        debouncer.schedule(after: 0.05) {
            fired.append(2)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        // Long enough for a first timer that was NOT invalidated to land too.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [2], "only the last action of a burst may run")
    }
}
