import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownStyleRenderer {
    /// The inline kinds of `add(_:)` — character-level styling inside a block.
    static func addInline(
        _ kind: StyleSpan.Kind, in r: NSRange,
        to storage: NSTextStorage,
        theme: MarkdownTheme
    ) {
        let tokens = theme.tokens
        switch kind {
        // Both compose onto `current` ITSELF, not onto a fresh
        // `.systemFont(ofSize: current.pointSize)`. Re-basing kept the size and
        // discarded the FAMILY, which was invisible while the body font was the
        // only family in play and became a bug the moment it was not: bold
        // inside a monospaced code span, or inside a heading, switched typeface
        // mid-run. `.tableHeader` below already did it this way and is the
        // model being followed.
        case .strong:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current).union(.boldFontMask),
                    to: current)
            }

        case .emphasis:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current).union(.italicFontMask),
                    to: current)
            }

        case .strikethrough:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: r)
            // Struck text recedes as well as being crossed out, which is what
            // Obsidian's `--text-faint` does for it. A line through text at
            // full contrast reads as emphasis; the point of the construct is
            // the opposite.
            storage.addAttribute(
                .foregroundColor,
                value: theme.color(theme.skin.text.muted),
                range: r)

        case .highlight:
            // A tinted BACKGROUND, not a foreground change: highlighted text
            // must stay as readable as the prose around it, which a colour
            // swap does not guarantee against every theme.
            storage.addAttribute(
                .backgroundColor,
                value: NSColor(tokens.accentSecondary).withAlphaComponent(theme.skin.opacity.o28),
                range: r)

        case .footnoteReference:
            // A real superscript: raised AND reduced. Both are drawing changes,
            // never text changes — no character is added, removed or replaced.
            //
            // The size reduction is what M6 left undone (final review, Finding
            // 5) and it is done now, so the reference reads as a mark on the
            // sentence rather than as a bracketed word inside it. The offset is
            // theme-relative rather than the flat 4.0 it was: at Comfortable's
            // 17 pt body a fixed 4 pt barely clears the baseline.
            composeFont(in: r, storage: storage) { $0.withSize($0.pointSize * 0.75) }
            storage.addAttribute(.baselineOffset, value: theme.bodySize * 0.28, range: r)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.accentPrimary), range: r)

        case .tag:
            // The `#` STAYS VISIBLE — Obsidian keeps it, and without it a tag
            // chip is indistinguishable from a link chip.
            //
            // `theme.renderTagsAsChips`, not `settings` — `settings` is never
            // in scope here; `MarkdownTheme` resolves it at construction. See
            // `EditorSettings.renderTagsAsChips`.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.accentPrimary), range: r)
        // The chip itself is DRAWN — see `MarkdownBlockBackgrounds.Kind
        // .tagPill`. It used to be a `.backgroundColor` here, which is a
        // per-glyph attribute and therefore cannot round its corners or
        // pad its ends: the result was a tight rectangle around the
        // letters that read as a selection, not as a tag. Nothing is
        // written here for the chip any more; the setting is honoured
        // where the region is built.

        case .blockID:
            // Near-invisible when the caret is elsewhere. It is machinery the
            // author needs to be able to find, not something to read past.
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(tokens.foreground).withAlphaComponent(theme.skin.opacity.o25),
                range: r)

        case .inlineCode:
            composeFont(in: r, storage: storage) { current in
                Self.applying(
                    Self.inheritedTraits(of: current),
                    to: .monospacedSystemFont(
                        ofSize: Self.monoSize(replacing: current, theme: theme),
                        weight: .regular))
            }
        // The pill is DRAWN — see `MarkdownBlockBackgrounds.Kind
        // .inlineCodePill`. It was a `.backgroundColor` here, which is a
        // per-glyph attribute: it cannot round its corners, cannot pad its
        // ends, and fills the whole LINE BOX rather than the text. At a
        // 1.5 line height that is half again as tall as the glyphs, which
        // is why the highlight looked like it belonged to the line above.
        // Nothing is written here for it any more.

        // Both links: colour at rest, underline ON HOVER only — see
        // `MarkdownEditor.Coordinator.hoverChanged(to:)`.
        //
        // `.link` used to carry a PERSISTENT underline and `.wikilink` none,
        // justified by the wikilink's own visible `[[…]]`. But in the state
        // the reader actually looks at, those brackets are COLLAPSED, so the
        // asymmetry amounted to underlining one kind of link and not the
        // other for a reason that is invisible at the moment it applies.
        // Obsidian underlines both, and only under the pointer.
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .wikilink:
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)

        case .embed:
            // The FALLBACK look — plain wikilink colouring, over the TARGET
            // text only (the `![[`/`]]` markers are separate `.marker(of:
            // .wikilink)` spans and style themselves) — for an embed that
            // `EmbedRendering` has not decorated: an unresolved target, a
            // resolver-less caller (a test, a plain-text engine), or a block
            // the caret is currently INSIDE, which `EmbedRendering.
            // applyEmbeds` deliberately leaves as plain revealed source so a
            // typo'd target can be edited — see that function's doc comment.
            // `applyEmbeds` runs immediately after this in both `renderStyles`
            // (a full render) and `restyleBlock` (the per-block caret path,
            // fix round 1 Critical 2), and overwrites this wherever it can
            // resolve the target AND the block is not the one being edited.
            storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: r)
        default:
            break
        }
    }
}
