import XCTest
@testable import LoreFeature

@MainActor
final class TransclusionLayoutTests: XCTestCase {

    // `MarkdownTheme` has no `.default`; tests build one from test tokens,
    // as `Tests/LoreFeatureTests/EditorLayoutTests.swift:9` does.
    private let theme = MarkdownTheme(tokens: TestTokens.make())

    func test_sameContentAndWidthMeasuresIdentically() {
        let c = TransclusionContent.content("# Title\n\nTwo lines\nof body.")
        let a = TransclusionLayout.height(for: c, width: 600, theme: theme)
        let b = TransclusionLayout.height(for: c, width: 600, theme: theme)
        XCTAssertEqual(a, b, accuracy: 0.001, "measurement is not deterministic")
    }

    func test_narrowerWidthIsTaller() {
        let c = TransclusionContent.content(String(repeating: "word ", count: 200))
        let wide = TransclusionLayout.height(for: c, width: 800, theme: theme)
        let narrow = TransclusionLayout.height(for: c, width: 300, theme: theme)
        XCTAssertGreaterThan(narrow, wide)
    }

    func test_everyFailureStateStillReservesVisibleHeight() {
        for c in [TransclusionContent.circular, .tooDeep,
                  .unreadable("nope"), .missingFragment("Body.", "abc")] {
            let h = TransclusionLayout.height(for: c, width: 600, theme: theme)
            XCTAssertGreaterThan(h, 0, "\(c) reserved a blank gap")
        }
    }

    func test_measurementIsCounted() {
        TransclusionMeasureCounter.reset()
        _ = TransclusionLayout.height(for: .content("x"), width: 600, theme: theme)
        XCTAssertEqual(TransclusionMeasureCounter.count, 1)
    }
}
