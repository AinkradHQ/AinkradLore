import SwiftUI
import AinkradAppKit

/// The document's headings, as texture rather than as UI.
///
/// ## Why this replaces the outline panel
///
/// The outline lived in a 280pt slideover, capped at 160pt tall, behind a
/// disclosure the user had already opened the panel to see — and it was
/// mutually exclusive with linked mentions, so consulting one meant closing
/// the other. All of that to answer a question asked constantly and answered
/// in half a second: *where am I, and take me there*.
///
/// The rail answers it without occupying anything. It draws one short tick per
/// heading in the margin the editor's measure already leaves empty, indented
/// by level. No text, so at rest it reads as texture — a sense of the
/// document's shape, the way a scrollbar conveys length. Hovering expands it
/// into the full labelled outline as an OVERLAY, so the text column never
/// reflows; the writing position is as stable as it was with the panel shut.
///
/// The keyboard route is ⌘⇧O, which opens the same headings as a filterable
/// jump palette — see `LorePalette`. The rail is the glanceable half; the
/// palette is the fast half.
struct LoreSpineRail: View {
    let outline: [OutlineEntry]
    /// Total body length in UTF-16 units, for proportional placement.
    let documentLength: Int
    /// The caret's body-relative offset, for the active tick.
    let caretOffset: Int
    let theme: HostTheme
    let onSelect: (Int) -> Void

    @State private var expanded = false
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradTypography) private var typo

    /// Width of the rail at rest. Sized to be unmissable as an affordance
    /// while fitting inside `MarkdownTheme.contentInset`, so it costs the text
    /// column nothing.
    static let width: CGFloat = 12

    private var activeIndex: Int? {
        LoreSpineRail.activeHeading(in: outline, caretOffset: caretOffset)
    }

    var body: some View {
        // No headings, no rail. A column of empty margin with a hover target
        // in it would be a promise of something that is not there.
        if !outline.isEmpty {
            ticks
                .frame(width: Self.width)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : AinkradMotion.hover) {
                        expanded = hovering
                    }
                }
                .overlay(alignment: .topLeading) {
                    if expanded { labels }
                }
                .accessibilityHidden(true)
        }
    }

    private var ticks: some View {
        GeometryReader { geometry in
            ForEach(Array(outline.enumerated()), id: \.offset) { index, entry in
                let fraction = LoreSpineRail.fraction(of: entry.utf16Offset,
                                                      in: documentLength)
                Capsule()
                    // EXEMPT from `LoreMetrics.indicatorGlyph`, deliberately.
                    //
                    // The floors exist for elements that carry meaning no other
                    // channel carries. These ticks do not: the ACTIVE one is
                    // drawn in the accent (and is the only one that reports
                    // anything), the headings themselves are reachable via ⌘⇧O
                    // and by hovering the rail, and the whole rail is
                    // `accessibilityHidden` because it is a visual summary of
                    // information the document already contains. Raising these
                    // to 0.55 was tried and makes the rail read as loud chrome
                    // beside the text rather than as the texture it is for.
                    .fill(index == activeIndex
                          ? theme.tokens.accentPrimary
                          : theme.tokens.foreground.opacity(0.28))
                    // Deeper headings draw shorter ticks, so nesting is
                    // legible without a single character of text.
                    .frame(width: Self.tickWidth(forLevel: entry.level), height: 2)
                    .position(x: Self.tickWidth(forLevel: entry.level) / 2 + 2,
                              y: geometry.size.height * fraction)
            }
        }
    }

    /// The expanded outline, drawn OVER the text rather than beside it, so the
    /// measure never reflows on hover.
    private var labels: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            ForEach(Array(outline.enumerated()), id: \.offset) { index, entry in
                Button { onSelect(entry.utf16Offset) } label: {
                    Text(entry.text)
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(index == activeIndex
                                         ? theme.tokens.accentPrimary
                                         : theme.tokens.foreground.opacity(0.85))
                        .lineLimit(1)
                        .padding(.leading, CGFloat(max(0, entry.level - 1)) * 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AinkradSpacing.sm)
        .frame(width: 240, alignment: .leading)
        .background(theme.tokens.surfaceElevated)
        .clipShape(ChamferShape(cut: LoreMetrics.chamfer))
        .shadow(color: .black.opacity(0.3), radius: 12, x: 2)
        .transition(.opacity)
    }

    /// Where a heading sits, as a fraction of the document.
    ///
    /// Proportional to the CHARACTER offset, not to laid-out height. The two
    /// differ wherever the document does (a long code block occupies more
    /// characters than screen), so this is a map of the text rather than of
    /// the rendering — deliberately, because the exact alternative costs a
    /// round trip through the layout manager on every redraw, and clicking a
    /// tick jumps to the exact offset regardless.
    ///
    /// Clamped, and safe on an empty document: a zero length would otherwise
    /// divide by zero and place every tick at NaN, which SwiftUI renders as a
    /// blank rail with no error.
    static func fraction(of offset: Int, in documentLength: Int) -> CGFloat {
        guard documentLength > 0 else { return 0 }
        return min(max(CGFloat(offset) / CGFloat(documentLength), 0), 1)
    }

    /// Which heading the caret is currently inside: the LAST one at or before
    /// it. Nil when the caret sits above the first heading, which is a real
    /// position (a document with a preamble) and not an error.
    static func activeHeading(in outline: [OutlineEntry], caretOffset: Int) -> Int? {
        var active: Int?
        for (index, entry) in outline.enumerated() where entry.utf16Offset <= caretOffset {
            active = index
        }
        return active
    }

    /// Tick length by heading level. Clamped, so a malformed level from a
    /// broken document cannot produce a negative width.
    static func tickWidth(forLevel level: Int) -> CGFloat {
        let clamped = min(max(level, 1), 6)
        return 9 - CGFloat(clamped - 1) * 1.2
    }
}
