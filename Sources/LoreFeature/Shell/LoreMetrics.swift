import AinkradAppKit
import CoreGraphics

/// Lore's own geometry, in one value — the numbers that are about LORE's
/// layout rather than about the design system's scale.
///
/// The rule this file encodes: if a number appears in more than one view, or
/// answers a question someone could reasonably ask ("how wide is the
/// sidebar?", "how round are our chamfers?"), it belongs here. If it is a
/// one-off inside a single view, it stays there with a comment.
///
/// `LoreSidebarMetrics` already did this for the sidebar's indent and is left
/// alone: it is the pure, directly-asserted rule about how folder and document
/// rows line up, and folding it in here would bury it.
enum LoreMetrics {

    // The skin has no sidebar-width token yet (`chrome.settings.sidebarWidth`
    // is the host Settings window's), and these are read by the STORE, which
    // has no environment to read a skin from.
    /// The sidebar's width when nothing has been chosen.
    static let defaultSidebarWidth: CGFloat = 280  // design-lint: allow frame-literal token-gap chrome.sidebarWidth
    /// Narrow enough to be a list of names, wide enough to still show one.
    static let minSidebarWidth: CGFloat = 180  // design-lint: allow frame-literal token-gap chrome.sidebarMinWidth
    /// Wide enough for deep trees, bounded so the editor cannot be squeezed
    /// out of existence on a small display.
    static let maxSidebarWidth: CGFloat = 520  // design-lint: allow frame-literal token-gap chrome.sidebarMaxWidth

    static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    /// Horizontal padding for Lore's own bars (the document header, the panel
    /// bar), so the editor's chrome lines up column-to-column.
    static let gutter: CGFloat = AinkradSpacing.md

    /// The one chamfer cut Lore draws — `skin.cut.c6` in a view. Kept only for
    /// `LinkPreviewPanel`, which moves to the kit panel in 5B.8.
    ///
    /// There were two — `ChamferShape(cut: 6)` on tabs and `cut: 4` on the
    /// panel-bar buttons — with no rule distinguishing them; they were simply
    /// written at different times. Two chamfer radii in one window read as a
    /// mistake rather than a hierarchy, so there is now one.
    static let chamfer: CGFloat = 6

    // MARK: - Contrast floors
    //
    // Lore draws de-emphasised text and glyphs by fading the theme's
    // foreground, which is a contrast decision dressed up as a style one: at
    // 0.4 on a mid-tone surface, "secondary" text stops meeting the 4.5:1 that
    // makes it readable, and a faded indicator glyph stops meeting the 3:1
    // non-text minimum. These are the floors, named so a future `.opacity(0.4)`
    // on a label reads as the mistake it is.
    //
    // Deliberately NOT a single value: text and non-text have different
    // minimums in the guidance, and collapsing them would either wash out the
    // glyphs or over-darken the captions.
    //
    // Views read these as `skin.opacity.o75` / `.o60` / `.o55`. The two left
    // here are read only by the native editor (`MarkdownStyleRendering`,
    // `LinkPreviewPanel`), which is tokenised in 5B.8.

    /// Supporting text — captions, hints, the save-state label.
    static let secondaryText: Double = 0.75
    /// The faintest text should ever go: shortcut hints, placeholder detail.
    static let tertiaryText: Double = 0.6
}
