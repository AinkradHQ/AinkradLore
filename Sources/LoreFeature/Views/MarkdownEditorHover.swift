import AppKit
import SwiftUI

/// The link hover preview: deciding that a pointer resting over a `[[link]]`
/// means "show me what is in there", and doing it without costing the writer
/// anything.
extension MarkdownEditor.Coordinator {

    /// How long the pointer must rest before a preview appears.
    ///
    /// Long enough that crossing a link on the way somewhere else shows
    /// nothing — a preview that fires on every pass turns a document full of
    /// links into a flicker — and short enough to feel like an answer rather
    /// than a wait. This is the whole difference between a considered feature
    /// and a twitchy one.
    static let hoverDelay: Duration = .milliseconds(450)

    /// Called on every pointer move, with the index under it.
    func hoverChanged(to index: Int?) {
        // The underline is IMMEDIATE, unlike the preview below. They answer
        // different questions: the preview says "here is what is in there",
        // which is worth waiting for stillness; the underline says "this is a
        // link", which the pointer arriving has already asked. Delaying it
        // would make links feel unresponsive to find.
        underlineLink(at: index)

        // Any movement cancels the pending intent, including movement WITHIN
        // the same link: the delay measures stillness, not presence.
        hoverTask?.cancel()
        hoverTask = nil

        guard let index, let tv = textView else {
            previewPanel.hide()
            return
        }
        guard let target = LinkCompletionContext.target(in: tv.string, at: index) else {
            previewPanel.hide()
            return
        }
        // Already showing this exact link: leave it alone rather than
        // dismissing and re-presenting, which flickers as the pointer moves
        // across a single link's characters.
        if previewPanel.isVisible, previewPanel.shownTarget == target { return }
        previewPanel.hide()

        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: MarkdownEditor.Coordinator.hoverDelay)
            guard !Task.isCancelled else { return }
            await self?.presentPreview(for: target, at: index)
        }
    }

    /// Reads the target and shows it.
    ///
    /// The file read happens off the main actor: it is small, but it is still
    /// disk I/O on a path triggered by pointer movement, and this codebase's
    /// standing rule is that the main actor does not wait on the filesystem.
    private func presentPreview(for target: String, at index: Int) async {
        let name = LinkCompletionContext.documentName(of: target)
        guard let url = resolveHoverTarget?(name) else { return }

        let excerpt: String? = await Task.detached(priority: .userInitiated) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return LinkPreview.excerpt(from: contents)
        }.value
        guard let excerpt, !Task.isCancelled, let tv = textView else { return }

        // Re-checked after the await: the pointer may have moved, the document
        // may have been swapped, or the panel dismissed while the read was in
        // flight. Presenting now would show a preview for a link nobody is
        // pointing at.
        guard hoverTask?.isCancelled == false else { return }
        let rect = tv.firstRect(
            forCharacterRange: NSRange(location: index, length: 0),
            actualRange: nil)
        previewPanel.show(
            title: url.deletingPathExtension().lastPathComponent,
            excerpt: excerpt,
            target: target,
            tokens: tokens,
            near: rect,
            over: tv)
    }

    // MARK: - The hover underline

    /// Underlines the link under the pointer, and nothing else.
    ///
    /// A TEMPORARY attribute, never the storage's own. This is the same
    /// distinction `applyFocusDimming` rests on and it matters for the same
    /// reason: `MarkdownStyleRendering` owns the storage's real attributes and
    /// rewrites them on every restyle, so an underline written there would be
    /// erased by the next keystroke — or, worse, survive into something that
    /// read attributes back out. Hover is presentation and stays presentation.
    ///
    /// The range comes from the STYLE SPANS the coordinator already holds, not
    /// from a second scan of the text: those are the exact ranges the renderer
    /// coloured accent, so what underlines and what looks clickable cannot
    /// disagree.
    func underlineLink(at index: Int?) {
        guard let tv = textView, let layoutManager = tv.layoutManager else { return }

        let range = index.flatMap { linkRange(containing: $0) }
        // Nothing to do — including the common case of moving within the same
        // link, where removing and re-adding would flicker the underline on
        // every pointer event.
        if range == hoveredLinkRange { return }

        // CLAMPED, not trusted. The stored range was recorded against the
        // document as it was when the pointer last moved, and an edit may have
        // shortened it since — `removeTemporaryAttribute` past the end traps.
        if let previous = hoveredLinkRange {
            let live = NSIntersectionRange(
                previous, NSRange(location: 0, length: (tv.string as NSString).length))
            if live.length > 0 {
                layoutManager.removeTemporaryAttribute(
                    .underlineStyle,
                    forCharacterRange: live)
            }
        }
        hoveredLinkRange = range
        guard let range else { return }
        layoutManager.addTemporaryAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            forCharacterRange: range)
    }

    /// The `.link`/`.wikilink` span containing `index`, as an `NSRange`.
    ///
    /// The INNERMOST match wins. Spans arrive parent-first and a link's own
    /// range can contain nested inline spans, but two link spans never
    /// overlap — so taking the shortest containing one is both correct and
    /// stable, and costs a single pass.
    private func linkRange(containing index: Int) -> NSRange? {
        var best: Range<Int>?
        for span in styleCache.spans {
            switch span.kind {
            case .link, .wikilink: break
            default: continue
            }
            guard span.range.contains(index) else { continue }
            if let current = best, current.count <= span.range.count { continue }
            best = span.range
        }
        guard let best else { return nil }
        let range = NSRange(location: best.lowerBound, length: best.count)
        let document = NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)
        guard NSMaxRange(range) <= document.length else { return nil }
        return range
    }
}
