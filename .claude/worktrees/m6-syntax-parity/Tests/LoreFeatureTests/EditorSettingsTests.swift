import XCTest
@testable import LoreFeature

/// The editor's display settings, and the theme they drive.
@MainActor
final class EditorSettingsTests: XCTestCase {

    private let tokens = TestTokens.make()

    // MARK: - The defaults are the old hard-coded values

    /// The load-bearing test of this whole change.
    ///
    /// `MarkdownTheme` used to hard-code body 15, line-height 1.5, paragraph
    /// spacing 12, list indent 22, inset 28, measure 760. `MarkdownThemeTests`
    /// asserts scale relationships derived from those numbers. If the defaults
    /// produced anything else, that suite would keep passing while describing
    /// a document nobody has ever seen — so the defaults are pinned here
    /// directly, to the point.
    func test_defaultSettingsReproduceThePreSettingsTheme() {
        let theme = MarkdownTheme(tokens: tokens, settings: .default)
        XCTAssertEqual(theme.bodySize, 15)
        XCTAssertEqual(theme.lineHeightMultiple, 1.5)
        XCTAssertEqual(theme.paragraphSpacing, 12)
        XCTAssertEqual(theme.listIndentStep, 22)
        XCTAssertEqual(theme.contentInset, 28)
        XCTAssertEqual(theme.maxMeasure, 760)
    }

    /// The heading ramp became DERIVED (body × ratio) rather than fixed, so
    /// zoom moves it. At default settings it must still land on exactly the
    /// old absolute sizes.
    func test_defaultHeadingRampMatchesTheOldAbsoluteSizes() {
        let theme = MarkdownTheme(tokens: tokens, settings: .default)
        let expected: [CGFloat] = [30, 24, 20, 17.5, 16, 15.5]
        for (index, size) in expected.enumerated() {
            XCTAssertEqual(theme.headingSize(index + 1), size, accuracy: 0.001,
                           "h\(index + 1) drifted from the pre-settings ramp")
        }
    }

    /// An out-of-range level from a malformed document still clamps.
    func test_headingSizeClampsOutOfRangeLevels() {
        let theme = MarkdownTheme(tokens: tokens, settings: .default)
        XCTAssertEqual(theme.headingSize(0), theme.headingSize(1))
        XCTAssertEqual(theme.headingSize(99), theme.headingSize(6))
    }

    // MARK: - Zoom

    func test_zoomScalesTheWholeRampTogether() {
        let zoomed = EditorSettings.default.zoomed(by: 2)     // ×1.2
        let theme = MarkdownTheme(tokens: tokens, settings: zoomed)
        XCTAssertEqual(theme.bodySize, 18, accuracy: 0.001)
        XCTAssertEqual(theme.headingSize(1), 36, accuracy: 0.001,
                       "headings must scale with the body, not stay fixed")
    }

    /// The measure scales with zoom too. A reader who doubled the text size
    /// and kept a 760pt column would be reading a ~35-character measure, which
    /// is worse than either setting on its own.
    func test_measureScalesWithZoom() {
        let theme = MarkdownTheme(tokens: tokens,
                                  settings: EditorSettings.default.zoomed(by: 5))
        XCTAssertEqual(try XCTUnwrap(theme.maxMeasure), 760 * 1.5, accuracy: 0.001)
    }

    /// Zoom is bounded, asymmetrically: zooming out hits illegibility fast,
    /// zooming in merely gets large.
    func test_zoomClampsAtBothEnds() {
        XCTAssertEqual(EditorSettings.default.zoomed(by: -99).zoomStep,
                       EditorSettings.minZoom)
        XCTAssertEqual(EditorSettings.default.zoomed(by: 99).zoomStep,
                       EditorSettings.maxZoom)
    }

    func test_zoomResetReturnsToTheDensitysOwnSize() {
        let reset = EditorSettings.default.zoomed(by: 4).zoomReset()
        XCTAssertEqual(reset.zoomStep, 0)
        XCTAssertEqual(MarkdownTheme(tokens: tokens, settings: reset).bodySize, 15)
    }

    /// Zoom must not silently change the other preferences.
    func test_zoomPreservesDensityAndMeasure() {
        let custom = EditorSettings(density: .comfortable, measure: .narrow, zoomStep: 0)
        let zoomed = custom.zoomed(by: 3)
        XCTAssertEqual(zoomed.density, .comfortable)
        XCTAssertEqual(zoomed.measure, .narrow)
    }

    // MARK: - Density and measure

    /// Density moves the related values TOGETHER — the reason it is a preset
    /// rather than a free body-size field. A ramp where h4 is smaller than the
    /// body text must not be reachable.
    func test_densityMovesTheWholeSystem() {
        for density in EditorSettings.Density.allCases {
            let settings = EditorSettings(density: density, measure: .standard,
                                          zoomStep: 0)
            let theme = MarkdownTheme(tokens: tokens, settings: settings)
            XCTAssertGreaterThan(theme.lineHeightMultiple, 1)
            for level in 1...6 {
                XCTAssertGreaterThanOrEqual(theme.headingSize(level), theme.bodySize,
                                            "h\(level) is smaller than body text at \(density)")
            }
            for level in 1..<6 {
                XCTAssertGreaterThanOrEqual(theme.headingSize(level),
                                            theme.headingSize(level + 1),
                                            "the ramp inverts at \(density)")
            }
        }
    }

    /// Full width means "no cap", which the layout reads as fill-the-view.
    func test_fullWidthRemovesTheMeasureCap() {
        let settings = EditorSettings(density: .standard, measure: .full, zoomStep: 0)
        XCTAssertNil(MarkdownTheme(tokens: tokens, settings: settings).maxMeasure)
    }

    // MARK: - Persistence

    func test_settingsRoundTripThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-editorsettings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))

        store.setEditorSettings(EditorSettings(density: .comfortable, measure: .wide,
                                               zoomStep: 2))

        // A second store over the SAME document store is what a relaunch looks
        // like — a zoom that silently resets on relaunch reads as a bug to
        // anyone who used it to make the app legible at all.
        let reopened = LoreStore(documents: docs,
                                 indexPath: root.appendingPathComponent(".idx.sqlite"))
        XCTAssertEqual(reopened.editorSettings.density, .comfortable)
        XCTAssertEqual(reopened.editorSettings.measure, .wide)
        XCTAssertEqual(reopened.editorSettings.zoomStep, 2)
    }

    /// A corrupt or newer-format blob must not stop Lore starting.
    func test_unreadableSettingsFallBackToDefaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-editorsettings-bad-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let docs = FakeDocs()
        docs.setData(Data("not json".utf8), forKey: "editorSettings")

        let store = LoreStore(documents: docs,
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        XCTAssertEqual(store.editorSettings, .default)
    }

    // MARK: - Render tags as chips

    func test_renderTagsAsChips_defaultsToOn() {
        // The brief's version of this test called `EditorSettings()` — there
        // is no parameterless initializer anywhere in this codebase, only
        // `.default` and the explicit member-wise one. Using `.default`.
        XCTAssertTrue(EditorSettings.default.renderTagsAsChips)
    }

    func test_renderTagsAsChips_roundTripsThroughCodable() throws {
        var settings = EditorSettings.default
        settings.renderTagsAsChips = false
        let decoded = try JSONDecoder().decode(
            EditorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.renderTagsAsChips)
    }

    func test_renderTagsAsChips_absentFromStoredJSONDecodesToOn() throws {
        // Someone upgrading has settings JSON written before this key existed.
        // It must decode, not throw, and must land on the default.
        let old = Data(#"{"density":"standard","measure":"standard"}"#.utf8)
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: old)
        XCTAssertTrue(decoded.renderTagsAsChips)
    }
}
