import Foundation

/// Which markers are hidden, given where the selection is.
///
/// Pure and text-view-free on purpose: this is the rule that decides what the
/// user sees, and it is asserted directly rather than through a view host.
enum MarkdownReveal {

    /// Blocks, delimited by blank lines. Deliberately cheap: this runs on every
    /// selection change, and a full AST walk per caret move is exactly the lag
    /// this milestone exists to avoid.
    ///
    /// Scans in UTF-16 units but counts LINE TERMINATORS, not units: "\r\n" is
    /// one terminator (two units), and a lone "\r" or lone "\n" is one
    /// terminator each. A blank line is two consecutive terminators with
    /// nothing but spaces/tabs between them — this is what makes a CRLF
    /// document's ordinary single line breaks NOT count as a blank line.
    static func blocks(in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var result: [Range<Int>] = []
        var start = 0
        var index = 0
        var terminatorRun = 0

        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 0x0D || unit == 0x0A {
                // Consume a full terminator: a lone unit, or a "\r\n" pair.
                var terminatorEnd = index + 1
                if unit == 0x0D, terminatorEnd < ns.length, ns.character(at: terminatorEnd) == 0x0A {
                    terminatorEnd += 1
                }
                terminatorRun += 1
                if terminatorRun >= 2 {
                    if terminatorEnd > start { result.append(start..<terminatorEnd) }
                    start = terminatorEnd
                    terminatorRun = 0
                }
                index = terminatorEnd
            } else if unit != 0x20 && unit != 0x09 {
                terminatorRun = 0
                index += 1
            } else {
                index += 1
            }
        }
        if start < ns.length { result.append(start..<ns.length) }
        return result.isEmpty ? [0..<max(ns.length, 0)] : result
    }

    /// The source range whose syntax is SHOWN, or `nil` when nothing is.
    ///
    /// ## The unit is the LINE, not the block
    ///
    /// This used to reveal the whole blank-line-delimited BLOCK the selection
    /// touched, which is the unit `blocks(in:)` returns and the unit the
    /// renderer re-attributes in. Sharing one unit for both was tidy and wrong:
    /// a five-item list with no blank line between items is ONE block, so
    /// putting the caret in item 3 showed the `- ` marker on all five. The
    /// editor Ahmed is measuring this against reveals the line you are on and
    /// leaves the rest rendered.
    ///
    /// The two concepts are therefore separated. `blocks(in:)` stays the
    /// STYLING unit — it is load-bearing for span bucketing and for the edit
    /// fast path, both of which rest on "a markdown span does not cross a blank
    /// line", which is true of blocks and false of lines. This is the REVEAL
    /// unit, and it is computed from the selection alone.
    ///
    /// ## Except for spans a single pair of markers delimits
    ///
    /// A span whose syntax is ONE opening marker and ONE closing marker, with
    /// the content between them, reveals whole when the caret is anywhere
    /// inside it. Otherwise `**bold` on one line and `across lines**` on the
    /// next would show the opening `**` and hide the closing one — half a
    /// construct, and the caret standing in syntax it cannot see the end of.
    /// A fenced code block is the same shape written large: its markers are the
    /// two fence lines, and a line-scoped rule alone would hide both whenever
    /// the caret sat on line 3 of the code.
    ///
    /// This is the concern that argued for block-scoped reveal in the first
    /// place, and it is a real one — it is answered here directly rather than
    /// by making every construct in the document coarser.
    ///
    /// Deliberately NOT extended to block quotes, list items or headings.
    /// Those can span lines too, but each line carries its OWN marker, so
    /// there is no pair to split — and revealing them together is precisely
    /// the defect this change exists to remove.
    ///
    /// `isFocused` is first-responder state, not selection state. An unfocused
    /// text view KEEPS its selection, so without this the line the caret was
    /// last on stayed revealed and kept showing its syntax to a reader who was
    /// no longer editing. Reveal exists to let you edit the markers you are
    /// standing in; standing in them requires focus.
    /// The single-pair spans that actually CROSS a line, which are the only
    /// ones `revealedRange` can ever widen over.
    ///
    /// Derived once per text change and cached on `MarkdownEditorReveal.Index`,
    /// because the alternative is what the first version of this did: scan
    /// every span in the document, twice, on every caret move. MEASURED at
    /// 1,000 lines and 2,184 spans that cost 3.2 ms per keystroke — it turned a
    /// 4.25 ms keystroke into 7.47 ms — and it scaled with the DOCUMENT, which
    /// is exactly the property the caret path is supposed not to have.
    ///
    /// Almost always empty: a span delimited by one marker pair that also spans
    /// a line break is a fenced code block, or prose someone hard-wrapped in
    /// the middle of an emphasis run.
    static func wideSpans(in text: String, spans: [StyleSpan]) -> [Range<Int>] {
        let ns = text as NSString
        return spans.compactMap { span in
            guard span.kind.isDelimitedByASinglePair,
                  span.range.lowerBound >= 0, span.range.upperBound <= ns.length,
                  span.range.lowerBound < span.range.upperBound else { return nil }
            let range = NSRange(location: span.range.lowerBound, length: span.range.count)
            // A span inside one line can never widen past that line, so it
            // cannot affect the answer and does not need to be carried.
            let hasBreak = ns.rangeOfCharacter(from: .newlines, options: [], range: range)
            return hasBreak.location == NSNotFound ? nil : span.range
        }
    }

    static func revealedRange(in text: String, selection: NSRange,
                              spans: [StyleSpan], isFocused: Bool) -> Range<Int>? {
        revealedRange(in: text, selection: selection,
                      wideSpans: wideSpans(in: text, spans: spans), isFocused: isFocused)
    }

    /// The same, for a caller holding the cached `wideSpans` — the caret path.
    static func revealedRange(in text: String, selection: NSRange,
                              wideSpans: [Range<Int>], isFocused: Bool) -> Range<Int>? {
        guard isFocused else { return nil }
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        // `selection` arrives from AppKit and is clamped rather than trusted:
        // `lineRange(for:)` traps on a range past the end, and this runs on
        // every caret move.
        let location = min(max(selection.location, 0), ns.length)
        let length = min(max(selection.length, 0), ns.length - location)
        let line = ns.lineRange(for: NSRange(location: location, length: length))
        var lower = line.location
        var upper = NSMaxRange(line)
        // Widen over every single-pair span the line overlaps. Repeated until
        // it settles, because these nest — `**bold with `code` inside**` —
        // and widening over the inner one can bring the outer one into scope.
        // Bounded by the span count and in practice one or two passes.
        var widened = !wideSpans.isEmpty
        while widened {
            widened = false
            for span in wideSpans {
                // STRICT overlap. An inclusive test treats a span that merely
                // ABUTS the line's end as overlapping it, so the caret on line
                // one of `**a**\n**b**` widened over line two's span and
                // revealed it as well — the block-scoped behaviour creeping
                // back in through the exception. Caught by
                // `test_revealingOneLineLeavesTheRestOfTheParagraphRendered`.
                guard span.lowerBound < upper && lower < span.upperBound else { continue }
                if span.lowerBound < lower { lower = span.lowerBound; widened = true }
                if span.upperBound > upper { upper = span.upperBound; widened = true }
            }
        }
        return lower..<upper
    }

    /// The marker ranges that must be COLLAPSED for this selection.
    ///
    /// A marker is shown only when it lies wholly inside `revealedRange`.
    /// Containment rather than overlap: half a `**` is not something anyone can
    /// edit, and a marker that straddled the boundary would flicker as the
    /// caret crossed it.
    static func hiddenMarkers(spans: [StyleSpan], selection: NSRange,
                              text: String, isFocused: Bool) -> [Range<Int>] {
        let revealed = revealedRange(in: text, selection: selection,
                                     spans: spans, isFocused: isFocused)
        return spans.compactMap { span in
            guard case .marker = span.kind else { return nil }
            return isRevealed(span.range, in: revealed) ? nil : span.range
        }
    }

    /// Whether `range`'s syntax is shown. The one place the containment rule
    /// is written, so the full render and the per-block restyle cannot come to
    /// different conclusions about the same marker.
    static func isRevealed(_ range: Range<Int>, in revealed: Range<Int>?) -> Bool {
        guard let revealed else { return false }
        return range.lowerBound >= revealed.lowerBound
            && range.upperBound <= revealed.upperBound
    }
}
