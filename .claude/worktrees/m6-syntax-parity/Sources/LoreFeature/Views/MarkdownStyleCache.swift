import AppKit
import SwiftUI
import AinkradAppKit

/// The editor's style spans, and the text they describe.
///
/// The cache exists because `MarkdownDocumentModel.styleSpans` is a full parse
/// PLUS a link scan PLUS a `fullText.count`-sized offset table, and the editor's
/// `applyStyles()` runs on every keystroke and on every ancestor redraw — a
/// theme change, a banner appearing, a window resize. Before this cache a single
/// keystroke cost up to four parses. Identity of the text is the whole
/// invalidation rule: spans describe exactly one string, and `describes(_:)`
/// answers whether they still describe the one on screen.
struct MarkdownStyleCache {
    /// The string `spans` were derived from, or shifted to match.
    private(set) var text = ""
    private(set) var spans: [StyleSpan] = []
    /// Set from the model, so the renderer need not re-measure the string.
    private(set) var isOverHardCap = false
    private(set) var isOverViewportCap = false
    /// True when `spans` have been SHIFTED since the last parse — they are
    /// positioned correctly but may no longer be the right KINDS, because typing
    /// `*` can turn prose into emphasis. Only a parse settles that.
    private(set) var isStale = false

    /// Whether the last FULL parse saw a link reference definition
    /// (`[label]: /target`) anywhere in the document.
    ///
    /// The one thing that makes a block's meaning depend on text outside it:
    /// `[label]` styles as a link only because a definition somewhere else says
    /// so, and a block parsed in isolation cannot see that. `spliceBlock`
    /// refuses when this is set — see its doc comment.
    ///
    /// Deliberately NOT recomputed by `shift`, which would put a document scan
    /// back on the keystroke path this exists to keep cheap. It therefore
    /// describes the document as of the last parse, and can be up to one
    /// debounce out of date: typing the `:` that turns `[label]` into a
    /// definition leaves the flag false until the parse lands 150 ms later. The
    /// consequence is bounded — for that window, shortcut links elsewhere in
    /// the document style as plain text, which is exactly what they looked like
    /// before the definition was typed.
    private(set) var hasReferenceDefinitions = false

    func describes(_ candidate: String) -> Bool { text == candidate }

    /// Refreshes the spans from a real parse — EXCEPT above the hard cap, where
    /// the answer is `[]` and no parse is needed to say so.
    ///
    /// The guard has to be here, not in `MarkdownDocumentModel.init`: that
    /// initialiser also builds `codeRegions`, which the LINK GRAPH consumes, and
    /// making it skip work above a size would silently change which links
    /// resolve. The editor is the only consumer of style spans, so the editor is
    /// where "too big to style" is cheap to answer. Without this, the styling-OFF
    /// path was the most expensive path in the editor — a full parse per debounce
    /// to be handed an empty array.
    mutating func reparse(_ newText: String) {
        adopt(Self.derive(newText), for: newText)
    }

    /// Everything a parse produces, and nothing that is tied to a thread.
    ///
    /// `Sendable` so the parse can run OFF the main actor and the result be
    /// carried back — see `MarkdownEditor.Coordinator.parseNow`. The struct
    /// carries no reference to the editor, so there is nothing to race on; the
    /// string it describes travels alongside it and is checked on arrival.
    struct Derived: Sendable {
        let spans: [StyleSpan]
        let isOverHardCap: Bool
        let isOverViewportCap: Bool
        /// See `MarkdownStyleCache.hasReferenceDefinitions`.
        let hasReferenceDefinitions: Bool
    }

    /// The pure, actor-free half of `reparse`. Safe to call from any thread.
    static func derive(_ newText: String) -> Derived {
        guard newText.utf16.count <= MarkdownDocumentModel.stylingHardCap else {
            return Derived(spans: [], isOverHardCap: true, isOverViewportCap: true,
                           // Nothing is styled above the hard cap, so the block
                           // path is barred anyway; `true` states that without
                           // paying for a scan of a document this large.
                           hasReferenceDefinitions: true)
        }
        // `init(body:)`: the editor styles exactly the string it was given,
        // whole. For markdown that string is `note.body` (bound in
        // `MarkdownDocumentEditor`), already frontmatter-free; for plain text
        // there is no frontmatter to have. Either way a `Frontmatter.bodyOffset`
        // scan here can only mis-fire, and when it does the region above the
        // second `---` is simply left UNSTYLED — no bold, no headings, no
        // code-block background. Surviving spans still land correctly, because
        // `SourceOffsetMap` re-bases them; the defect is omission, not
        // misplacement.
        let model = MarkdownDocumentModel(body: newText)
        return Derived(spans: model.styleSpans,
                       isOverHardCap: model.isOverStylingHardCap,
                       isOverViewportCap: model.isOverStylingViewportCap,
                       hasReferenceDefinitions: containsReferenceDefinition(newText))
    }

    /// Whether any line LOOKS like a link reference definition.
    ///
    /// Deliberately over-eager, and deliberately not a parse. It is only ever
    /// read to REFUSE the single-block splice, so a false positive costs the
    /// document the fast path — the behaviour that shipped before it — while a
    /// false negative would let a block be styled without the definition it
    /// depends on. Nothing here can produce a false negative for a real
    /// definition: CommonMark requires one to begin a line (up to three spaces
    /// of indent) with `[`, and to have its `]:` on that same line.
    ///
    /// Runs once per full parse, alongside a parse that is orders of magnitude
    /// more expensive than a character scan — never on the keystroke path.
    static func containsReferenceDefinition(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.first == "[" else { continue }
            // The `]` must be followed immediately by `:` to be a definition;
            // `[a] : b` is a paragraph.
            if let close = trimmed.dropFirst().firstIndex(of: "]"),
               trimmed.index(after: close) < trimmed.endIndex,
               trimmed[trimmed.index(after: close)] == ":" { return true }
        }
        return false
    }

    /// Spans for ONE block, parsed in ISOLATION and re-based onto the document.
    ///
    /// This is what lets a keystroke show the markdown it just typed. The rest
    /// of the edit path deliberately never parses — it SHIFTS the previous
    /// spans, which keeps positions right and kinds frozen, so `**bold**` typed
    /// into a paragraph stayed plain until the debounced parse landed 150 ms
    /// after the user stopped. Parsing the one block the caret is in costs
    /// microseconds against the 9–92 ms a whole-document parse costs, and
    /// answers the question that actually changed.
    ///
    /// Correct in isolation only because `MarkdownReveal.blocks` splits on BLANK
    /// LINES, which is also where CommonMark ends a leaf block: with the two
    /// exceptions the caller checks for — a span reaching past the block's ends
    /// (a fence containing a blank line) and a link reference definition
    /// elsewhere in the document — a blank-line-delimited block parses to the
    /// same nodes alone as it does in place.
    ///
    /// Returns `nil` rather than a wrong answer if any derived span escapes the
    /// block after re-basing. That cannot happen for a substring parse and is
    /// checked anyway: this writes into the cache the whole editor renders from,
    /// and an out-of-block span there would style characters belonging to a
    /// block nobody is about to re-attribute.
    static func deriveBlock(of text: String, range: Range<Int>) -> [StyleSpan]? {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length,
              range.lowerBound < range.upperBound else { return nil }
        let slice = ns.substring(with: NSRange(location: range.lowerBound,
                                               length: range.count))
        let model = MarkdownDocumentModel(body: slice)
        guard !model.isOverStylingHardCap else { return nil }
        var out: [StyleSpan] = []
        out.reserveCapacity(model.styleSpans.count)
        for span in model.styleSpans {
            let lower = span.range.lowerBound + range.lowerBound
            let upper = span.range.upperBound + range.lowerBound
            guard lower >= range.lowerBound, upper <= range.upperBound,
                  upper > lower else { return nil }
            out.append(StyleSpan(range: lower..<upper, kind: span.kind))
        }
        return out
    }

    /// Replaces the spans of one block with freshly parsed ones.
    ///
    /// - Parameters:
    ///   - range: the block, in UTF-16 offsets into the current `text`.
    ///   - fresh: `deriveBlock`'s answer for that block.
    ///
    /// Ordering is rebuilt as "everything starting before the block, then the
    /// block, then everything starting at or after it", preserving relative
    /// order inside each part. That is NOT the order a full parse produces —
    /// `styleSpans` is every AST span followed by every wikilink — but it is
    /// equivalent where equivalence is observable. Order matters to the renderer
    /// only between OVERLAPPING spans (a later one overwrites an earlier one's
    /// attributes) and to `MarkdownListDepth`, whose stack needs list spans in
    /// document order. Spans in different blocks never overlap, and within a
    /// block relative order is untouched, so both hold. `MarkdownEditFastPathTests`
    /// asserts it against a full render rather than taking this on trust.
    ///
    /// `isStale` stays as it was: only THIS block has been settled by a parse,
    /// and every other span in the document is still a shifted guess that the
    /// debounce must come back for.
    mutating func spliceBlock(_ range: Range<Int>, with fresh: [StyleSpan]) {
        var before: [StyleSpan] = []
        var after: [StyleSpan] = []
        for span in spans {
            if span.range.lowerBound < range.lowerBound { before.append(span) }
            else if span.range.lowerBound >= range.upperBound { after.append(span) }
            // Anything starting inside the block is dropped: `fresh` replaces it.
        }
        spans = before + fresh + after
    }

    /// Installs a derivation together with the string it describes.
    ///
    /// `text` is set from the caller's snapshot, never from the live view: the
    /// invariant `describes(text) ⇒ these spans index that exact string` is the
    /// only thing standing between a stale parse and styling the wrong
    /// characters, so the string and the spans are installed as one unit.
    mutating func adopt(_ derived: Derived, for newText: String) {
        text = newText
        spans = derived.spans
        isOverHardCap = derived.isOverHardCap
        isOverViewportCap = derived.isOverViewportCap
        hasReferenceDefinitions = derived.hasReferenceDefinitions
        isStale = false
    }

    /// Below this much text the editor parses on the OPEN path synchronously;
    /// above it, off the main actor.
    ///
    /// Not a performance hedge but an honest trade of two different bad
    /// experiences. A synchronous parse blocks the main actor — ~0.4 s Debug on
    /// a 230 KB note, which is a beachball on every document switch. An
    /// off-actor one returns instantly but shows the note UNSTYLED for as long
    /// as the parse takes, because there are no cached spans to shift from: a
    /// freshly opened document has no previous text. For a hand-written note
    /// that flash would be the more visible defect of the two, and the parse it
    /// replaces is a couple of milliseconds. So: small documents pay the
    /// millisecond, large ones take the flash.
    ///
    /// 16 KB rather than the viewport cap because the two answer different
    /// questions — that one is about how much can be ATTRIBUTED per frame, this
    /// one about how long a parse may hold the main actor. At 16 KB the
    /// measured Debug parse is under 30 ms and the Release one is a few.
    static let synchronousParseCap = 16 * 1024

    /// Claims currency for `newText` WITHOUT parsing it, so the editor can
    /// render immediately and let the real parse land off-actor.
    ///
    /// `isStale` is the load-bearing part: it is how `parseNow` knows this is a
    /// promise rather than an answer, and re-parses instead of returning early
    /// on the `describes(_:)` check. Without it the document would keep these
    /// empty spans forever.
    ///
    /// The caps are still exact — they are a function of the LENGTH, not of the
    /// parse — so an over-cap document still shows its notice at once.
    mutating func adoptProvisional(_ newText: String) {
        text = newText
        spans = []
        isOverHardCap = newText.utf16.count > MarkdownDocumentModel.stylingHardCap
        isOverViewportCap = newText.utf16.count > MarkdownDocumentModel.stylingViewportCap
        // Conservative until a real parse says otherwise: a provisional cache
        // has not looked at the document, so it cannot rule a definition out.
        hasReferenceDefinitions = true
        isStale = true
    }

    /// Moves every cached span to where the edit put it, rather than dropping
    /// the styling until the next parse.
    ///
    /// Dropping would be correct and horrible: every keystroke would flash the
    /// document back to plain text for the length of the debounce. Shifting
    /// keeps the picture stable and is wrong only in the ways a parse 150 ms
    /// later fixes.
    ///
    /// One uniform rule, applied to both ends of every span: an offset at or
    /// before the edit stays put, an offset after it moves by the delta. That
    /// makes a span entirely after the edit slide, a span entirely before it
    /// hold still, and a span the caret is INSIDE grow — which is what typing
    /// inside `**bold**` should look like.
    ///
    /// - Parameter delta: replacement length minus `editedRange.length`, in
    ///   UTF-16 units.
    mutating func shift(editedRange: NSRange, delta: Int, newText: String) {
        let start = editedRange.location
        let limit = (newText as NSString).length
        text = newText
        isStale = true
        guard delta != 0 || editedRange.length != 0 else { return }

        spans = spans.compactMap { span in
            let lower = moved(span.range.lowerBound, start: start, delta: delta, limit: limit)
            let upper = moved(span.range.upperBound, start: start, delta: delta, limit: limit)
            // A deletion can collapse a span onto itself; an empty range styles
            // nothing, and an inverted one traps.
            guard upper > lower else { return nil }
            return StyleSpan(range: lower..<upper, kind: span.kind)
        }
    }

    private func moved(_ offset: Int, start: Int, delta: Int, limit: Int) -> Int {
        guard offset > start else { return min(offset, limit) }
        return min(max(start, offset + delta), limit)
    }
}
