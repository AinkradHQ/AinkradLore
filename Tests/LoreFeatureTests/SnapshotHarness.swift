import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

// The off-screen parity harness (Epic 5B, task 5B.0).
//
// FILE-SCOPE functions, not static methods on a test class: a `static` helper
// on an `XCTestCase` subclass in a `@testable` test bundle is the trap the
// plan names — keep every shared helper here, free-standing.
//
// Everything renders through `NSHostingView` + `cacheDisplay`, never
// `ImageRenderer`: the latter cannot draw AppKit-backed controls (text fields,
// text views, PDF views), which is half of what Lore shows.

/// Where `make parity` writes its PNGs. Nil unless `LORE_PARITY_DIR` is set,
/// which is what keeps the screen shots out of the normal suite.
///
/// xcodebuild forwards `TEST_RUNNER_<NAME>` to the test process as `<NAME>`;
/// the `parity` target sets that, and a plain `LORE_PARITY_DIR` is honoured
/// too for a runner that passes the environment through.
func parityOutputDirectory() throws -> URL? {
    guard let path = ProcessInfo.processInfo.environment["LORE_PARITY_DIR"],
        !path.isEmpty
    else { return nil }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One of the host's seven palettes, built from the host's own theme files.
///
/// The `.theme` files in `Tests/Fixtures/Themes` are verbatim copies of
/// `Ainkrad/Sources/Ainkrad/Resources/Themes` (host `development` @ 15442072),
/// decoded by the same `ainkradLoadThemes` the host's `ThemeCatalog` uses. A
/// frozen copy, on purpose: a before/after pair must render from identical
/// inputs, so the palettes may only move when someone moves them here.
struct ParityPalette {
    /// The theme id, which is also the file-name suffix of every shot.
    let id: String
    let skin: AinkradSkin

    var tokens: HostThemeTokens { HostThemeTokens(skin: skin) }

    /// The plugin-facing theme exactly as `HostServicesImpl` publishes it:
    /// the seven tokens plus the real status colours.
    @MainActor var theme: HostTheme {
        let theme = HostTheme(tokens)
        let status = AinkradStatusColors(skin: skin)
        theme.updateStatusColors(
            HostStatusColors(success: status.success, warning: status.warning, danger: status.danger))
        return theme
    }
}

/// The order every loop runs in — and the order the plan lists them.
let parityPaletteIDs = [
    "neonBlue", "cyberPurple", "tokyoNight", "solarizedDark", "dracula", "nord", "gruvbox",
]

private final class HarnessBundleToken {}

/// All seven palettes. Fails loudly on any theme-file issue: a palette that
/// silently fell back to the standard skin would make seven identical shots.
func parityPalettes() throws -> [ParityPalette] {
    let bundle = Bundle(for: HarnessBundleToken.self)
    let urls = bundle.urls(forResourcesWithExtension: "theme", subdirectory: nil) ?? []
    let result = ainkradLoadThemes(try urls.map { try Data(contentsOf: $0) })
    guard result.issues.isEmpty else {
        throw HarnessError("theme files did not load: \(result.issues)")
    }
    return try parityPaletteIDs.map { id in
        guard let file = result.themes[id] else {
            throw HarnessError("no theme file for \(id); found \(result.themes.keys.sorted())")
        }
        return ParityPalette(id: id, skin: file.skin)
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A borderless, never-shown window in the host's appearance. The host pins
/// `NSApp.appearance` to dark Aqua, so an AppKit control drawn in a light
/// system appearance would not be what Lore looks like.
@MainActor
func makeOffscreenWindow(_ rect: NSRect) -> NSWindow {
    let window = NSWindow(
        contentRect: rect, styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    return window
}

/// Renders `view` at a fixed size under `palette` and returns its pixels.
///
/// The view sits top-leading on the palette's background, inside the skin
/// environment the host installs (`.ainkradSkin`), so kit components read the
/// same tokens they do in the app. `settleFor` lets `.task`/`onAppear` work and
/// AppKit's own deferred layout land before the capture.
@MainActor
func shoot(
    _ view: some View, size: CGSize, palette: ParityPalette,
    settleFor seconds: TimeInterval = 0.5
) throws -> NSBitmapImageRep {
    let root =
        view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(palette.tokens.background)
        .ainkradSkin(palette.skin)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = makeOffscreenWindow(hosting.frame)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    settle(seconds)
    hosting.layoutSubtreeIfNeeded()
    hosting.display()
    return try capture(hosting)
}

/// `cacheDisplay` of an already-hosted view.
@MainActor
func capture(_ view: NSView) throws -> NSBitmapImageRep {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw HarnessError("no bitmap for \(type(of: view))")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Spins the main run loop for `seconds`.
@MainActor
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw HarnessError("could not encode \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

/// How many rows of the image differ from their neighbour.
///
/// A cheap "did anything render" measure that a size check cannot give: a
/// blank surface is one colour, so every row is identical to the last, and
/// the count is 1 however many bytes the PNG takes.
func distinctRowCount(of rep: NSBitmapImageRep) -> Int {
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    var previous: [Int] = []
    var distinct = 0
    for y in stride(from: 0, to: height, by: 4) {
        var row: [Int] = []
        for x in stride(from: 0, to: width, by: 16) {
            let colour = rep.colorAt(x: x, y: y)
            row.append(Int(((colour?.brightnessComponent ?? 0) * 255).rounded()))
        }
        if row != previous { distinct += 1 }
        previous = row
    }
    return distinct
}
