import SwiftUI
import AinkradAppKit

/// Every size and every gap in the markdown editor, in one value.
///
/// M2a had these numbers inline at their use sites, which is how the editor
/// ended up with no vertical rhythm at all: there was no single place where
/// "how far apart are two paragraphs" was a question anyone had to answer.
/// M3 (PDF) and M4 (rich text) render the same documents, so this value is the
/// seam that stops the three from drifting apart.
///
/// Colour still comes from `HostThemeTokens` — the theme owns hue, this owns
/// scale.
struct MarkdownTheme: Equatable {
    let bodySize: CGFloat
    let lineHeightMultiple: CGFloat
    let paragraphSpacing: CGFloat
    let listIndentStep: CGFloat
    let contentInset: CGFloat
    /// Nil means "fill the width". A measure much beyond ~70 characters is
    /// tiring to read, which is what an unbounded editor gives you on a wide
    /// window.
    let maxMeasure: CGFloat?
    /// See `EditorSettings.renderTagsAsChips`. Resolved here rather than read
    /// from `settings` at the styling call site — `MarkdownStyleRendering
    /// .add(_:in:to:storage:tokens:theme:)` never has `settings` in scope,
    /// only `tokens` and `theme`, and `MarkdownTheme` exists precisely to be
    /// "settings resolved for rendering".
    let renderTagsAsChips: Bool

    /// `settings` defaults to `.default`, whose values are exactly the numbers
    /// this initializer used to hard-code — so every call site that has no
    /// settings to offer (a preview, a test, an engine with no editor chrome)
    /// renders precisely what it rendered before.
    ///
    /// `tokens` is still accepted and still unused. It stays because colour
    /// genuinely belongs to the host theme and a future scale that depends on
    /// it (a host-wide type ramp) would arrive through this parameter — but it
    /// is worth being explicit that TODAY it decides nothing here, which the
    /// old signature actively obscured.
    init(tokens: HostThemeTokens, settings: EditorSettings = .default) {
        bodySize = settings.bodySize
        lineHeightMultiple = settings.density.lineHeightMultiple
        paragraphSpacing = settings.density.paragraphSpacing * settings.zoomFactor
        listIndentStep = 22 * settings.zoomFactor
        contentInset = 28 * settings.zoomFactor
        maxMeasure = settings.maxMeasure
        renderTagsAsChips = settings.renderTagsAsChips
    }

    /// h1…h6. Clamped so an out-of-range level from a malformed document
    /// cannot produce a negative or absurd size.
    ///
    /// Derived from `bodySize` rather than fixed, so zoom and density move the
    /// whole ramp together. The multipliers are the original absolute sizes
    /// divided by the original body size of 15 — at default settings this
    /// returns [30, 24, 20, 17.5, 16, 15.5] to the point, which is what keeps
    /// `MarkdownThemeTests`' existing assertions honest rather than merely
    /// passing.
    func headingSize(_ level: Int) -> CGFloat {
        let ratios: [CGFloat] = [2, 1.6, 4.0 / 3.0, 7.0 / 6.0, 16.0 / 15.0, 31.0 / 30.0]
        return bodySize * ratios[min(max(level, 1), 6) - 1]
    }

    func headingSpacingBefore(_ level: Int) -> CGFloat {
        max(10, headingSize(level) * 0.9)
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        max(4, headingSize(level) * 0.25)
    }
}
