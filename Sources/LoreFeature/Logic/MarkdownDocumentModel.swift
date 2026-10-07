import Foundation
import Markdown

/// The one place this application parses markdown.
///
/// Before M2a there were THREE scanners — a regex styler, a line-based outline
/// scan, and the link parser's span scanner — and they disagreed: the first two
/// were blind to code fences, so a `#` comment in a code block became a heading
/// in the index and `**bold**` inside a fence was styled. Every feature that
/// reads document structure now derives from this single parse.
public struct MarkdownDocumentModel: Sendable {
    /// Above this much text, styling covers only the visible range plus a
    /// margin, re-derived on scroll. The outline and task lists still come from
    /// a full parse, which happens once per debounce rather than per keystroke.
    ///
    /// 256 KB is roughly where applying attributes over the whole storage — not
    /// the parse — starts to be felt on a keystroke, and it is far above any
    /// hand-written note in the owner's vault, so ordinary editing never takes
    /// this path.
    public static let stylingViewportCap = 256 * 1024

    /// Above this, styling is disabled entirely and the editor says so. A note
    /// that is slow to type in is worse than one that is plainly styled.
    public static let stylingHardCap = 2 * 1024 * 1024

    public let offsetMap: SourceOffsetMap

    /// Every raw-text region, tagged. Ordered as the walk found them.
    public let codeRegions: [CodeRegion]

    /// `codeRegions` as a searchable union — every kind.
    private let allKindsIndex: CodeRegionIndex

    /// `codeRegions` as a searchable union — `linkSuppressingKinds` only.
    /// Built once here so the link scan does not rebuild it per call.
    let linkSuppressionIndex: CodeRegionIndex

    /// Every code region's range, kind discarded. Unchanged in meaning from
    /// before kinds existed: fenced, indented, HTML block, and inline code.
    public var codeRangesUTF16: [NSRange] { codeRegions.map(\.range) }

    /// The kinds the LINK GRAPH suppresses on. Deliberately NOT every kind —
    /// see `CodeRegionKind`.
    public static let linkSuppressingKinds: Set<CodeRegionKind> = [
        .fencedCodeBlock, .inlineCode,
    ]

    /// The string this model describes, and the string every offset it reports
    /// indexes. Retained so wikilink spans can be derived ON DEMAND — see
    /// `styleSpans`. The parsed `Document` is NOT retained: `RawMarkup` is not
    /// `Sendable`.
    public let fullText: String

    /// Style spans for the nodes the AST knows about, in walk order, in UTF-16
    /// offsets into `fullText`. Collected in `init` by the same walk as
    /// `codeRegions`.
    ///
    /// Deliberately NOT the whole story: wikilinks are not CommonMark, so this
    /// omits them. Callers wanting what the EDITOR should style want
    /// `styleSpans`.
    public let astStyleSpans: [StyleSpan]

    /// Headings, in document order, with UTF-16 offsets into `fullText`.
    /// Collected in `init` by the SAME walk as `astStyleSpans` and
    /// `codeRegions` — see `MarkdownASTCollector.visitHeading`. A `Heading`
    /// inside a fenced code block is never visited at all (the parser never
    /// produced one there), so an offset heading comment cannot appear here —
    /// unlike the line scanner this replaces.
    public let outline: [OutlineEntry]

    /// The non-AST syntaxes, from the SAME pass that produced the code
    /// regions. A second scan here would be a second parse, which is exactly
    /// the disagreement this type exists to remove.
    public let extensionSpans: [MarkdownExtensions.Span]

    /// Wikilink spans, derived on demand rather than in `init`.
    ///
    /// On demand because `LinkParser` — the one scanner that knows a `[[link]]`
    /// inside a fence is documentation, not a link — itself needs a code-region
    /// answer, and deriving these during `init` would close a cycle: model →
    /// parser → model → … an unbounded recursion, which is a hang rather than a
    /// crash. Evaluating outside `init` makes the cycle unformable no matter
    /// who calls what, so no flag and no partially-built model are needed.
    ///
    /// The parser is handed THIS model's already-computed regions, so the
    /// public path parses markdown exactly once.
    public var wikilinkSpans: [StyleSpan] {
        WikilinkSpanBuilder.spans(in: fullText, suppression: injectableSuppressionIndex)
    }

    /// Tag names written inline in the body, deduplicated, in document order.
    ///
    /// Derived from `extensionSpans`, which the initializer already computed —
    /// a second scan here would be a second parse, which is the disagreement
    /// this type exists to remove.
    public var inlineTags: [String] {
        var seen = Set<String>()
        return extensionSpans.compactMap { span in
            guard case .tag(let name) = span.kind, seen.insert(name).inserted
            else { return nil }
            return name
        }
    }

    /// `^block-id` anchors, derived from `extensionSpans` — not a rescan.
    public var blockAnchors: [BlockAnchor] {
        extensionSpans.compactMap { span in
            guard case .blockID(let id) = span.kind else { return nil }
            return BlockAnchor(id: id, offset: span.range.lowerBound)
        }
    }

    /// Every link this document contributes to the graph, from THIS parse.
    ///
    /// The index-building half of `indexPayload` used to call
    /// `LinkParser.links(in:)` with nothing injected, so it built a second,
    /// identical model of the same string purely to answer "inside code?" —
    /// two full AST parses per payload. This is the same seam `wikilinkSpans`
    /// uses, and it answers identically: `LinkParser`'s grammar, kind filter
    /// and results do not depend on whether the index was injected or rebuilt.
    ///
    /// NOT gated on `isOverStylingHardCap`. The caps govern STYLING — what the
    /// editor draws — and dropping links above one would silently amputate the
    /// link graph of a large note and let a rename stop rewriting it.
    public var links: [DocumentLink] {
        LinkParser.spans(in: fullText, suppression: injectableSuppressionIndex).map(\.link)
    }

    /// Every span the editor should style: AST nodes plus wikilinks.
    ///
    /// Computed, not stored, because `wikilinkSpans` must stay lazy. There is
    /// no incomplete model to observe — this property always answers fully —
    /// at the cost of recomputing the link scan per access. Callers on a hot
    /// path should hold the result, not the model.
    /// Empty above `stylingHardCap`: past that size the honest answer is "this
    /// document is not styled", not a slow one.
    public var styleSpans: [StyleSpan] {
        guard !isOverStylingHardCap else { return [] }
        return astStyleSpans + wikilinkSpans + mathSpans + Self.styleSpans(from: extensionSpans)
    }

    /// Turns scanner spans into the `StyleSpan`s the renderer reads.
    ///
    /// One function, extended per syntax, rather than a conversion scattered
    /// across the scanners: the CONTENT span and its MARKER spans have to be
    /// emitted together or Live Preview collapses markers around text it has
    /// no span for.
    private static func styleSpans(
        from extensions: [MarkdownExtensions.Span]
    ) -> [StyleSpan] {
        extensions.flatMap { span -> [StyleSpan] in
            switch span.kind {
            case .highlight:
                return [
                    StyleSpan(range: span.content, kind: .highlight),
                    StyleSpan(
                        range: span.range.lowerBound..<span.content.lowerBound,
                        kind: .marker(of: .highlight)),
                    StyleSpan(
                        range: span.content.upperBound..<span.range.upperBound,
                        kind: .marker(of: .highlight)),
                ]
            case .footnoteReference(let label):
                return [
                    StyleSpan(range: span.content, kind: .footnoteReference(label: label)),
                    StyleSpan(
                        range: span.range.lowerBound..<span.content.lowerBound,
                        kind: .marker(of: .footnote)),
                    StyleSpan(
                        range: span.content.upperBound..<span.range.upperBound,
                        kind: .marker(of: .footnote)),
                ]
            case .footnoteDefinition(let label):
                // The SAME two-marker-span shape as `.footnoteReference`
                // above: one marker in front of the label, one after —
                // `isDelimitedByASinglePair` answering `false` for this kind
                // (see `MarkdownSpanBuilder`) is not about how many marker
                // spans this emits. It is about whether the REVEAL machinery
                // must show the whole thing together across a line break,
                // and a definition's markers structurally never can: a
                // definition only exists at line start (`scanFootnotes`
                // requires it) and both its markers sit on that one line, so
                // there is no closing half on a later line to reveal in
                // tandem with. Both spans are inert for the same reason —
                // neither a reference's nor a definition's span can cross a
                // line — noted here so the `true`/`false` split does not
                // read as arbitrary.
                return [
                    StyleSpan(range: span.content, kind: .footnoteDefinition(label: label)),
                    StyleSpan(
                        range: span.range.lowerBound..<span.content.lowerBound,
                        kind: .marker(of: .footnote)),
                    StyleSpan(
                        range: span.content.upperBound..<span.range.upperBound,
                        kind: .marker(of: .footnote)),
                ]
            case .tag(let name):
                // The WHOLE range, `#` included, and NO marker span: Obsidian
                // keeps the `#` visible (a tag chip without it would be
                // indistinguishable from a link chip), so there is nothing
                // for `MarkdownReveal` to collapse.
                return [StyleSpan(range: span.range, kind: .tag(name: name))]
            case .blockID(let id):
                // The WHOLE range, `^` included, and NO marker span — same
                // shape as `.tag`: a block ID is line-scoped with no closing
                // half, so there is nothing for `MarkdownReveal` to collapse.
                return [StyleSpan(range: span.range, kind: .blockID(id: id))]
            }
        }
    }

    /// UTF-16 length, which is what every style offset is measured in.
    public var isOverStylingHardCap: Bool {
        fullText.utf16.count > Self.stylingHardCap
    }

    /// True when styling should be limited to the visible range plus a margin.
    public var isOverStylingViewportCap: Bool {
        fullText.utf16.count > Self.stylingViewportCap
    }

    /// This model's regions, but only when they are known to describe exactly
    /// the string `LinkParser` will scan.
    ///
    /// `LinkParser` normalises CRLF before scanning. That is offset-safe for
    /// its own CHARACTER offsets (`"\r\n"` is one Swift `Character`) but not
    /// for UTF-16 ones: every line break past the first shifts by a unit, so
    /// regions computed here would point at the wrong places in the string it
    /// actually scans. For those documents we hand over nothing and let the
    /// parser build its own model from the normalised text — correctness over
    /// the saved parse.
    ///
    /// Handing over the INDEX rather than the region array changes nothing
    /// about this guard: the index is derived from the same regions and carries
    /// the same UTF-16 offsets, so a pre-normalisation index is misplaced in
    /// exactly the same way a pre-normalisation region array is. The guard
    /// stays.
    private var injectableSuppressionIndex: CodeRegionIndex? {
        fullText.contains("\r\n") ? nil : linkSuppressionIndex
    }

    /// For a string that may still CARRY frontmatter — a whole file as it sits
    /// on disk. Its `---` block is located once, with `Frontmatter.bodyOffset`,
    /// and excluded from the parse.
    ///
    /// Callers holding a string that is ALREADY a body must use `init(body:)`,
    /// not this. Running the frontmatter scan over a body is not a no-op: a
    /// body that legitimately OPENS with something fence-shaped (an `---`
    /// horizontal rule followed, anywhere later, by another bare `---` line)
    /// has everything up to that second `---` misread as frontmatter and
    /// excluded from `Document(parsing:)` entirely — not shifted, DROPPED. A
    /// heading in that region vanishes from the outline; a `[[link]]` inside a
    /// fence there vanishes from the SUPPRESSION index and becomes a phantom
    /// link that a rename will rewrite.
    public init(fullText: String) {
        self.init(text: fullText, bodyStart: Frontmatter.bodyOffset(in: fullText))
    }

    /// For a string that is ENTIRELY body — there is nothing left to strip, so
    /// nothing is: every offset this model reports indexes `body` from its
    /// first character.
    ///
    /// "Body" is a claim about provenance, not about content. `Note.body` (the
    /// frontmatter was separated by `Frontmatter.parse`), the editor's own
    /// buffer (which is what it is asked to style, whole), and the
    /// already-offset slice `LinkRewriter` scans all qualify. A plain-text file
    /// qualifies too: it has no frontmatter to have, so all of it is body.
    ///
    /// A separate initialiser rather than a `Bool` parameter on the one above
    /// because the boolean was how this defect family arose — three call sites,
    /// three chances to pass the wrong value, and a default that was silently
    /// wrong for two of them. An argument LABEL states the provenance at the
    /// call site and cannot be defaulted away.
    public init(body: String) {
        self.init(text: body, bodyStart: 0)
    }

    /// - Parameter bodyStart: CHARACTER offset in `text` where the body begins.
    ///   Already decided by the caller; this initialiser does not second-guess
    ///   it, which is the whole point of having two public doors.
    private init(text fullText: String, bodyStart: Int) {
        #if DEBUG
        MarkdownParseCounter.record()
        #endif
        let body = String(fullText.dropFirst(bodyStart))
        let bodyUTF16Offset = (String(fullText.prefix(bodyStart)) as NSString).length

        let map = SourceOffsetMap(body: body, bodyUTF16Offset: bodyUTF16Offset)
        let doc = Document(parsing: body)

        self.offsetMap = map
        self.fullText = fullText
        var collector = MarkdownASTCollector(map: map, text: fullText as NSString)
        collector.visit(doc)
        self.codeRegions = collector.regions
        self.astStyleSpans = collector.styleSpans
        self.outline = collector.outline
        let allKindsIndex = CodeRegionIndex(regions: collector.regions, kinds: nil)
        self.allKindsIndex = allKindsIndex
        self.linkSuppressionIndex = CodeRegionIndex(
            regions: collector.regions,
            kinds: Self.linkSuppressingKinds)

        // Masked = code regions plus math expressions, from THIS same pass —
        // a second scan here would be a second parse. Computed via
        // `MarkdownMath.spans` directly, not `self.mathSpans`: `self` is not
        // fully initialized until `extensionSpans` itself is assigned.
        let codeRanges = collector.regions.compactMap { Range($0.range) }
        let text = fullText as NSString
        let mathRanges = MarkdownMath.spans(in: text, isSuppressed: { allKindsIndex.contains($0) })
            .map(\.range)
        // Link ranges a `#` must never become a tag inside. Two different
        // sources, because no single existing scan covers both link syntaxes:
        //
        // - Markdown links `[text](target)`, WHOLE range (brackets, parens
        //   and target all included) — from `self.astStyleSpans`, the AST
        //   pass already run above. `LinkParser` was tried here first and
        //   rejected: it deliberately excludes any target containing "://"
        //   (an external URL is not a vault link), so
        //   `[text](https://x.test/page#anchor)` never appeared in its
        //   results and the `#` inside it was wrongly scanned as a tag.
        //   `self.astStyleSpans` has no such filter — swift-markdown parses
        //   a `Link` node whatever its target — so it is used instead of a
        //   second, narrower parse.
        // - Wikilink TARGETS `[[Target#fragment]]` — the AST has no node for
        //   these at all (`[[…]]` is not CommonMark), so `LinkParser` is
        //   still needed for this half. This is the same seam
        //   `wikilinkSpans` reads, filtered to `.wikilink` syntax only:
        //   markdown-link coverage now comes from `astStyleSpans` above, so
        //   asking `LinkParser` for markdown spans here would be redundant
        //   work for no wider a result.
        //
        // Neither is a NEW parse: `astStyleSpans` is this init's own AST
        // walk, already assigned above; `LinkParser.scan` here mirrors
        // exactly what `wikilinkSpans` already calls, so this stays "one
        // parse of the document, plus one bracket-only scan for the one
        // syntax the AST cannot see" — not a second full parse.
        //
        // Inlined rather than calling `injectableSuppressionIndex`: `self`
        // is not fully initialized until `extensionSpans` itself is
        // assigned, so a computed property that reads `self` cannot be
        // called here — same reason `mathRanges` above calls
        // `MarkdownMath.spans` directly instead of going through `self`.
        let markdownLinkRanges = astStyleSpans.compactMap { $0.kind == .link ? $0.range : nil }
        let linkSuppression: CodeRegionIndex? =
            fullText.contains("\r\n")
            ? nil : self.linkSuppressionIndex
        let linkScan = LinkParser.scan(fullText, suppression: linkSuppression)
        let linkUTF16Offsets =
            linkScan.normalised
            ? CharacterOffsetMap.make(for: fullText) : linkScan.offsets
        let wikilinkTargetRanges: [Range<Int>] = linkScan.spans.compactMap { span in
            guard span.link.syntax == .wikilink,
                span.targetRange.lowerBound >= 0,
                span.targetRange.upperBound < linkUTF16Offsets.count
            else { return nil }
            let lower = linkUTF16Offsets[span.targetRange.lowerBound]
            let upper = linkUTF16Offsets[span.targetRange.upperBound]
            return lower..<upper
        }
        self.extensionSpans = MarkdownExtensions.scan(
            text, masked: codeRanges + mathRanges,
            linkRanges: markdownLinkRanges + wikilinkTargetRanges)
    }

    /// True if `offset` is inside ANY code region. Semantics unchanged: callers
    /// that genuinely want every raw-text region keep using this.
    public func isInsideCode(utf16Offset offset: Int) -> Bool {
        allKindsIndex.contains(offset)
    }

    /// True if `offset` is inside a code region of one of `kinds`.
    ///
    /// The prebuilt index serves the one set that is on a hot path; any other
    /// set is a test or a one-off, and pays for its own index. Both branches
    /// answer the same question — see `CodeRegionIndex`.
    public func isInsideCode(utf16Offset offset: Int, kinds: Set<CodeRegionKind>) -> Bool {
        if kinds == Self.linkSuppressingKinds { return linkSuppressionIndex.contains(offset) }
        return CodeRegionIndex(regions: codeRegions, kinds: kinds).contains(offset)
    }
}
