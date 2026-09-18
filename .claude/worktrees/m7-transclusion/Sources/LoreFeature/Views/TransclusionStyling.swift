import AppKit
import SwiftUI
import AinkradAppKit

/// Makes room for a transcluded note, and paints it.
///
/// The same three techniques `MarkdownMathStyling` and `MarkdownTableStyling`
/// use, for the same reason: the `![[note]]` source is COLLAPSED by the marker
/// machinery, its measured height is RESERVED as a paragraph line height, and
/// the target's content is DRAWN into the gap that leaves. The document's text
/// is never touched — no `U+FFFC`, no rewritten bytes — which is the rule that
/// ruled out an `NSTextAttachment` here exactly as it did for a table.
///
/// ## Why measure and draw travel together
///
/// `prepare` returns a `TransclusionLayout.Box` per embed, carrying BOTH the
/// reserved height and the attributed string that height was measured from.
/// The draw pass never restyles the content itself. A block measured one way
/// and reserved another is drawn over the paragraph beneath it — the defect
/// recorded at `MarkdownEditor.swift:197`.
///
/// ## Why it runs in the collapse pass
///
/// `MarkdownStyleRenderer.collapse` resets attributes over every hidden
/// marker, and `restyle` resets a whole block's. A reservation written before
/// either would be wiped. So the reservation rides the same pass as the
/// collapse, and the regions it hands back are built from that one layout.
@MainActor
enum TransclusionStyling {

    /// The height reserved for an embed that has no usable measurement yet —
    /// ONE line, never zero. A zero-height gap is invisible until it fills,
    /// and then pops the document down by a screenful.
    static func placeholderHeight(font: NSFont) -> CGFloat {
        font.ascender - font.descender
    }

    /// Collapses, reserves and returns the drawing regions for every
    /// transclusion embed in `spans`.
    ///
    /// - Parameter selection: the live selection. An embed the caret is
    ///   literally inside is REVEALED — its raw `![[…]]` source stays visible,
    ///   nothing is collapsed, nothing is reserved and no region is produced —
    ///   which is `EmbedRendering.isEmbedRevealed`'s rule, shared verbatim so
    ///   an image embed and a transcluded one can never disagree about what
    ///   "the caret is in it" means.
    /// - Parameter width: the TEXT COLUMN's width, which is also the width the
    ///   draw pass paints across. Measuring at one width and painting at
    ///   another is the divergence this whole file exists to avoid.
    /// - Returns: one region per embed that was actually collapsed.
    static func prepare(_ spans: [StyleSpan], selection: NSRange,
                        width: CGFloat, theme: MarkdownTheme,
                        resolve: (String) -> URL?,
                        cache: TransclusionCache,
                        in storage: NSTextStorage) -> [MarkdownBlockBackgrounds.Region] {
        let text = storage.string as NSString
        let font = MarkdownStyleRenderer.baseFont
        var out: [MarkdownBlockBackgrounds.Region] = []

        for span in spans {
            guard case .embed(let target, let fullRange) = span.kind else { continue }
            let full = NSRange(location: fullRange.lowerBound, length: fullRange.count)
            guard full.length > 0, NSMaxRange(full) <= storage.length else { continue }
            guard case .transclusion(let url) = EmbedRendering.kind(for: resolve(target))
            else { continue }
            if MarkdownEditor.Coordinator.isEmbedRevealed(full, selection: selection) { continue }
            // ALONE on its paragraph, or not transcluded at all — the same
            // guard, and the same reasoning, an image embed uses (see
            // `EmbedRendering.isAloneOnItsParagraph`). The reservation this
            // function writes is a PARAGRAPH line height and the region it
            // returns is a full-column panel: an embed sharing its line with
            // prose would have that prose stretched to the note's height and
            // then painted over, and two embeds in one paragraph would fight
            // over the same line height and draw into the same rect. A
            // mid-sentence transclusion therefore degrades to the chip/link
            // treatment instead, applied by `applyEmbeds` — which asks this
            // same question, so the two can never disagree.
            guard EmbedRendering.isAloneOnItsParagraph(fullRange: full, in: text) else {
                continue
            }

            let box = self.box(for: url, rawTarget: target, width: width,
                               theme: theme, cache: cache, font: font)

            // Collapse LAST-but-one, and over `fullRange` rather than the
            // target text alone: a visible `![[note]]` floating above the
            // note's own content would be worse than the raw markdown it
            // replaces. Exactly what `applyEmbeds` does for an image.
            MarkdownStyleRenderer.collapse([full.location..<NSMaxRange(full)], in: storage)

            // The reservation goes on the embed's own PARAGRAPH — copied from
            // whatever style is already there, never replaced, so an embed
            // inside a list item or a quote keeps that block's indent. The
            // same care `MarkdownMathStyling.reserveSpace` documents.
            let paragraph = text.paragraphRange(for: full)
            let existing = storage.attribute(.paragraphStyle, at: paragraph.location,
                                             effectiveRange: nil) as? NSParagraphStyle
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = box.height
            style.maximumLineHeight = box.height
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)

            out.append(MarkdownBlockBackgrounds.Region(kind: .transclusion(box),
                                                       range: full))
        }
        return out
    }

    /// The measured box for one target, through the cache.
    ///
    /// A cache HIT costs no layout and records no measurement — that is the
    /// property `MarkdownRevealBenchmark.test_typingInHostDoesNotRemeasureEmbeds`
    /// pins. A miss measures once and stores the height back.
    ///
    /// A width that is not yet real (the container has no size during the
    /// first layout pass) reserves ONE LINE and stores NOTHING, so the next
    /// pass — at a real width — is the one that measures. Reserving zero there
    /// and filling it later is what makes an embed pop.
    private static func box(for url: URL, rawTarget: String, width: CGFloat,
                            theme: MarkdownTheme, cache: TransclusionCache,
                            font: NSFont) -> TransclusionLayout.Box {
        let key = TransclusionKey(path: url, mtime: modificationDate(of: url),
                                  fragment: fragmentName(of: rawTarget))
        let content = cache.content(for: key) {
            resolveContent(url: url, rawTarget: rawTarget)
        }

        guard width.isFinite, width > TransclusionLayout.framePadding * 2 else {
            return TransclusionLayout.Box(
                text: NSAttributedString(string: ""),
                innerWidth: 1,
                height: placeholderHeight(font: font))
        }

        // The geometry this measurement would be true FOR. A stored height
        // taken at any other width or type scale is a miss — see
        // `TransclusionMeasurement`. This is what makes a window resize or a
        // font-size change self-correct on the very next render, without
        // depending on anything remembering to invalidate.
        let geometry = TransclusionMeasurement(height: 0, width: width,
                                               bodySize: theme.bodySize,
                                               lineHeightMultiple: theme.lineHeightMultiple)
        if let cached = cache.measuredHeight(for: key, matching: geometry) {
            return TransclusionLayout.box(for: content, width: width, theme: theme,
                                          measuredHeight: cached)
        }
        let box = TransclusionLayout.box(for: content, width: width, theme: theme)
        cache.setMeasurement(TransclusionMeasurement(height: box.height, width: width,
                                                     bodySize: theme.bodySize,
                                                     lineHeightMultiple: theme.lineHeightMultiple),
                             for: key)
        return box
    }

    /// Resolves one target to the slice it should show.
    ///
    /// Reuses `TransclusionResolver` whole rather than re-deriving fragment
    /// slicing here — that logic is Task 2's and is tested there. The resolver
    /// it needs is built around the ONE url the editor's own
    /// `resolveEmbedTarget` already picked, registered under the raw target's
    /// own basename so `LinkResolver.resolve` returns it: the vault-wide
    /// resolution decision has already been made by the shell, and re-making
    /// it here from a second index is how the two would come to disagree.
    ///
    /// `path: [url]` is NOT passed — the cycle check needs the ancestors of
    /// this embed, and a top-level embed has none. Nested embeds inside the
    /// transcluded text are not themselves expanded (the drawn content is one
    /// flat slice), so the depth cap is never reached from here.
    private static func resolveContent(url: URL, rawTarget: String) -> TransclusionContent {
        let name = LinkResolver.basename(of: rawTarget)
        let resolver = LinkResolver(documents: [(url: url, title: name, aliases: [])])
        return TransclusionResolver.resolve(rawTarget: rawTarget, resolver: resolver,
                                            path: []) { target in
            try String(contentsOf: target, encoding: .utf8)
        }
    }

    private static func fragmentName(of rawTarget: String) -> String? {
        switch LinkResolver.fragment(of: rawTarget) {
        case .some(.heading(let heading)): return heading
        case .some(.block(let id)): return "^" + id
        case .none: return nil
        }
    }

    /// The target's mtime, part of the cache key. A file that cannot be
    /// stat'd gets `.distantPast`, which is stable — so an unreadable target
    /// is cached as unreadable rather than re-read on every render.
    private static func modificationDate(of url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Paints one transcluded note into the gap `prepare` reserved.
    ///
    /// A left rule in the accent-secondary tint says "this is somebody else's
    /// text"; a hairline frame in muted foreground bounds it. Both colours
    /// come from the palette the rest of the decoration already uses — no new
    /// constants.
    ///
    /// - Parameter columnX/columnWidth: the same text-column geometry a code
    ///   panel is drawn against. The collapsed run's own rect is 0.01 pt wide
    ///   and says nothing about how wide the note should be, so only its Y and
    ///   height are taken from it.
    static func draw(_ box: TransclusionLayout.Box, at range: NSRange,
                     columnX x: CGFloat, columnWidth width: CGFloat,
                     rule: NSColor, frame: NSColor,
                     in textView: NSTextView, origin: NSPoint, dirtyRect: NSRect) {
        var rect = MarkdownBlockBackgrounds.boundingRect(of: range, in: textView)
        guard !rect.isNull, !rect.isEmpty else { return }
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let panel = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
        guard panel.intersects(dirtyRect.insetBy(dx: -400, dy: -400)) else { return }

        frame.setStroke()
        let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: MarkdownBlockBackgrounds.cornerRadius,
                                  yRadius: MarkdownBlockBackgrounds.cornerRadius)
        border.lineWidth = 1
        border.stroke()

        rule.setFill()
        NSBezierPath(roundedRect: NSRect(x: panel.minX, y: panel.minY,
                                         width: MarkdownBlockBackgrounds.barWidth,
                                         height: panel.height),
                     xRadius: MarkdownBlockBackgrounds.barWidth / 2,
                     yRadius: MarkdownBlockBackgrounds.barWidth / 2).fill()

        guard box.text.length > 0 else { return }
        let padding = TransclusionLayout.framePadding
        // Wrapped at `innerWidth`, which is the measure the height was taken
        // at — not at whatever the panel happens to be now.
        box.text.draw(with: NSRect(x: panel.minX + padding, y: panel.minY + padding,
                                   width: box.innerWidth,
                                   height: max(1, panel.height - padding * 2)),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
