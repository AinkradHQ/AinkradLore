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
        let rect = tv.firstRect(forCharacterRange: NSRange(location: index, length: 0),
                                actualRange: nil)
        previewPanel.show(title: url.deletingPathExtension().lastPathComponent,
                          excerpt: excerpt,
                          target: target,
                          tokens: tokens,
                          near: rect,
                          over: tv)
    }
}
