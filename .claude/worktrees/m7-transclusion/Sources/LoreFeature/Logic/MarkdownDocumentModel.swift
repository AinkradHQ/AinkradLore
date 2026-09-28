import Foundation
import Markdown

/// The one place this application parses markdown.
///
/// Before M2a there were THREE scanners — a regex styler, a line-based outline
/// scan, and the link parser's span scanner — and they disagreed: the first two
/// were blind to code fences, so a `#` comment in a code block became a heading
/// in the index and `**bold**` inside a fence was styled. Every feature that
/// reads document structure now derives from this single parse.
/// What kind of raw-text region a `CodeRegion` came from.
///
/// Kinds exist because "is this code?" has two different right answers depending
/// on who is asking. A styler wants every raw-text region. The LINK GRAPH wants
/// only the regions the old hand-written scanner recognised — fenced and inline
/// code — because widening it silently deletes links from real notes: a
/// CommonMark type-6 HTML block runs to the next BLANK line, so `[[R]]` in an
/// ordinary prose line after a `</div>` would stop being a link at all.
public enum CodeRegionKind: Sendable, Equatable, Hashable {
    case fencedCodeBlock
    case indentedCodeBlock
    case inlineCode
    case htmlBlock
}

public struct CodeRegion: Sendable, Equatable {
    public let range: NSRange
    public let kind: CodeRegionKind
}

/// "Is this offset inside code?" answered in O(log n) instead of O(n).
///
/// The linear `codeRegions.contains { … }` it replaces was 85% of the cost of
/// parsing a large note: `LinkParser` asks once per candidate link, so a note
/// with L links and R regions cost O(L × R). A 230 KB note has thousands of
/// each.
///
/// The trick that makes a binary search legal is that the QUESTION is about a
/// UNION, not about individual regions: "inside any region of these kinds" is
/// exactly "inside the union of those ranges". So the ranges are sorted and
/// COALESCED into disjoint half-open intervals at construction, and a single
/// binary search for the last interval starting at or before `offset` settles
/// it. Kinds are applied by FILTERING before coalescing, which is why the
/// kind-filtered and all-kinds questions need two different indexes rather than
/// one index consulted differently — merging first would let an
/// `.indentedCodeBlock` extend a `.fencedCodeBlock`'s interval and silently
/// widen link suppression.
///
/// Zero-length regions are dropped: `NSLocationInRange` is false for every
/// offset against them, so they can never have contributed an answer.
struct CodeRegionIndex: Sendable {
    /// Disjoint, ascending, half-open. `starts[i]..<ends[i]`.
    private let starts: [Int]
    private let ends: [Int]

    /// - Parameter kinds: `nil` means every kind — the all-regions question.
    init(regions: [CodeRegion], kinds: Set<CodeRegionKind>?) {
        let intervals = regions
            .lazy
            .filter { kinds?.contains($0.kind) ?? true }
            .map { ($0.range.location, $0.range.location + $0.range.length) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(intervals.count)
        ends.reserveCapacity(intervals.count)
        for (lower, upper) in intervals {
            // `lower <= ends.last` merges overlapping AND touching intervals.
            // Touching ones are safe to merge because the intervals are
            // half-open: `[0,3)` ∪ `[3,5)` covers exactly `[0,5)`.
            if let last = ends.last, lower <= last {
                ends[ends.count - 1] = max(last, upper)
            } else {
                starts.append(lower)
                ends.append(upper)
            }
        }
        self.starts = starts
        self.ends = ends
    }

    var isEmpty: Bool { starts.isEmpty }

    func contains(_ offset: Int) -> Bool {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return false }
        return offset < ends[low - 1]
    }
}

/// Counts markdown parses so the editor's caching can be asserted on rather
/// than asserted about. Test-only: the increment is `#if DEBUG`, so a release
/// build carries neither the lock nor the call.
///
/// Not an actor: `MarkdownDocumentModel.init` is synchronous and `Sendable`, and
/// making the count `await`-able would change every call site to prove a
/// property no shipping code reads.
/// Internal, not public: nothing outside this module has any business reading
/// it, and `@testable import` reaches it exactly as it is.
enum MarkdownParseCounter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = 0

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stored = 0
    }

    static func record() {
        lock.lock(); defer { lock.unlock() }
        stored += 1
    }
}

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
            guard case let .tag(name) = span.kind, seen.insert(name).inserted
            else { return nil }
            return name
        }
    }

    /// `^block-id` anchors, derived from `extensionSpans` — not a rescan.
    public var blockAnchors: [BlockAnchor] {
        extensionSpans.compactMap { span in
            guard case let .blockID(id) = span.kind else { return nil }
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
        from extensions: [MarkdownExtensions.Span]) -> [StyleSpan] {
        extensions.flatMap { span -> [StyleSpan] in
            switch span.kind {
            case .highlight:
                return [StyleSpan(range: span.content, kind: .highlight),
                        StyleSpan(range: span.range.lowerBound..<span.content.lowerBound,
                                  kind: .marker(of: .highlight)),
                        StyleSpan(range: span.content.upperBound..<span.range.upperBound,
                                  kind: .marker(of: .highlight))]
            case .footnoteReference(let label):
                return [StyleSpan(range: span.content, kind: .footnoteReference(label: label)),
                        StyleSpan(range: span.range.lowerBound..<span.content.lowerBound,
                                  kind: .marker(of: .footnote)),
                        StyleSpan(range: span.content.upperBound..<span.range.upperBound,
                                  kind: .marker(of: .footnote))]
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
                return [StyleSpan(range: span.content, kind: .footnoteDefinition(label: label)),
                        StyleSpan(range: span.range.lowerBound..<span.content.lowerBound,
                                  kind: .marker(of: .footnote)),
                        StyleSpan(range: span.content.upperBound..<span.range.upperBound,
                                  kind: .marker(of: .footnote))]
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
        self.linkSuppressionIndex = CodeRegionIndex(regions: collector.regions,
                                                    kinds: Self.linkSuppressingKinds)

        // Masked = code regions plus math expressions, from THIS same pass —
        // a second scan here would be a second parse. Computed via
        // `MarkdownMath.spans` directly, not `self.mathSpans`: `self` is not
        // fully initialized until `extensionSpans` itself is assigned.
        let codeRanges = collector.regions.map { Range($0.range)! }
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
        let linkSuppression: CodeRegionIndex? = fullText.contains("\r\n")
            ? nil : self.linkSuppressionIndex
        let linkScan = LinkParser.scan(fullText, suppression: linkSuppression)
        let linkUTF16Offsets = linkScan.normalised
            ? CharacterOffsetMap.make(for: fullText) : linkScan.offsets
        let wikilinkTargetRanges: [Range<Int>] = linkScan.spans.compactMap { span in
            guard span.link.syntax == .wikilink,
                  span.targetRange.lowerBound >= 0,
                  span.targetRange.upperBound < linkUTF16Offsets.count else { return nil }
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

/// Walks the AST ONCE, collecting the source ranges of code and — in the same
/// pass, see `MarkdownSpanBuilder.swift` for the prose visits — the style spans.
///
/// A node whose `range` is nil contributes nothing rather than guessing — a
/// dropped range means a link inside that code is treated as a real link, which
/// is a visible wrong answer, whereas a GUESSED range could suppress a real
/// link silently. Neither is good; the visible one is preferable.
///
/// `SourceRange` is `Range<SourceLocation>` and swift-markdown has ALREADY
/// converted cmark's inclusive end column into an exclusive one (it adds 1 in
/// `CommonMarkConverter.range(_:)`), so `upperBound.column` is passed straight
/// through to `SourceOffsetMap.utf16Range`, which also treats `toColumn` as
/// exclusive. Adding a further +1 here would overrun every node by one unit.
struct MarkdownASTCollector: MarkupWalker {
    let map: SourceOffsetMap
    /// The FULL text, used to tell a fenced code block from an indented one
    /// (see `isFenced(at:code:)`) and to locate a task item's checkbox marker.
    let text: NSString
    var regions: [CodeRegion] = []
    var styleSpans: [StyleSpan] = []
    var outline: [OutlineEntry] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let ns = resolve(codeBlock.range) else { return }
        regions.append(CodeRegion(range: ns,
                                  kind: isFenced(at: ns, code: codeBlock.code)
                                      ? .fencedCodeBlock : .indentedCodeBlock))
        styleSpans.append(StyleSpan(range: swiftRange(ns),
                                    kind: .codeBlock(language: codeBlock.language)))
        // Only a FENCED block has fence lines; an indented one yields nothing.
        appendMarkers(MarkdownMarkers.fences(in: ns, text: text), .codeFence)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let ns = resolve(inlineCode.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .inlineCode))
        styleSpans.append(StyleSpan(range: swiftRange(ns), kind: .inlineCode))
        appendMarkers(MarkdownMarkers.backtickPair(in: ns, text: text), .inlineCode)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let ns = resolve(html.range) else { return }
        regions.append(CodeRegion(range: ns, kind: .htmlBlock))
    }

    /// Fenced or indented? swift-markdown models both as `CodeBlock`, and
    /// `language` / `fenceInfo` is nil for a bare ``` opener as well as for
    /// indented code, so neither can discriminate.
    ///
    /// `CodeBlock.range` starts at the block's CONTENT, never at column 1 — a
    /// 4-space indented block reports its start already PAST the indent. So
    /// leading whitespace is invisible here, and column arithmetic cannot help
    /// either: a fence nested in a list and an indented code block both report
    /// column 5. The discriminator has to be the text itself, in two parts.
    ///
    /// 1. The range must START with a run of 3+ backticks or tildes. Necessary,
    ///    not sufficient — an INDENTED block whose first content line happens to
    ///    be ```` ``` ```` also satisfies it, and reading that as a fence made
    ///    the block suppress links, which the owner's ruling forbids.
    /// 2. So: reject when the block's own CONTENT contains a line that would
    ///    have CLOSED that fence — a bare run of the same character, at least as
    ///    long. CommonMark guarantees a real fenced block can never contain such
    ///    a line, because it would have terminated the block. Only an indented
    ///    block can. `[[X]]` inside `"    ```\n    [[X]]\n    ```"` therefore
    ///    stays a link, while ```` ```` ````-fenced content containing ```` ``` ````
    ///    (a shorter run) is still correctly fenced.
    ///
    /// Every content line is checked, not just the first: an indented block may
    /// open with an info-string line (`    ```swift`), which is not itself a
    /// closer, and only reveal the bare closer further down.
    ///
    /// "Bare" matters: ` ```text ` does not close a fence, so a fenced block MAY
    /// contain it, and it must not be mistaken for indented code.
    ///
    /// KNOWN LIMIT — an accepted REGRESSION against the old scanner.
    ///
    /// An indented block whose first line is fence-shaped WITH an info string,
    /// and which never contains a line that closes THAT run, still reads as
    /// fenced and suppresses. The old scanner required `indent <= 3` on the raw
    /// line, so it saw these as ordinary text and kept the link; we drop it.
    /// Direction is link rot: the link leaves the graph and a rename stops
    /// rewriting it. Accepted by the owner — the shapes are rare in prose and
    /// the alternative risks the fence direction, which is verified sound.
    ///
    /// The class is wider than "unterminated". All five measured members, each
    /// yielding `["X"]` from the old scanner and `[]` from this one:
    ///
    ///   1. unterminated:            `"    ```swift\n    [[X]]\n"`
    ///   2. closer indented further: `"    ```swift\n    [[X]]\n     ```\n"`
    ///   3. closer SHORTER than the opener:
    ///                               `"    ````js\n    [[X]]\n    ```\n"`
    ///   4. closer of the WRONG character:
    ///                               `"    ~~~x\n    [[X]]\n    ```\n"`
    ///   5. info line alone:         `"    ```swift\n"` — same misclassification,
    ///      though it holds no link, so no link is actually lost.
    ///
    /// 3 and 4 are worth naming separately: they are not "unterminated" at all —
    /// they have a closing-looking line that simply does not close the opener's
    /// run, so `code` never contains a qualifying bare closer.
    ///
    /// A block with a MATCHING bare closer is classified correctly and is NOT
    /// part of this class: `"    ```swift\n    [[X]]\n    ```\n"` keeps `[[X]]`,
    /// matching the old scanner exactly.
    private func isFenced(at range: NSRange, code: String) -> Bool {
        guard let marker = leadingFenceRun(in: sourceLine(at: range)) else {
            return false
        }
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            if let closer = leadingFenceRun(in: String(line)),
               closer.character == marker.character,
               closer.length >= marker.length,
               closer.isBare {
                return false
            }
        }
        return true
    }

    /// The source text from `range`'s start to the end of that line.
    private func sourceLine(at range: NSRange) -> String {
        var end = range.location
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        guard end > range.location else { return "" }
        return text.substring(with: NSRange(location: range.location,
                                            length: end - range.location))
    }

    private func leadingFenceRun(in line: String)
        -> (character: Character, length: Int, isBare: Bool)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let rest = line[run.endIndex...]
        return (first, run.count, rest.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" })
    }

    func resolve(_ sourceRange: SourceRange?) -> NSRange? {
        guard let r = sourceRange else { return nil }
        return map.utf16Range(fromLine: r.lowerBound.line,
                              fromColumn: r.lowerBound.column,
                              toLine: r.upperBound.line,
                              toColumn: r.upperBound.column)
    }
}
