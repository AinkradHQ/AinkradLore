import CoreGraphics
import Foundation

/// The reader's own preferences for the writing surface.
///
/// ## Why the editor gets its own settings
///
/// `MarkdownTheme.init(tokens:)` took a `HostThemeTokens` and then IGNORED it,
/// hard-coding every number: body 15, line-height 1.5, measure 760. So the one
/// surface in Lore a person stares at for hours was the one surface they could
/// not adjust — and the parameter's presence made it look as though the host
/// theme controlled it, which nothing did.
///
/// These are Lore's own, not the host's. The host theme owns HUE — background,
/// foreground, accents — and keeping colour there is right, because a plugin
/// that repainted itself differently from its host would look broken. Scale is
/// the opposite: how large the text is and how wide the column runs are
/// properties of the DOCUMENT and the person reading it, not of the app's
/// visual identity, and two people sharing a theme can reasonably want
/// different ones.
///
/// ## Presets, not sliders
///
/// Density is three named steps rather than a free numeric field. The heading
/// ramp, the paragraph spacing and the line height are RELATED — `MarkdownTheme`
/// derives headings from the body size and spacing from the heading size — and
/// a free-form body-size field lets someone produce a document whose h4 is
/// smaller than its body text. Presets move the whole system together, which is
/// what keeps `MarkdownThemeTests`' scale assertions meaningful.
public struct EditorSettings: Equatable, Sendable, Codable {

    public enum Density: String, CaseIterable, Codable, Sendable {
        case compact, standard, comfortable

        public var title: String {
            switch self {
            case .compact: return "Compact"
            case .standard: return "Standard"
            case .comfortable: return "Comfortable"
            }
        }

        /// Body point size before zoom.
        var bodySize: CGFloat {
            switch self {
            case .compact: return 13
            case .standard: return 15
            case .comfortable: return 17
            }
        }

        var lineHeightMultiple: CGFloat {
            switch self {
            case .compact: return 1.35
            case .standard: return 1.5
            case .comfortable: return 1.7
            }
        }

        var paragraphSpacing: CGFloat {
            switch self {
            case .compact: return 8
            case .standard: return 12
            case .comfortable: return 16
            }
        }
    }

    /// How wide the text column is allowed to run.
    ///
    /// `.full` is offered but is not the default, and deliberately so: a
    /// measure much beyond ~70 characters is tiring to read, which is what an
    /// unbounded editor gives you on a wide display. It exists for tables and
    /// wide code blocks, where the constraint hurts more than it helps.
    public enum Measure: String, CaseIterable, Codable, Sendable {
        case narrow, standard, wide, full

        public var title: String {
            switch self {
            case .narrow: return "Narrow"
            case .standard: return "Standard"
            case .wide: return "Wide"
            case .full: return "Full width"
            }
        }

        /// Nil means "fill the width".
        var points: CGFloat? {
            switch self {
            case .narrow: return 600
            case .standard: return 760
            case .wide: return 920
            case .full: return nil
            }
        }
    }

    public var density: Density
    public var measure: Measure
    /// ⌘+ / ⌘− steps on top of `density`. A TRANSIENT override in spirit —
    /// "this document is hard to read right now" — but persisted anyway,
    /// because a zoom that silently resets on relaunch reads as a bug to
    /// anyone who used it to make the app usable at all.
    public var zoomStep: Int
    /// Dim everything but the paragraph being written.
    public var focusMode: Bool
    /// Keep the caret at a fixed height rather than letting it walk to the
    /// bottom edge.
    public var typewriterMode: Bool
    /// Whether inline `#tags` draw as tinted chips or as plain tinted text.
    ///
    /// On by default — chips are what makes a tag scannable. Off exists
    /// because some people want the `#` typographically quiet in long prose.
    public var renderTagsAsChips: Bool = true

    /// Defaults reproduce the pre-settings numbers EXACTLY (body 15,
    /// line-height 1.5, paragraph spacing 12, measure 760). That is not
    /// nostalgia: `MarkdownThemeTests` asserts the scale relationships those
    /// numbers produce, so anything else would make the existing suite pass
    /// against a document nobody has ever seen.
    public static let `default` = EditorSettings(density: .standard, measure: .standard,
                                                 zoomStep: 0)

    /// Both writing modes default OFF. They are strong opinions about how a
    /// page should behave, and an editor that dims most of the document the
    /// first time it is opened reads as broken rather than as focused.
    public init(density: Density, measure: Measure, zoomStep: Int,
                focusMode: Bool = false, typewriterMode: Bool = false,
                renderTagsAsChips: Bool = true) {
        self.density = density
        self.measure = measure
        self.zoomStep = Self.clampZoom(zoomStep)
        self.focusMode = focusMode
        self.typewriterMode = typewriterMode
        self.renderTagsAsChips = renderTagsAsChips
    }

    /// Custom `Decodable` rather than the synthesised one: `EditorSettings` is
    /// persisted, so its on-disk JSON was written by whatever version the
    /// user last ran. ANY key here — not just the newest one — is absent
    /// from JSON written before that key existed, so EVERY property decodes
    /// with `decodeIfPresent` and falls back to its own default. A
    /// synthesised decoder (or one that hand-picks which keys are optional)
    /// treats the rest as required regardless of their declared defaults,
    /// which throws on an old install and falls back to `.default` for the
    /// WHOLE struct — silently discarding density, measure, zoom and
    /// everything else the user had actually set, to avoid defaulting the
    /// one key that is genuinely missing. Sparse, old JSON must still decode
    /// into "everything it specifies, defaults for the rest" — never an
    /// all-or-nothing failure.
    private enum CodingKeys: String, CodingKey {
        case density, measure, zoomStep, focusMode, typewriterMode, renderTagsAsChips
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        density = try container.decodeIfPresent(Density.self, forKey: .density)
            ?? EditorSettings.default.density
        measure = try container.decodeIfPresent(Measure.self, forKey: .measure)
            ?? EditorSettings.default.measure
        zoomStep = Self.clampZoom(
            try container.decodeIfPresent(Int.self, forKey: .zoomStep)
                ?? EditorSettings.default.zoomStep)
        focusMode = try container.decodeIfPresent(Bool.self, forKey: .focusMode) ?? false
        typewriterMode = try container.decodeIfPresent(Bool.self, forKey: .typewriterMode) ?? false
        renderTagsAsChips = try container.decodeIfPresent(Bool.self, forKey: .renderTagsAsChips)
            ?? true
    }

    /// Font FAMILY is deliberately not modelled here.
    ///
    /// It was, briefly — and it did nothing: the family is chosen inside
    /// `MarkdownStyleRendering`, which this value does not reach, so the
    /// setting would have persisted a preference with no effect. A control
    /// that appears to work and does not is worse than an absent one, so the
    /// field is gone until the rendering side can honour it.

    /// Bounds on zoom.
    ///
    /// Asymmetric on purpose. Zooming IN has an obvious ceiling of usefulness
    /// but no failure mode; zooming OUT hits illegibility fast, and a text view
    /// at 60% of 13pt is not a feature. The floor is the tighter of the two.
    public static let minZoom = -3
    public static let maxZoom = 8

    static func clampZoom(_ step: Int) -> Int { min(max(step, minZoom), maxZoom) }

    /// Multiplier applied to every type size. 10% per step, so the ramp is
    /// perceptually even rather than a fixed point-count that is drastic at
    /// 13pt and imperceptible at 30.
    var zoomFactor: CGFloat { 1 + CGFloat(zoomStep) * 0.1 }

    /// The effective body size.
    public var bodySize: CGFloat { density.bodySize * zoomFactor }

    /// The effective column width. Scales WITH zoom: a reader who doubled the
    /// text size and kept a 760pt column would be reading a 35-character
    /// measure, which is worse than either setting alone.
    public var maxMeasure: CGFloat? { density.measure(measure, zoomFactor: zoomFactor) }

    /// Zoom applied to `step`, clamped.
    public func zoomed(by step: Int) -> EditorSettings {
        EditorSettings(density: density, measure: measure,
                       zoomStep: Self.clampZoom(zoomStep + step),
                       focusMode: focusMode, typewriterMode: typewriterMode,
                       renderTagsAsChips: renderTagsAsChips)
    }

    /// Zoom reset to the density's own size (⌘0).
    public func zoomReset() -> EditorSettings {
        EditorSettings(density: density, measure: measure, zoomStep: 0,
                       focusMode: focusMode, typewriterMode: typewriterMode,
                       renderTagsAsChips: renderTagsAsChips)
    }
}

private extension EditorSettings.Density {
    func measure(_ measure: EditorSettings.Measure, zoomFactor: CGFloat) -> CGFloat? {
        measure.points.map { $0 * zoomFactor }
    }
}
