import AinkradAppKit
import AppKit
import SwiftUI

/// Every size and every gap in the markdown editor, in one value.
///
/// M2a had these numbers inline at their use sites, which is how the editor
/// ended up with no vertical rhythm at all: there was no single place where
/// "how far apart are two paragraphs" was a question anyone had to answer.
/// M3 (PDF) and M4 (rich text) render the same documents, so this value is the
/// seam that stops the three from drifting apart.
///
/// It also carries what the styling files colour WITH: the host's
/// `HostThemeTokens` (the palette) and the `AinkradSkin` (alpha levels, syntax
/// hues, type sizes). Every styling file reads both through this value and
/// never takes `HostThemeTokens` on its own, so "where does this colour come
/// from" has one answer.
struct MarkdownTheme: Equatable {
    /// The host palette every editor colour is drawn from.
    let tokens: HostThemeTokens
    /// The skin: opacity levels, syntax hues and type sizes.
    let skin: AinkradSkin
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

    /// The prose face.
    ///
    /// PROPORTIONAL, and that is the whole of M9.1. The editor rendered every
    /// paragraph in `NSFont.monospacedSystemFont` at a hard-coded 14 pt, which
    /// is why a Lore note and an Obsidian note read as different products even
    /// where every other detail matched — proportional and monospaced text
    /// differ in character density, line texture and word shape, and no amount
    /// of spacing tuning closes that.
    ///
    /// It lives HERE rather than as a static on the renderer for a second
    /// reason: `EditorSettings.bodySize` was computed correctly, threaded into
    /// `MarkdownTheme.bodySize` correctly, and then read by nothing except the
    /// heading ramp. Density and ⌘+/⌘− moved the headings, the line height and
    /// the column, and left the prose at 14 pt — a control that appeared to
    /// work and did not, which is the exact failure `EditorSettings`' own
    /// comment says it removed the font-family setting to avoid. Putting the
    /// font on the theme makes "the body font tracks the settings" a property
    /// of the type rather than a promise nobody kept.
    let bodyFont: NSFont

    /// Code — inline and fenced.
    ///
    /// Sized BELOW `bodyFont` rather than at it. SF Mono at a given point size
    /// reads visibly larger and much wider than SF Text at the same size (a
    /// taller x-height and a fixed advance set for legibility, not for fitting
    /// prose), so matching the point sizes makes every inline code span look
    /// like it was set in a bigger font. Obsidian ships `--font-monospace`
    /// below `--font-text` for the same reason.
    let monoFont: NSFont

    /// How far `monoFont` sits below `bodyFont`. Tuned by eye against
    /// Obsidian's default pairing; a ratio rather than a point offset so it
    /// survives density and zoom.
    static let monoRatio: CGFloat = 0.92

    /// The advance of one space in `bodyFont`.
    ///
    /// Stored, not measured on demand. `MarkdownStyleRenderer` needs it once
    /// per list-item span to derive a nested item's hang indent, which put a
    /// `size(withAttributes:)` call on the styling path of every list in the
    /// document. It was previously a `static let` on the renderer, correct
    /// only because the font was a constant; now that the font moves with
    /// density and zoom, the theme is the natural place for it — one
    /// measurement per theme, and the theme is rebuilt only when the settings
    /// or the tokens change.
    let spaceAdvance: CGFloat

    /// `bodyFont` at bold — a callout's title, a table header.
    ///
    /// Computed rather than stored so `Equatable` stays a comparison of the
    /// two faces the theme actually chose, and a derived face can never drift
    /// out of step with the one it is derived from.
    var boldBodyFont: NSFont {
        NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
    }

    /// `settings` defaults to `.default`, whose values are exactly the numbers
    /// this initializer used to hard-code — so every call site that has no
    /// settings to offer (a preview, a test, an engine with no editor chrome)
    /// renders precisely what it rendered before.
    ///
    /// `skin` defaults to `.standard` for the same reason: a caller with no
    /// environment to read one from (a test, the CM6 bridge until 5B.9) gets
    /// the default skin, whose values are today's literals.
    init(
        tokens: HostThemeTokens, settings: EditorSettings = .default,
        skin: AinkradSkin = .standard
    ) {
        self.tokens = tokens
        self.skin = skin
        bodySize = settings.bodySize
        lineHeightMultiple = settings.density.lineHeightMultiple
        paragraphSpacing = settings.density.paragraphSpacing * settings.zoomFactor
        listIndentStep = 22 * settings.zoomFactor
        contentInset = 28 * settings.zoomFactor
        maxMeasure = settings.maxMeasure
        renderTagsAsChips = settings.renderTagsAsChips
        bodyFont = .systemFont(ofSize: settings.bodySize)
        monoFont = .monospacedSystemFont(
            ofSize: settings.bodySize * Self.monoRatio,
            weight: .regular)
        spaceAdvance =
            (" " as NSString)
            .size(withAttributes: [.font: bodyFont]).width
    }

    /// h1…h6. Clamped so an out-of-range level from a malformed document
    /// cannot produce a negative or absurd size.
    ///
    /// Derived from `bodySize` rather than fixed, so zoom and density move the
    /// whole ramp together.
    ///
    /// The ratios are Obsidian's, with ONE deliberate change. Obsidian's h6 is
    /// exactly 1.0 — the same size as body text, separated from it by weight
    /// and colour alone. `MarkdownThemeTests` asserts that even h6 outranks
    /// body, and that assertion is defending something real: a heading that
    /// measures the same as the paragraph under it is a bold paragraph. So h6
    /// is 1.05 rather than 1.00, which keeps the rule and is within a point of
    /// the target at every density.
    ///
    /// The previous ramp — [2, 1.6, 4/3, 7/6, 16/15, 31/30] — was flat at the
    /// bottom in a way that made the last two levels useless: at the default
    /// body size h5 was 1 pt larger than body and h6 half a point larger, so
    /// they were indistinguishable from each other and nearly so from prose.
    /// At default settings this returns [27, 24, 21, 18.75, 16.9, 15.75];
    /// every adjacent pair differs by at least 1.1 pt and the top three by
    /// three.
    func headingSize(_ level: Int) -> CGFloat {
        let ratios: [CGFloat] = [1.80, 1.60, 1.40, 1.25, 1.125, 1.05]
        return bodySize * ratios[min(max(level, 1), 6) - 1]
    }

    /// The weight a heading is set at.
    ///
    /// Semibold at the top of the ramp, bold at the bottom — which inverts the
    /// naive expectation on purpose. Optical weight grows with size: SF Bold
    /// at 27 pt is far heavier against the page than SF Bold at 16 pt, and a
    /// uniformly-bold ramp makes h1 shout while h6 barely registers. Size
    /// carries the top of the hierarchy and weight carries the bottom.
    func headingWeight(_ level: Int) -> NSFont.Weight {
        level <= 3 ? .semibold : .bold
    }

    /// Space above a heading. Roughly 1.35× its own size, against 0.45× below
    /// it — a heading binds to the text it introduces, which is what the ratio
    /// between these two encodes and what `MarkdownThemeTests` asserts.
    ///
    /// Both were previously smaller (0.9× and 0.25×, floors of 10 and 4), and
    /// the direction was already right; the numbers simply left a heading
    /// crowded into the paragraph above it.
    func headingSpacingBefore(_ level: Int) -> CGFloat {
        max(16, headingSize(level) * 1.35)
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        max(6, headingSize(level) * 0.45)
    }
}
