import XCTest

@testable import LoreFeature

/// E4T1: the flag that lets both surfaces exist.
final class CM6FlagTests: XCTestCase {

    /// ON by default since E4T3, with the owner's word and after the E4T2
    /// parity checklist.
    ///
    /// It was off for E4T1 and E4T2 because the CodeMirror surface had no link
    /// completion, no Cmd-click and no maths, so defaulting it on would have
    /// taken working features away from the reader. E2 built those; E4T2 then
    /// shot a document holding every construct Lore renders in both surfaces
    /// and found four regressions against the shipping editor, which were fixed
    /// before this default moved.
    ///
    /// Hover previews are still native-only, which is why the setting stays
    /// labelled experimental.
    func test_theFlagDefaultsOn() {
        XCTAssertTrue(EditorSettings.default.usesCM6)
        // And through the memberwise init, not only `.default` — the two have
        // drifted apart before.
        XCTAssertTrue(
            EditorSettings(
                density: .standard, measure: .standard,
                zoomStep: 0
            ).usesCM6)
    }

    /// Turning it off has to keep working, or the flag is not a flag.
    func test_itCanStillBeTurnedOff() throws {
        var settings = EditorSettings.default
        settings.usesCM6 = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: data)
        XCTAssertFalse(decoded.usesCM6, "an explicit false must survive a round trip")
    }

    /// It survives a round trip, and — the part that matters — it survives
    /// JSON written before the key existed.
    ///
    /// `EditorSettings` decodes every key with `decodeIfPresent` precisely so
    /// an old install does not fall back to `.default` for the WHOLE struct and
    /// silently discard the reader's density, measure and zoom. A new key is
    /// the case that rule exists for, so it is tested rather than trusted.
    func test_theFlagSurvivesEncodingAndOldSettingsFilesStillDecode() throws {
        var settings = EditorSettings.default
        settings.usesCM6 = true
        settings.density = .comfortable
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(EditorSettings.self, from: data)
        XCTAssertEqual(back, settings)

        // JSON from before this key existed.
        let old = #"{"density":"compact","measure":"wide","zoomStep":2}"#
        let decoded = try JSONDecoder().decode(
            EditorSettings.self,
            from: Data(old.utf8))
        XCTAssertTrue(
            decoded.usesCM6,
            "an absent key means ON since E4T3 — settings stored before it have no such key, and reading them as off would leave every existing reader on the old surface"
        )
        XCTAssertEqual(decoded.density, .compact, "and must not reset what WAS set")
        XCTAssertEqual(decoded.measure, .wide)
        XCTAssertEqual(decoded.zoomStep, 2)
    }

    /// Zoom and reset carry it, or flipping the text size would silently put
    /// the reader back on the other editor.
    func test_zoomAndResetPreserveTheFlag() {
        var settings = EditorSettings.default
        settings.usesCM6 = true
        XCTAssertTrue(settings.zoomed(by: 2).usesCM6)
        XCTAssertTrue(settings.zoomReset().usesCM6)
    }
}
