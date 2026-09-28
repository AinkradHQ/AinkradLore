import AppKit
import SwiftUI
import AinkradAppKit

/// WHERE things are: the text column's own geometry, and the entry point that
/// puts the caret at an offset and scrolls it on screen.
///
/// The two arrived here from different directions — the column geometry was
/// always its own concern, and `scrollToOffset` was parked in
/// `MarkdownStyleRendering.swift` to keep `MarkdownEditor.swift` short — but
/// they answer the same kind of question, and neither is about turning markdown
/// into attributes.

/// The scroll-to-offset entry point `OutlineSection` drives, kept here rather
/// than in `MarkdownEditor.swift` to leave that file's AppKit wiring alone —
/// see that file's line-count note.
extension MarkdownEditor.Coordinator {
    /// Moves the caret to `offset` (UTF-16, into the editor's text) and
    /// scrolls it on screen. Clamped rather than guarded: an outline entry
    /// computed against a slightly stale model (edit landed between parse and
    /// click) should still land somewhere sane, not be silently dropped.
    @MainActor func scrollToOffset(_ offset: Int) {
        guard let tv = textView else { return }
        let length = (tv.string as NSString).length
        let clamped = max(0, min(offset, length))
        let range = NSRange(location: clamped, length: 0)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
    }
}

/// Where the text column sits inside the editor's width.
///
/// A value, not a view: the owner's complaint was that text "runs edge to
/// edge", and the numbers that fix it are worth asserting directly rather than
/// through a view host. `MarkdownEditor` had `NSSize(width: 16, height: 16)`
/// hard-coded while `MarkdownTheme.contentInset` and `.maxMeasure` sat
/// declared and unused.
enum MarkdownEditorLayout {

    /// Left-aligns the measured text column for a view `width` points wide.
    ///
    /// This used to CENTRE the column — `(viewWidth - maxMeasure) / 2` — which
    /// on a wide pane pushed the text into the middle of the window and left a
    /// large empty margin before every line. The measure cap is what keeps
    /// lines readable; centering was never doing that work, and the column now
    /// simply starts where the pane starts.
    static func containerInset(forViewWidth viewWidth: CGFloat,
                               theme: MarkdownTheme) -> NSSize {
        // Clamped so a view narrower than twice the inset still leaves a
        // positive column rather than an inverted one.
        let horizontal = min(theme.contentInset, max(0, viewWidth / 2 - 1))
        return NSSize(width: horizontal, height: theme.contentInset)
    }

    /// The text container's own width for a view `viewWidth` points wide.
    ///
    /// `maxMeasure` is a MAXIMUM, not a fixed width: pinning the container to
    /// it regardless of the view's actual width left the container wider than
    /// the visible pane on any window narrower than the measure, and with
    /// `isHorizontallyResizable = false` and no horizontal scroller that
    /// overflow was clipped and unreachable — worse than the centring this
    /// task removed. The container must fit inside whatever space the inset
    /// leaves, so it is capped at both the theme's measure AND the space
    /// actually available after both horizontal insets.
    static func containerWidth(forViewWidth viewWidth: CGFloat,
                               theme: MarkdownTheme) -> CGFloat {
        let inset = containerInset(forViewWidth: viewWidth, theme: theme)
        let available = max(0, viewWidth - inset.width * 2)
        guard let measure = theme.maxMeasure else { return available }
        return min(measure, available)
    }
}
