import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownEditor.Coordinator {
    // MARK: - Click-to-open

    /// Returns whether a link was actually opened.
    func openLink(atUTF16 index: Int) -> Bool {
        guard let tv = textView, let onOpenLink else { return false }
        let text = tv.string
        guard let clicked = Range(NSRange(location: index, length: 0), in: text)?.lowerBound
        else { return false }
        let offset = text.distance(from: text.startIndex, to: clicked)
        guard let target = LinkCompletionContext.target(in: text, at: offset)
        else { return false }
        onOpenLink(target)
        return true
    }

    /// A click inside a RENDERED transclusion (`transclusionRegions`,
    /// built by `TransclusionStyling.prepare` every render pass — see
    /// `MarkdownEditorDecoration`) opens the embed's source note; ⌥-click
    /// opens it beside, through `onOpenLinkBeside` — the same
    /// `store.openInSecondaryPane` path an ⌥-click already opens a
    /// sidebar row beside (`LoreRootView.openRow`), not a second one.
    ///
    /// ALWAYS returns `true` once `index` falls inside a transclusion
    /// region, whether or not a handler actually fires — the region is
    /// COLLAPSED source (`TransclusionStyling.prepare` collapses it every
    /// time it is not the one the caret is literally inside), so once a
    /// click lands here it must never fall through to
    /// `super.mouseDown`'s caret placement: doing so would be exactly the
    /// "caret inside drawn content" the M6 rule forbids. The `defer`
    /// parks the caret right after the embed instead — the same "caret
    /// goes just past what the click activated" contract `toggleTask`
    /// already keeps for a flipped checkbox.
    @MainActor func openTransclusion(atUTF16 index: Int, beside: Bool) -> Bool {
        guard let tv = textView else { return false }
        guard
            let region = transclusionRegions.first(where: { region in
                guard case .transclusion = region.kind else { return false }
                return index >= region.range.location && index <= NSMaxRange(region.range)
            })
        else { return false }

        defer {
            tv.setSelectedRange(NSRange(location: NSMaxRange(region.range), length: 0))
        }

        let ns = tv.string as NSString
        guard NSMaxRange(region.range) <= ns.length else { return true }
        // Re-read the LIVE text at the region's own range rather than
        // trusting a cached target string — the same "cached offset is a
        // candidate, never an authority" rule `toggleTask`'s doc comment
        // spells out. `region.range` is the WHOLE source form (`!`, both
        // brackets, the target — see `StyleSpan.Kind.embed`'s doc
        // comment), so stripping the fixed `![[`/`]]` delimiters is
        // enough; anything else here means the live text no longer
        // matches what this region was built from, and the click is
        // simply absorbed rather than opening something stale.
        let raw = ns.substring(with: region.range)
        guard raw.hasPrefix("![["), raw.hasSuffix("]]") else { return true }
        let target = String(raw.dropFirst(3).dropLast(2))
        guard !target.isEmpty else { return true }

        if beside {
            onOpenLinkBeside?(target)
        } else {
            onOpenLink?(target)
        }
        return true
    }

    // MARK: - Plain click: footnote jump and tag filter

    /// Dispatches a plain (unmodified, single) click to whichever of the
    /// three navigation affordances owns the clicked offset, in the same
    /// fall-through spirit as `toggleTask` — `false` means "not mine",
    /// and the caret lands exactly where the user clicked.
    ///
    /// All three work in a READ-ONLY session: they navigate, they never
    /// write, so none of them consults `allowsTaskToggle` or any
    /// read-only gate the way `toggleTask` does.
    @MainActor func handlePlainClick(atUTF16 index: Int) -> Bool {
        if toggleTask(atUTF16: index) { return true }
        if jumpFootnote(atUTF16: index) { return true }
        // `selectTag` always returns `false` — see its doc comment
        // (Finding 7): it fires `onTagClick` as a side effect but never
        // claims the click, so the caret still lands where the user
        // clicked and `#tagg` stays editable.
        _ = selectTag(atUTF16: index)
        // `.blockID` is an anchor, not a control — deliberately no case
        // for it here. A click on one falls through to ordinary caret
        // placement, same as clicking any other plain text.
        return false
    }

    /// A click on a `[^label]` reference lands on its `[^label]:`
    /// definition; a click on the definition's own label lands back on
    /// the FIRST reference sharing that label. Located via
    /// `MarkdownNavigation.footnoteJumpTarget`, which filters
    /// `styleCache.spans` to the footnote KINDS before matching offsets —
    /// a plain `first(where: { $0.range.contains(index) })` over the
    /// whole array (AST spans first, extension spans last — see
    /// `MarkdownDocumentModel.styleSpans`) would return whatever
    /// CONTAINING span got there first: a list item, a blockquote, a
    /// callout — and never reach the footnote at all. See the M6 final
    /// review, Finding 1. A stale cache can only pick a stale
    /// destination, never an out-of-bounds one, since `scrollToOffset`
    /// clamps to `[0, length]`.
    @MainActor private func jumpFootnote(atUTF16 index: Int) -> Bool {
        guard
            let target = MarkdownNavigation.footnoteJumpTarget(
                in: styleCache.spans, at: index)
        else { return false }
        scrollToOffset(target)
        return true
    }

    /// A click on a `#tag` sets `activeTag` — the SAME filter
    /// `TagChipRow`/`NoteListView` share via `EditorContext.onTagClick` —
    /// so a tag clicked in the body does exactly what one clicked in the
    /// sidebar does. No new channel: this rides the existing binding all
    /// the way up through `DocumentPane`/`DocumentPaneColumn`.
    ///
    /// Located via `MarkdownNavigation.tagSpan`, which filters to `.tag`
    /// spans before matching offsets — see `jumpFootnote`'s comment for
    /// why a plain `first(where:)` over the whole span array cannot
    /// reach a tag nested in a list item or blockquote (Finding 1).
    ///
    /// ALWAYS returns `false`. The filter fires as a side effect, but the
    /// click itself is never swallowed: `toggleTask` deliberately
    /// preserves "the caret goes here", and a swallowed click on `#tagg`
    /// would make the typo the one span the user cannot click into to
    /// fix — see Finding 7. `jumpFootnote` above is the opposite case on
    /// purpose: it swallows, because a footnote click is about to scroll
    /// the caret elsewhere anyway.
    @MainActor private func selectTag(atUTF16 index: Int) -> Bool {
        guard let onTagClick, let hit = MarkdownNavigation.tagSpan(in: styleCache.spans, at: index),
            let tv = textView,
            // Finding 12: the cached span's associated `name` is a
            // CANDIDATE, never an authority — re-derive it from the
            // live text the way `toggleTask` re-reads `tv.string`
            // rather than trusting `styleCache`, which may lag by up
            // to one styling debounce.
            let name = MarkdownNavigation.liveTagName(forSpan: hit.range, in: tv.string as NSString)
        else { return false }
        onTagClick(name)
        return false
    }
}
