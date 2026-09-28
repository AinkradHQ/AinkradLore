import SwiftUI
import AinkradAppKit

/// The sidebar's tag filter chips.
///
/// ## Why it wraps instead of scrolling
///
/// The row was a horizontal `ScrollView`, which hides tags behind an edge with
/// no indication they are there: in a vault with thirty tags you can only see
/// the first four, and nothing tells you the rest exist. Worse, the ACTIVE
/// chip scrolls out of view, so the way to clear a filter disappears — which is
/// why a separate "Clear" chip had to be added.
///
/// Wrapping shows the whole vocabulary. Capped at two rows so it cannot push
/// the note list off the screen, with the remainder behind a "+n" that expands
/// in place — no popover, no second window, nothing that can swallow a click.
struct TagChipRow: View {
    let tags: [String]
    let counts: [String: Int]
    @Binding var activeTag: String?
    let theme: HostTheme

    @State private var expanded = false

    /// How many chips fit in two rows at a typical sidebar width.
    ///
    /// A count, not a measurement. Measuring would need the real chip widths
    /// (which vary with tag length) fed back through a layout pass, and the
    /// only thing riding on the number is when a "+n" appears — being a chip
    /// or two out is invisible, while a `GeometryReader`-driven version would
    /// be an order of magnitude more code for the same outcome.
    static let collapsedLimit = 8

    private var visible: [String] {
        expanded ? tags : Array(tags.prefix(Self.collapsedLimit))
    }

    private var hidden: Int { max(0, tags.count - visible.count) }

    var body: some View {
        // An ACTIVE tag is always shown, even when it would fall past the cap:
        // a filter you cannot see is a filter you cannot turn off, and that is
        // the exact failure the horizontal scroll had.
        let shown = activeTag.map { active in
            visible.contains(active) ? visible : [active] + visible
        } ?? visible

        LoreWrappingHStack(spacing: AinkradSpacing.xs) {
            ForEach(shown, id: \.self) { tag in chip(tag) }
            if hidden > 0 && !expanded {
                AinkradChip(label: "+\(hidden)", systemName: "ellipsis") { expanded = true }
                    .accessibilityLabel("Show \(hidden) more tags")
            } else if expanded && tags.count > Self.collapsedLimit {
                AinkradChip(label: "Fewer", systemName: "chevron.up") { expanded = false }
                    .accessibilityLabel("Show fewer tags")
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        // The COUNT tells you whether a tag is worth filtering by before you
        // click it — a tag on two notes and one on two hundred look identical
        // otherwise.
        AinkradSwatchChip(label: "#\(tag) \(counts[tag] ?? 0)",
                          swatch: theme.tokens.accentSecondary,
                          isOn: activeTag == tag) {
            activeTag = (activeTag == tag) ? nil : tag
        }
        // The chip's ON state is a fill and nothing else, so whether a filter
        // is active was carried by colour alone.
        .accessibilityLabel(activeTag == tag
                            ? "Tag \(tag), filtering" : "Filter by tag \(tag)")
        .accessibilityAddTraits(activeTag == tag ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row of views that wraps onto the next line when it runs out of width.
///
/// SwiftUI has no wrapping stack before the layout protocol's `Layout`, and
/// this project targets macOS 14 — where `Layout` exists, so this is a plain
/// conformance rather than the `GeometryReader` contortion the same thing
/// needed a few years ago.
struct LoreWrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width
                                                    : current.width + spacing + size.width
            // A chip wider than the whole row still gets its own line rather
            // than being dropped: overflowing is visible, vanishing is not.
            if projected > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
