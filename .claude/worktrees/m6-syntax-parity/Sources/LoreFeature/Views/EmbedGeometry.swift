import AppKit

/// Pure geometry for positioning an inline embed image within its paragraph.
///
/// Extracted out of `LinkTextView.drawEmbedImages` so the two failure modes
/// fixed here — an RTL paragraph's image floating past the right margin, and
/// an over-wide image overflowing either edge — can be pinned by a headless
/// XCTest, with no `NSTextView`, no window and no live layout involved. See
/// `EmbedRendering.applyEmbeds` for where `writingDirection`/`indent` are
/// derived and stashed on `MarkdownEditor.Coordinator.EmbedImageRegion`.
enum EmbedGeometry {

    /// Where an embed image should draw, in CONTAINER-LOCAL coordinates — 0
    /// at the text container's own leading edge (`textContainerOrigin.x` in
    /// view space — see `MarkdownBlockBackgrounds.columnX`'s doc comment on
    /// why that, and NOT `textContainerInset.width`, is the only coordinate
    /// source that still agrees once `MarkdownEditorLayout` centres a
    /// capped-width column: `textContainerInset.width` only happened to
    /// match while the column was flush against the view's edge).
    ///
    /// PRECONDITION, enforced by the caller, not by this function: the embed
    /// must be ALONE on its paragraph — `EmbedRendering.applyEmbeds` never
    /// calls this (never builds an `EmbedImageRegion` at all) unless
    /// `isAloneOnItsParagraph` said so; a mid-paragraph embed
    /// (`"Before ![[a.png]] after."`) renders as a CHIP instead, over the
    /// target text only, same as a document embed — see that guard's doc
    /// comment for why (this function's margin-anchored answer would paint
    /// over "Before "/"after." otherwise, since it has no idea where either
    /// one ends). This function has no way to check that precondition
    /// itself — it receives only a width and an indent, not a range — so
    /// violating it at the call site is a silent mispositioning bug, not a
    /// crash; `EmbedDecorationTests.test_midParagraphEmbed_rendersAsAChipNotAnImage`
    /// is the regression guard for the call site holding up its end.
    ///
    /// The caller (`LinkTextView.drawEmbedImages`) translates `origin.x`
    /// into view space by adding `textContainerOrigin.x`, and always
    /// overrides `y` with the glyph rect's own `minY` — the vertical
    /// position is not part of the bug this function exists to fix, so `y`
    /// here is always 0.
    ///
    /// - Parameters:
    ///   - containerWidth: the text container's usable width — the SAME
    ///     value `EmbedRendering.applyEmbeds` already caps the image's SIZE
    ///     against (`maxWidth = containerWidth - 32`), so an image this
    ///     function positions can never need more room than it was scaled to
    ///     fit, and the overflow clamp below is a belt-and-braces guard
    ///     against float error and mismatched cache entries, not the primary
    ///     defence.
    ///   - writingDirection: the paragraph's RESOLVED (non-`.natural`) base
    ///     writing direction — see `contextualWritingDirection`. NEVER
    ///     derived from the embed's OWN paragraph text: that text is just
    ///     `![[filename]]`, and a filename is very often Latin even inside
    ///     an Arabic document, which would resolve LTR every time and never
    ///     fire the RTL branch the owner actually needs.
    ///   - indent: the paragraph's `firstLineHeadIndent`, measured from the
    ///     READING-direction start margin — the same convention TextKit
    ///     itself uses for that attribute, which is why this needs no
    ///     left/right translation of its own: `0` for a top-level paragraph,
    ///     `theme.listIndentStep * n` inside a list or blockquote, on
    ///     EITHER side.
    ///   - lineFragmentPadding: `NSTextContainer.lineFragmentPadding`
    ///     (AppKit's own default is 5pt, and nothing in this codebase zeroes
    ///     it). TextKit adds this padding at BOTH ends of every line
    ///     fragment, and the OLD `rect.minX`-based code inherited it for
    ///     free because a glyph rect already includes it. Reproducing that
    ///     spacing here — rather than silently dropping it — is what keeps
    ///     the previously-working top-level LTR case pixel-identical to
    ///     before this fix, instead of drifting 5pt left.
    ///   - imageSize: the image's already width/height-capped draw size —
    ///     see `applyEmbeds`'s `maxWidth`/`maxHeight`.
    ///
    /// Deliberately never reads a glyph rect's `x`/`width` — the root cause
    /// this fixes. For a COLLAPSED, near-zero-width source run, TextKit
    /// places that run against whichever margin is the line's END in its
    /// writing direction — the RIGHT margin for RTL — so an x read off that
    /// rect is trustworthy only for LTR, and even there only by coincidence.
    /// Deriving the origin from the writing direction and container width
    /// directly, instead, is correct for both and needs no special case.
    static func drawRect(containerWidth: CGFloat, writingDirection: NSWritingDirection,
                          indent: CGFloat, lineFragmentPadding: CGFloat = 0,
                          imageSize: NSSize) -> NSRect {
        let clampedIndent = max(0, indent)
        let clampedPadding = max(0, lineFragmentPadding)
        let x: CGFloat = writingDirection == .rightToLeft
            // Grows LEFTWARD from the right margin, itself inset by the
            // line fragment's own trailing padding.
            ? containerWidth - clampedPadding - clampedIndent - imageSize.width
            // Grows RIGHTWARD from the left margin, inset by the line
            // fragment's leading padding.
            : clampedPadding + clampedIndent

        // Clamp: an image wider than the room its own indent (and padding)
        // leaves — or simply wider than the container — must still land
        // fully on-screen rather than painting past either edge.
        // `upperBound` never goes negative even when
        // `imageSize.width > containerWidth`, so the clamp always has a
        // valid (if fully left-pinned) answer, on EITHER side, for EITHER
        // direction.
        let upperBound = max(0, containerWidth - imageSize.width)
        let clampedX = min(max(x, 0), upperBound)
        return NSRect(x: clampedX, y: 0, width: imageSize.width, height: imageSize.height)
    }

    /// The writing direction an embed image should draw with, resolved from
    /// its SURROUNDING CONTEXT rather than its own paragraph.
    ///
    /// Fix round 1, Critical 1: an embed's own paragraph is just
    /// `![[filename]]` (plus whitespace, or a list marker) — its first
    /// strong character is very often the LATIN filename even inside an
    /// otherwise entirely Arabic document, so resolving direction from that
    /// text alone resolved `.leftToRight` for the owner's actual notes and
    /// never exercised the RTL branch at all.
    ///
    /// Three-tier fallback, each tier answering "what direction is the
    /// PROSE around this embed actually written in":
    /// 1. The nearest PRECEDING non-blank paragraph with a strong character
    ///    — the ordinary case: a screenshot follows the Arabic sentence it
    ///    illustrates.
    /// 2. The nearest FOLLOWING one — an embed that opens a document, or
    ///    sits right after a blank line with nothing written above it yet.
    /// 3. `documentFallback` — the document's own dominant direction (see
    ///    `MarkdownEditor.Coordinator.documentWritingDirection`), for the
    ///    degenerate case of an embed with no strongly-directional text
    ///    anywhere near it (e.g. the ENTIRE document is just this one
    ///    image).
    ///
    /// Tiers 1/2 are bounded to `maxHops` paragraphs each — a handful, not
    /// the whole document — so a pathological run of blank-ish paragraphs
    /// can never turn one embed's styling pass into an unbounded scan; the
    /// realistic case (prose immediately above or below the image) resolves
    /// in one hop.
    static func contextualWritingDirection(paragraph: NSRange, in text: NSString,
                                           documentFallback: NSWritingDirection = .leftToRight,
                                           maxHops: Int = 20) -> NSWritingDirection {
        if let dir = nearestStrongDirection(before: paragraph, in: text, maxHops: maxHops) {
            return dir
        }
        if let dir = nearestStrongDirection(after: paragraph, in: text, maxHops: maxHops) {
            return dir
        }
        return documentFallback
    }

    private static func nearestStrongDirection(before paragraph: NSRange, in text: NSString,
                                                maxHops: Int) -> NSWritingDirection? {
        var location = paragraph.location
        var hops = 0
        while location > 0, hops < maxHops {
            let priorRange = text.paragraphRange(for: NSRange(location: location - 1, length: 0))
            if let dir = strongWritingDirection(of: text.substring(with: priorRange)) { return dir }
            guard priorRange.location < location else { break }   // safety: never loop in place
            location = priorRange.location
            hops += 1
        }
        return nil
    }

    private static func nearestStrongDirection(after paragraph: NSRange, in text: NSString,
                                                maxHops: Int) -> NSWritingDirection? {
        var location = NSMaxRange(paragraph)
        var hops = 0
        while location < text.length, hops < maxHops {
            let nextRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            if let dir = strongWritingDirection(of: text.substring(with: nextRange)) { return dir }
            let advanced = NSMaxRange(nextRange)
            guard advanced > location else { break }   // safety: never loop in place
            location = advanced
            hops += 1
        }
        return nil
    }

    /// A string's base writing direction, resolved approximately the way
    /// TextKit resolves `.natural`: the FIRST alphabetic character decides
    /// it (UAX#9 rule P2/P3, simplified) — a character from an RTL script
    /// (Arabic, Hebrew, Syriac, Thaana, N'Ko, and their presentation-form
    /// blocks) makes it RTL, any other letter makes it LTR. `nil` — not a
    /// default — when the string has no strong character at all (digits/
    /// punctuation only, or empty), so callers can tell "genuinely neutral,
    /// keep looking elsewhere" apart from "resolved LTR": the whole point of
    /// `contextualWritingDirection`'s multi-tier fallback.
    ///
    /// `Unicode.Scalar.Properties` has no bidi-class accessor in the Swift
    /// standard library (that is an ICU-level property this platform does
    /// not expose to Swift), so this checks scalar VALUE against the RTL
    /// script blocks directly rather than a proper bidi classification —
    /// approximate, not a full UAX#9 implementation, but exactly what
    /// matters for "is this text Arabic (or another RTL script)":
    /// script-mixed bidi runs within one paragraph are out of scope, same as
    /// they are for TextKit's own `.natural` resolution at the paragraph
    /// level.
    static func strongWritingDirection(of text: String) -> NSWritingDirection? {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return Self.rtlScriptRanges.contains(where: { $0.contains(scalar.value) })
                ? .rightToLeft : .leftToRight
        }
        return nil
    }

    /// Convenience over `strongWritingDirection(of:)` for callers (and
    /// tests) that just want a definite answer for a single string with no
    /// further fallback tier to try — `.leftToRight` when neutral, matching
    /// this app's existing LTR-only default.
    static func naturalWritingDirection(of text: String) -> NSWritingDirection {
        strongWritingDirection(of: text) ?? .leftToRight
    }

    /// Unicode code point ranges for scripts that read right-to-left:
    /// Hebrew, Arabic (plus its Supplement and Extended-A blocks), Syriac
    /// (plus its Supplement), Thaana, N'Ko, and the Hebrew/Arabic
    /// presentation-form compatibility blocks.
    private static let rtlScriptRanges: [ClosedRange<UInt32>] = [
        0x0590...0x05FF,   // Hebrew
        0x0600...0x06FF,   // Arabic
        0x0700...0x074F,   // Syriac
        0x0750...0x077F,   // Arabic Supplement
        0x0780...0x07BF,   // Thaana
        0x07C0...0x07FF,   // N'Ko
        0x0860...0x086F,   // Syriac Supplement
        0x08A0...0x08FF,   // Arabic Extended-A
        0xFB1D...0xFB4F,   // Hebrew presentation forms
        0xFB50...0xFDFF,   // Arabic presentation forms A
        0xFE70...0xFEFF,   // Arabic presentation forms B
    ]
}
