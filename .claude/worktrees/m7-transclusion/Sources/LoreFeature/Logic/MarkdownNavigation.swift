import Foundation

/// Where a plain click on a footnote or a tag lands, computed as a PURE
/// function of the style spans and the clicked offset — no `NSTextView`
/// involved — so the click routing itself is testable without hosting a
/// real text view.
///
/// ## Why filter by kind first
///
/// `MarkdownEditor.Coordinator.styleSpans` is `astStyleSpans + wikilinkSpans
/// + mathSpans + extensionSpans`, in that order, and `spliceBlock` preserves
/// it — see `MarkdownStyleCache`. A tag or footnote sitting inside a list
/// item, blockquote, callout, table row, heading, or an emphasis/strong run
/// emits a CONTAINING span earlier in that array. `first(where: { $0.range
/// .contains(index) })` over the whole array returns that container, not the
/// extension span — so a `#tag` inside a bullet list, or `[^1]` inside a
/// callout, silently did nothing. See the M6 final-review Finding 1.
///
/// The fix is to filter to the KIND being routed to FIRST — a list item's
/// `.listItem` span never matches `.tag`/`.footnoteReference`/
/// `.footnoteDefinition` — and only then look for the containing span. This
/// is the same shape `TaskCheckbox.items(in:text:)` already uses for
/// `.checkbox`, extended to two more kinds.
enum MarkdownNavigation {

    /// The smallest span, among `spans` already filtered to the routed
    /// kind(s), that contains `index`. "Smallest" rather than merely "first"
    /// because a kind filter alone is not proof of no nesting — the same
    /// kind should never nest within itself for tags/footnotes today, but
    /// picking the innermost match costs nothing and stays correct even if
    /// that ever changes.
    private static func innermost(_ spans: [StyleSpan], containing index: Int) -> StyleSpan? {
        spans.filter { $0.range.contains(index) }
            .min { $0.range.count < $1.range.count }
    }

    /// The offset a footnote click should jump to, or `nil` when `index`
    /// does not sit inside a footnote reference/definition, or the label has
    /// no counterpart (an unmatched footnote — emit nothing rather than jump
    /// somewhere wrong).
    static func footnoteJumpTarget(in spans: [StyleSpan], at index: Int) -> Int? {
        let footnoteSpans = spans.filter {
            switch $0.kind {
            case .footnoteReference, .footnoteDefinition: return true
            default: return false
            }
        }
        guard let hit = innermost(footnoteSpans, containing: index) else { return nil }
        switch hit.kind {
        case .footnoteReference(let label):
            guard let definition = footnoteSpans.first(where: {
                if case .footnoteDefinition(let defLabel) = $0.kind { return defLabel == label }
                return false
            }) else { return nil }
            return definition.range.lowerBound
        case .footnoteDefinition(let label):
            guard let reference = footnoteSpans.first(where: {
                if case .footnoteReference(let refLabel) = $0.kind { return refLabel == label }
                return false
            }) else { return nil }
            return reference.range.lowerBound
        default:
            return nil
        }
    }

    /// The `.tag` span `index` sits inside, or `nil`. The CACHED name on
    /// that span is not returned here — see `liveTagName(forSpan:in:)` below
    /// and Finding 12: `styleCache.spans` can lag the live text by up to one
    /// styling debounce, so the span's own offset is a candidate for
    /// LOCATING the click, never an authority on what the live text there
    /// actually spells.
    static func tagSpan(in spans: [StyleSpan], at index: Int) -> StyleSpan? {
        let tagSpans = spans.filter {
            if case .tag = $0.kind { return true }
            return false
        }
        return innermost(tagSpans, containing: index)
    }

    /// Re-derives the tag name from `text` at `range`, rather than trusting
    /// the cached span's associated value — same "candidate, never an
    /// authority" pattern `toggleTask` uses via `TaskCheckbox.markerRange`.
    ///
    /// Mirrors `MarkdownExtensions.scanTags`' own validation (leading `#`,
    /// at least one non-digit, trailing `/` trimmed) rather than re-scanning
    /// the whole document: this only has to answer for the one already-
    /// located range, not find one from scratch.
    static func liveTagName(forSpan range: Range<Int>, in text: NSString) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= text.length, range.count >= 2
        else { return nil }
        guard text.character(at: range.lowerBound) == 0x23 else { return nil }   // #
        let raw = text.substring(with: NSRange(location: range.lowerBound + 1,
                                               length: range.count - 1))
        var hasNonDigit = false
        for scalar in raw.unicodeScalars {
            let u = scalar.value
            let isDigit = (u >= 0x30 && u <= 0x39)
            let isLetter = (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u > 0x7F
            let isJoiner = u == 0x5F || u == 0x2D || u == 0x2F   // _ - /
            guard isDigit || isLetter || isJoiner else { return nil }
            if isLetter || isJoiner { hasNonDigit = true }
        }
        guard hasNonDigit, !raw.isEmpty else { return nil }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        return trimmed.isEmpty ? nil : trimmed
    }
}
