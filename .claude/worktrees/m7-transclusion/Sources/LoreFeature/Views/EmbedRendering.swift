import AppKit
import SwiftUI
import AinkradAppKit

/// How an `![[target]]` embed is drawn.
///
/// Only images render inline. A PDF or a Word file embedded inline would mean
/// running a second document's renderer inside the editor's text container —
/// unbounded height, a second scroll context, and a live PDFKit view per embed
/// in a note that might have twenty. A chip says what the document is and
/// lets the existing wikilink click path open it, which is what the reader
/// actually wants.
public enum EmbedKind: Equatable {
    case image(URL)
    /// A markdown note, rendered inline by the transclusion path. Was a
    /// `.chip` before M7 — the comment above about "a second document's
    /// renderer inside the editor" still holds for PDFs and Word files,
    /// which is why those stay chips. A markdown note is different in kind:
    /// this editor already knows how to lay one out.
    case transclusion(URL)
    case chip(URL)
    case unresolved
}

public enum EmbedRendering {
    /// Case-insensitive: `EmbedRenderingTests` asserts `"PNG"` renders inline
    /// too, because a target is written by hand and Obsidian vaults are full
    /// of screenshots saved with an upper-case extension.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg",
    ]

    /// Case-insensitive for the same reason `imageExtensions` is —
    /// `EmbedRenderingTests.test_markdownTargetIsCaseInsensitive` pins
    /// `"NOTE.MD"`.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    public static func kind(for target: URL?) -> EmbedKind {
        guard let target else { return .unresolved }
        let ext = target.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image(target) }
        if markdownExtensions.contains(ext) { return .transclusion(target) }
        return .chip(target)
    }

    /// The chip's pill: a background box plus the same colour and underline
    /// an ordinary link gets, over the TARGET text ONLY — `r` here is
    /// `StyleSpan.range` for a `.embed` span, which since fix round 1
    /// (Important 6 / Critical 1) is the filename alone (`Contract.pdf`),
    /// the `![[`/`]]` markers having become separate `.marker(of: .wikilink)`
    /// spans that the existing reveal machinery collapses. Painting the pill
    /// over that target range is what makes the chip actually READ as
    /// "Contract.pdf" rather than the raw `![[Contract.pdf]]` source — the
    /// bug this fix round's Critical 1 reported. The text stays real,
    /// unmodified characters, so it also stays clickable through the
    /// existing wikilink click path (`LinkCompletionContext.target(in:at:)`
    /// recognises `[[…]]` regardless of a leading `!`), rather than a
    /// rasterized `EmbedChip` behind an `NSTextAttachment`. `tokens.
    /// surfaceElevated` is used rather than the brief's
    /// `theme.tokens.secondaryBackground`, which `HostThemeTokens` does not
    /// expose; it is the same token `.inlineCode` already uses for a
    /// background box.
    ///
    /// No filename ICON: `NSWorkspace.shared.icon(forFile:)` was in the
    /// brief's sketch, but drawing one would need to reserve horizontal
    /// space before the target text the same way an inline image needs to
    /// reserve a line height — and, per `applyEmbeds`'s note on Important 7,
    /// that reservation is not achievable without an attachment character.
    /// Left out rather than drawn with a real risk of overlapping the
    /// preceding character; flagged as a follow-up in the task report.
    static func applyChipStyling(over range: NSRange, to storage: NSTextStorage,
                                 tokens: HostThemeTokens) {
        storage.addAttribute(.backgroundColor,
                             value: NSColor(tokens.surfaceElevated).withAlphaComponent(0.6),
                             range: range)
        storage.addAttribute(.foregroundColor, value: NSColor(tokens.accentPrimary), range: range)
        storage.addAttribute(.underlineStyle,
                             value: NSUnderlineStyle.single.rawValue, range: range)
    }

    /// True when `fullRange`, trimmed of the whitespace `MarkdownReveal.
    /// blocks`/`paragraphRange` would also trim, IS the paragraph — i.e. the
    /// embed is the only thing on its line. Compares TRIMMED bounds rather
    /// than exact equality so leading indentation (an embed inside a list
    /// item) still counts as "alone".
    static func isAloneOnItsParagraph(fullRange: NSRange, in text: NSString) -> Bool {
        let paragraph = text.paragraphRange(for: fullRange)
        var start = paragraph.location
        let paragraphEnd = paragraph.location + paragraph.length
        while start < NSMaxRange(fullRange), isTrimmable(text.character(at: start)) {
            start += 1
        }
        var end = paragraphEnd
        while end > NSMaxRange(fullRange), end > start,
              isTrimmable(text.character(at: end - 1)) {
            end -= 1
        }
        return start == fullRange.location && end == NSMaxRange(fullRange)
    }

    private static func isTrimmable(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// Decoded embed images, keyed like `ExtractionCache` — `(canonical path,
/// mtime, size)` — for the same reason that cache exists: a style pass runs
/// on every keystroke, every ancestor redraw and every selection change, and
/// `NSImage(contentsOf:)` is a disk read plus a decode. Without this, opening
/// a note with a handful of screenshots would re-decode every one of them on
/// every caret move — the exact per-render regression `MarkdownStylingBenchmark`
/// exists to catch.
///
/// `@unchecked Sendable` with a lock for the same reason `ExtractionCache` is:
/// nothing here touches AppKit's main-actor state, only a private dictionary.
final class EmbedImageCache: @unchecked Sendable {
    static let shared = EmbedImageCache()
    static let maxEntries = 256

    private struct Key: Hashable {
        let path: String
        let mtime: TimeInterval
        let size: Int
    }

    private let lock = NSLock()
    /// `NSImage?` as the VALUE, not just the presence of a key: a file that
    /// fails to decode is cached as a miss too, so a broken image is retried
    /// only when the file itself changes (a new mtime/size), never on every
    /// render in between.
    private var storage: [Key: NSImage?] = [:]
    private var order: [Key] = []

    private init() {}

    func image(for url: URL) -> NSImage? {
        guard let key = Self.key(for: url) else { return NSImage(contentsOf: url) }
        lock.lock()
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Decoding runs OUTSIDE the lock, exactly as `ExtractionCache.result`
        // does: it is the slow part this cache exists to avoid paying twice,
        // and holding a lock across it would serialize every embed's decode.
        let decoded = NSImage(contentsOf: url)

        lock.lock(); defer { lock.unlock() }
        if storage[key] == nil {
            storage[key] = decoded
            order.append(key)
            while order.count > Self.maxEntries {
                storage.removeValue(forKey: order.removeFirst())
            }
        }
        return decoded
    }

    private static func key(for url: URL) -> Key? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int
        else { return nil }
        return Key(path: url.path, mtime: mtime.timeIntervalSince1970, size: size)
    }
}

extension MarkdownEditor.Coordinator {

    /// One resolved, decoded image embed, positioned at draw time from its
    /// (collapsed) glyph range — see `LinkTextView.drawBackground`.
    struct EmbedImageRegion: Equatable {
        let range: NSRange
        let image: NSImage
        let size: NSSize
        /// The paragraph's resolved writing direction and indent, captured
        /// here rather than recomputed at draw time: `drawEmbedImages` runs
        /// on every `needsDisplay`, including scroll, and re-scanning the
        /// paragraph's text for its bidi class on every frame would be
        /// needless work for a value that only changes when `applyEmbeds`
        /// itself re-runs. See `EmbedGeometry.drawRect`.
        let writingDirection: NSWritingDirection
        let indent: CGFloat

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.range == rhs.range && lhs.image === rhs.image && lhs.size == rhs.size
                && lhs.writingDirection == rhs.writingDirection && lhs.indent == rhs.indent
        }
    }

    /// Decorates every `.embed` span: an image collapses its FULL source
    /// (`fullRange` — `!`, brackets and target) and is drawn by
    /// `LinkTextView` at the collapsed range; a document, a failed decode,
    /// or anything else gets the chip pill over the TARGET text only (see
    /// `EmbedRendering.applyChipStyling`). `.unresolved` is left exactly as
    /// `MarkdownStyleRenderer.add`'s fallback already painted it — the
    /// EXISTING unresolved-link treatment: clicking it still reaches
    /// `DocumentPane`'s "Create this note?" prompt through `ctx.openLink`,
    /// exactly as an unresolved ordinary wikilink does.
    ///
    /// REVEAL-AWARE (fix round 1, Important 6): an embed whose OWN source
    /// range the caret is inside is skipped entirely — no collapse, no chip
    /// pill, no region — so its raw `![[target]]` source shows and can be
    /// edited. `MarkdownEditor.Coordinator.revealForSelectionChange` drives
    /// that on the caret path; see `embedRevealState` for how entering an
    /// embed's range (which is NOT a block flip, and so does not by itself
    /// reach `restyleBlock`) still gets noticed — fix round 2, I6.
    ///
    /// Called from TWO places, both of which must agree with each other or
    /// an embed decoration and the base-fallback colour would fight:
    /// `renderStyles()`, a FULL render, with `restrictTo: nil` — replaces
    /// `LinkTextView.embedImages` wholesale, since it just rebuilt every
    /// span's attributes from scratch; and `restyleBlock`'s per-block caret
    /// path, with `restrictTo` set to that one block — MERGES into
    /// `embedImages` (dropping only the regions inside that block first)
    /// rather than replacing the array, because a full replace there would
    /// drop every OTHER block's already-decorated images. Fix round 1
    /// Critical 2 found this: `restyleBlock` calls
    /// `MarkdownStyleRenderer.restyle`, which resets font/paragraph style
    /// over the whole block, popping a collapsed image's source back to full
    /// size and destroying its reserved line height — and left the STALE
    /// `EmbedImageRegion` in `embedImages`, so a ghost image kept painting at
    /// the now-wrong rect. Re-running `applyEmbeds` scoped to that block,
    /// immediately after `restyle`, both restores the collapse/paragraph
    /// style and refreshes (or, if the caret just entered the embed, drops)
    /// that block's region in the SAME pass.
    ///
    /// - Parameter spanIndices: positions into `styleCache.spans` to
    ///   consider, or `nil` for "all of them". The block path passes
    ///   `revealIndex.spansByBlock[block]`, so the caret path touches only
    ///   the spans of the block that changed — never the whole document.
    ///   Fix round 2, NEW-1: the first version of this took only
    ///   `restrictTo` and scanned EVERY span in the document, filtering
    ///   afterwards, which put an O(total spans) cost on every block-boundary
    ///   crossing and broke the property `restyleBlock` exists to provide
    ///   ("still nothing outside this block is touched").
    ///
    /// No inline image is drawn above the hard/viewport cap: `window` already
    /// limits which spans this reaches, matching how the rest of `renderStyles`
    /// treats an over-cap or off-screen document.
    func applyEmbeds(to storage: NSTextStorage, window: NSRange?,
                     restrictTo blockRange: NSRange? = nil,
                     spanIndices: [Int]? = nil) {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: storage.length)
        let resolve = resolveEmbedTarget
        let containerWidth = tv.textContainer?.size.width ?? tv.bounds.width
        let text = storage.string as NSString
        var regions: [EmbedImageRegion] = []

        let candidates = spanIndices.map { indices in
            indices.compactMap { $0 < styleCache.spans.count ? styleCache.spans[$0] : nil }
        } ?? styleCache.spans

        for span in candidates {
            guard case .embed(let target, let fullRange) = span.kind else { continue }
            let r = NSRange(location: span.range.lowerBound, length: span.range.count)
            guard r.length > 0, NSMaxRange(r) <= full.length else { continue }
            if let blockRange, NSIntersectionRange(r, blockRange).length == 0 { continue }
            if let window, NSIntersectionRange(r, window).length == 0 { continue }

            let full_ = NSRange(location: fullRange.lowerBound, length: fullRange.count)
            guard full_.length > 0, NSMaxRange(full_) <= full.length else { continue }
            if Self.isEmbedRevealed(full_, selection: tv.selectedRange()) { continue }

            switch EmbedRendering.kind(for: resolve(target)) {
            case .unresolved:
                continue   // Fallback colour already applied by `add(.embed:)`.

            case .chip:
                EmbedRendering.applyChipStyling(over: r, to: storage, tokens: tokens)

            case .transclusion:
                // A transclusion that is NOT alone on its paragraph cannot be
                // drawn — the reserved gap is a paragraph line height and the
                // panel is full-column, so it would stretch and then paint over
                // the prose sharing its line. It degrades to the SAME chip a
                // document embed gets, exactly as a mid-paragraph image does.
                // `TransclusionStyling.prepare` asks this same question and
                // skips those embeds, so the two answers cannot disagree.
                guard EmbedRendering.isAloneOnItsParagraph(fullRange: full_, in: text) else {
                    EmbedRendering.applyChipStyling(over: r, to: storage, tokens: tokens)
                    continue
                }
                // Otherwise: rendered by `TransclusionStyling`, not here. The collapse,
                // the reserved height and the drawing region have to come out
                // of ONE pass — and that pass is the collapse pass, because
                // `MarkdownStyleRenderer.collapse` resets attributes over the
                // very ranges a reservation writes to. `applyEmbeds` runs
                // AFTER that pass, so reserving here would be reserving into
                // a gap that has already been sized. See
                // `MarkdownEditorDecoration.prepareTransclusions`.
                continue

            case .image(let url):
                guard let image = EmbedImageCache.shared.image(for: url) else {
                    // Decode failed: never a blank gap, so it falls back to
                    // the same chip the document case gets — over the
                    // target text only, same as a chip.
                    EmbedRendering.applyChipStyling(over: r, to: storage, tokens: tokens)
                    continue
                }
                // Restricted to an embed that is ALONE on its paragraph. A
                // mid-sentence image has nowhere safe to reserve width: the
                // paragraph-level line height this function sets covers the
                // WHOLE line, so text sharing that line
                // ("Before ![[a.png]] after.") would be pushed apart
                // vertically from its own baseline while the image is drawn
                // at a fixed rect that does not track where "after." ends up
                // — an overlap no reflow-free drawn decoration can fix
                // without an attachment character, which is exactly what is
                // ruled out here. Rather than draw a decoration with a known
                // collision, a mid-paragraph image embed degrades to the
                // SAME chip treatment a document gets.
                //
                // THIS is also what keeps `EmbedGeometry.drawRect` safe:
                // that function answers in MARGIN-anchored coordinates
                // (fix round 2, Important 7) with no idea where "Before "/
                // "after." end, so it is only ever a correct answer for an
                // embed with nothing else sharing its line — exactly what
                // this guard enforces before an `EmbedImageRegion` is ever
                // built. See `EmbedDecorationTests
                // .test_midParagraphEmbed_rendersAsAChipNotAnImage` for the
                // regression guard.
                guard EmbedRendering.isAloneOnItsParagraph(fullRange: full_, in: text) else {
                    EmbedRendering.applyChipStyling(over: r, to: storage, tokens: tokens)
                    continue
                }
                let maxWidth = max(1, containerWidth - 32)
                let maxHeight: CGFloat = 480   // a tall screenshot must not swallow the viewport
                let scale = min(1, min(maxWidth / max(image.size.width, 1),
                                       maxHeight / max(image.size.height, 1)))
                let size = NSSize(width: image.size.width * scale,
                                  height: image.size.height * scale)
                // The source text is never deleted or replaced — only made
                // visually near-zero, the SAME trick `MarkdownStyleRenderer.
                // collapse` uses for hidden syntax markers — so every offset
                // the index, the link graph and MCP tools hold stays valid.
                // A real `NSTextAttachment` would need the U+FFFC attachment
                // CHARACTER in `tv.string` to render at all, and that string
                // is `text.wrappedValue` verbatim on every `textDidChange` —
                // inserting one would write a control character into the
                // note's saved markdown. Drawing the decoded image instead,
                // at this collapsed range's glyph rect, is what keeps the
                // image inline without that risk. `fullRange`, not `r`: the
                // target text must vanish too, not just the brackets — a
                // visible filename floating in front of its own image would
                // be worse than the raw markdown it replaces.
                MarkdownStyleRenderer.collapse([full_.location..<NSMaxRange(full_)], in: storage)
                let paragraph = text.paragraphRange(for: full_)
                // The paragraph's OWN style — already applied by
                // `MarkdownStyleRenderer` for its block (list item,
                // blockquote, body) before `applyEmbeds` ever runs — read
                // BEFORE it is overwritten below, so `embedImageStyle` can
                // preserve its indent rather than resetting to `.body`. See
                // that function's doc comment.
                let existingStyle = storage.attribute(
                    .paragraphStyle, at: paragraph.location, effectiveRange: nil
                ) as? NSParagraphStyle
                let style = MarkdownParagraphStyles.embedImageStyle(
                    basedOn: existingStyle, height: size.height,
                    theme: MarkdownTheme(tokens: tokens, settings: settings))
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                // Resolved once here, from the SURROUNDING text — never the
                // embed's own paragraph, which is just a filename and is
                // very often Latin even inside an Arabic document (fix
                // round 1, Critical 1) — and carried on the region rather
                // than re-derived at draw time. See
                // `EmbedGeometry.contextualWritingDirection` and
                // `EmbedImageRegion.writingDirection`'s doc comments.
                let writingDirection = EmbedGeometry.contextualWritingDirection(
                    paragraph: paragraph, in: text,
                    documentFallback: documentWritingDirection)
                let indent = existingStyle?.firstLineHeadIndent ?? 0
                regions.append(EmbedImageRegion(range: full_, image: image, size: size,
                                                writingDirection: writingDirection,
                                                indent: indent))
            }
        }

        guard let linkView = tv as? LinkTextView else { return }
        if let blockRange {
            // MERGE: drop only this block's old regions, keep every other
            // block's — see this function's doc comment on why a full
            // replace here would erase decoration `renderStyles()` already
            // committed for the rest of the document.
            linkView.embedImages.removeAll { NSIntersectionRange($0.range, blockRange).length > 0 }
            linkView.embedImages.append(contentsOf: regions)
        } else {
            linkView.embedImages = regions
        }
    }

    /// Whether the CURRENT selection touches this embed's own source range —
    /// deliberately narrower than "is the selection anywhere in the same
    /// BLOCK", which is the grain ordinary marker reveal works at. A block is
    /// a whole paragraph; an embed sharing a paragraph with other prose (or
    /// simply being the first thing in the document, where the caret starts
    /// by default before the user has clicked anywhere) would otherwise be
    /// "revealed" — and therefore never rendered as an image or chip — every
    /// time the caret is anywhere near it, which is most of the time. Ordinary
    /// bold/italic markers are a few characters the reader tolerates seeing
    /// while typing nearby; an un-rendered image for the same reason is a much
    /// bigger regression. So an embed reveals only when the selection
    /// literally overlaps its own `fullRange`.
    ///
    /// STRICT overlap, not the inclusive touch `MarkdownReveal.hiddenMarkers`
    /// uses for blocks — fix round 2, NEW-3. Inclusive on both ends meant a
    /// caret parked immediately AFTER the closing `]]`, or immediately
    /// BEFORE the leading `!`, counted as "inside" and suppressed the
    /// embed's rendering entirely. Those two positions are the ordinary
    /// resting places for a caret that has just finished typing an embed or
    /// is about to type in front of one, so the image vanished exactly when
    /// the user was most likely to be looking at it. Strict overlap reveals
    /// only when the caret is genuinely WITHIN the source — which is when
    /// the user is actually editing the target — and a zero-length selection
    /// at either boundary leaves the embed rendered.
    static func isEmbedRevealed(_ fullRange: NSRange, selection: NSRange) -> Bool {
        let selected = selection.location..<(selection.location + max(selection.length, 0))
        let span = fullRange.location..<(fullRange.location + fullRange.length)
        return selected.lowerBound < span.upperBound && span.lowerBound < selected.upperBound
    }

    /// Rebuilds `embedIndex` from the current spans and block ranges. Called
    /// from `renderStyles()` only — a text change or a full redraw — beside
    /// the `revealIndex` build it mirrors.
    func rebuildEmbedIndex() {
        embedIndex = styleCache.spans.compactMap { span in
            guard case .embed(_, let fullRange) = span.kind else { return nil }
            let ns = NSRange(location: fullRange.lowerBound, length: fullRange.count)
            guard let block = MarkdownEditorReveal.blockIndex(of: ns.location,
                                                              in: revealIndex.blocks)
            else { return nil }
            return (fullRange: ns, block: block)
        }
        revealedEmbedSpans = currentlyRevealedEmbedSpans()
    }

    /// The entries of `embedIndex` the CURRENT selection sits inside.
    func currentlyRevealedEmbedSpans() -> Set<Int> {
        guard let tv = textView, !embedIndex.isEmpty else { return [] }
        let selection = tv.selectedRange()
        var result: Set<Int> = []
        for (offset, entry) in embedIndex.enumerated()
        where Self.isEmbedRevealed(entry.fullRange, selection: selection) {
            result.insert(offset)
        }
        return result
    }

    /// The caret-path half of embed reveal: re-decorates only the blocks
    /// whose embeds just entered or left the caret, and reports whether it
    /// did anything.
    ///
    /// Called from `revealForSelectionChange` on every caret move, BEFORE
    /// its block-flip early return, because entering an embed's range is not
    /// a block flip and would otherwise never be noticed (fix round 2, I6).
    /// Costs a walk of `embedIndex` — one entry per embed in the document,
    /// typically zero — plus, only when the answer actually changed, a
    /// `restyleBlock` on the affected blocks, which is the same
    /// already-bounded work a block flip does.
    @discardableResult
    func revealEmbedsForSelectionChange(in storage: NSTextStorage) -> Bool {
        let now = currentlyRevealedEmbedSpans()
        let was = revealedEmbedSpans
        guard now != was else { return false }
        revealedEmbedSpans = now
        // Exactly the embeds whose reveal state flipped, mapped to the blocks
        // that have to be re-attributed for the change to become visible.
        let changed = now.symmetricDifference(was)
        let blocks = Set(changed.compactMap { offset -> Int? in
            offset < embedIndex.count ? embedIndex[offset].block : nil
        })
        for block in blocks.sorted() {
            restyleBlock(block, revealed: revealedRange, in: storage)
        }
        // DRAINED HERE, not left to the caller. `restyleBlock` reset those
        // blocks' paragraph styles, which pops a transcluded embed's reserved
        // gap shut and leaves its region describing a rect that no longer
        // exists — and one of this function's three callers is
        // `revealForSelectionChange`'s early-return branch, which returns
        // without any drain of its own (fix round 2, NEW-1: caret column 0 → 1
        // on an embed's line flips embed reveal while the line-scoped
        // `revealedRange` does not change, so the gap closed and a stale
        // full-column panel painted over the following paragraph until the
        // next keystroke). Draining inside the function that did the damage is
        // what makes the invariant hold for EVERY caller rather than for the
        // ones someone remembered.
        //
        // Reserves only. Whether the DRAWN decoration is rebuilt from it is
        // the caller's call, because the caller knows its viewport window and
        // whether it is about to refresh anyway — see fix round 1, Important 3.
        prepareTransclusionsIfNeeded(in: storage)
        return !blocks.isEmpty
    }

}
