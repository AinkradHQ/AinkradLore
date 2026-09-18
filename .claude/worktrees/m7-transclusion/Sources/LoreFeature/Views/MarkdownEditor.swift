import SwiftUI
import AppKit
import AinkradAppKit

public struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens
    /// Display preferences. Threaded down from `EditorContext` so the five
    /// places that build a `MarkdownTheme` all build the SAME one — the
    /// alternative was a process-wide current-settings global, which would
    /// have made two Lore instances in one host share a font size.
    let settings: EditorSettings
    /// See `EditorContext.headingCompletions`.
    let headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)?
    /// See `EditorContext.createLinkedNote`.
    let createLinkedNote: (@MainActor (String) -> Bool)?
    /// Rows to offer for the current `[[` prefix. `nil` disables completion
    /// entirely — which is how plain-text documents get no link affordances.
    let completions: (@MainActor (String) -> [IndexRow])?
    /// Tag names matching the current `#` prefix, for `#` completion. `nil`
    /// disables it entirely — same "no capability supplied" shape as
    /// `completions` above, so a document type with no tag pipeline (or a
    /// call site that has not been updated) behaves exactly as before.
    let tagCompletions: (@MainActor (String) -> [String])?
    /// Called with the raw target of a Cmd-clicked `[[…]]` span. `nil` disables
    /// click-to-open.
    let onOpenLink: (@MainActor (String) -> Void)?
    /// Called with the raw target of a click that landed inside a rendered
    /// transclusion (a `![[note]]` embed's drawn content, not its collapsed
    /// source) while ⌥ was held. `nil` disables the beside-open affordance —
    /// same "no capability supplied" shape `onOpenLink == nil` already has —
    /// which is how a plain click still opens the embed in place even when
    /// nothing wired the split-view path up.
    let onOpenLinkBeside: (@MainActor (String) -> Void)?
    /// Called with a `#tag`'s name when clicked in the body. `nil` disables
    /// tag-click-to-filter entirely, matching `onOpenLink`'s "no capability
    /// supplied" shape.
    let onTagClick: (@MainActor (String) -> Void)?
    /// Resolves an `![[target]]` embed's raw target to a file, for
    /// `EmbedRendering`. `nil` — the default — makes every embed render
    /// `.unresolved` (plain wikilink colouring), which is the right answer
    /// for an engine with no link layer, exactly like `completions == nil`.
    let resolveEmbedTarget: (@MainActor (String) -> URL?)?
    /// See `EditorContext.registerExternalChangeHandler`. `nil` disables live
    /// transclusion updates entirely — the same "no capability supplied"
    /// shape `resolveEmbedTarget == nil` already has, which is right for an
    /// engine with no vault (and so no `![[…]]` targets that could ever
    /// change out from under it).
    let registerExternalChangeHandler: (@MainActor (@escaping @MainActor (URL) -> Void) -> UUID)?
    /// Pairs with `registerExternalChangeHandler` — see its doc comment.
    let unregisterExternalChangeHandler: (@MainActor (UUID) -> Void)?
    /// What a picked row inserts. Defaults to the store-blind approximation.
    let linkTarget: @MainActor (IndexRow) -> String
    /// A UTF-16 offset (into `text`) to scroll the caret to and select. Set by
    /// a caller — `OutlineSection` — and cleared back to `nil` once handled,
    /// so re-clicking the same heading still fires: `updateNSView` only acts
    /// on a non-nil value, never on "the value changed".
    let scrollTarget: Binding<Int?>
    /// Whether clicking a `[ ]` marker flips it. Off by default, so a document
    /// type that has no task lists — and, crucially, a READ-ONLY session, whose
    /// `markChanged()` is a no-op and whose saves are refused — offers no
    /// affordance it cannot honour. See `MarkdownEditorClicks.swift`.
    let allowsTaskToggle: Bool
    /// See `EditorContext.writePastedImage`. `nil` disables the paste
    /// interception entirely, so a document with no attachment story falls
    /// straight through to AppKit's default paste — exactly the
    /// `completions == nil` / `onOpenLink == nil` pattern above.
    let writePastedImage: (@MainActor (Data, String) -> String?)?
    /// See `EditorContext.writeDroppedFile`. `nil` disables the drop
    /// destination.
    let writeDroppedFile: (@MainActor (URL) -> String?)?
    /// Fired on every selection change with the live document text and
    /// selection — the host's context-menu wiring (`MarkdownEditorMenu.swift`)
    /// uses this to keep its menu items current without reaching back into
    /// AppKit itself. See that file for why the items cannot be computed at
    /// the exact moment of a right-click.
    let onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)?
    /// Called once the text view exists, with the actions its own context
    /// menu should run. See `MarkdownEditorMenu.swift`.
    let registerMenuActions: (@MainActor (EditorMenuActions) -> Void)?

    public init(text: Binding<String>, tokens: HostThemeTokens,
                settings: EditorSettings = .default,
                headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)? = nil,
                createLinkedNote: (@MainActor (String) -> Bool)? = nil,
                completions: (@MainActor (String) -> [IndexRow])? = nil,
                tagCompletions: (@MainActor (String) -> [String])? = nil,
                onOpenLink: (@MainActor (String) -> Void)? = nil,
                onOpenLinkBeside: (@MainActor (String) -> Void)? = nil,
                onTagClick: (@MainActor (String) -> Void)? = nil,
                resolveEmbedTarget: (@MainActor (String) -> URL?)? = nil,
                registerExternalChangeHandler:
                    (@MainActor (@escaping @MainActor (URL) -> Void) -> UUID)? = nil,
                unregisterExternalChangeHandler: (@MainActor (UUID) -> Void)? = nil,
                linkTarget: @escaping @MainActor (IndexRow) -> String
                    = { LinkCompletionContext.insertableTarget(for: $0) },
                scrollTarget: Binding<Int?> = .constant(nil),
                allowsTaskToggle: Bool = false,
                writePastedImage: (@MainActor (Data, String) -> String?)? = nil,
                writeDroppedFile: (@MainActor (URL) -> String?)? = nil,
                onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)? = nil,
                registerMenuActions: (@MainActor (EditorMenuActions) -> Void)? = nil) {
        self._text = text; self.tokens = tokens; self.settings = settings
        self.headingCompletions = headingCompletions
        self.createLinkedNote = createLinkedNote
        self.completions = completions; self.tagCompletions = tagCompletions
        self.onOpenLink = onOpenLink
        self.onOpenLinkBeside = onOpenLinkBeside
        self.onTagClick = onTagClick
        self.resolveEmbedTarget = resolveEmbedTarget
        self.registerExternalChangeHandler = registerExternalChangeHandler
        self.unregisterExternalChangeHandler = unregisterExternalChangeHandler
        self.linkTarget = linkTarget
        self.scrollTarget = scrollTarget
        self.allowsTaskToggle = allowsTaskToggle
        self.writePastedImage = writePastedImage
        self.writeDroppedFile = writeDroppedFile
        self.onSelectionChange = onSelectionChange
        self.registerMenuActions = registerMenuActions
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tokens: tokens, settings: settings)
    }

    // `makeNSView`, `updateNSView`, `dismantleNSView` and `addStylingNotice`
    // — the AppKit-object lifecycle — live in `MarkdownEditorView.swift`.
    // This file keeps the `NSViewRepresentable`'s declared surface (the
    // properties, the initializer, `makeCoordinator`) together with the
    // `Coordinator` those lifecycle methods drive.

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var tokens: HostThemeTokens
        /// Floats a document's opening text beside a hovered `[[link]]`.
        let previewPanel = LinkPreviewPanel()
        /// Cancels a pending hover when the pointer moves on before the delay
        /// elapses. Held so each move REPLACES the last intent rather than
        /// queueing another one.
        var hoverTask: Task<Void, Never>?
        /// Resolves a link target to a file. Supplied by the shell; the same
        /// closure embeds already use, so a hover and an embed can never
        /// disagree about what a name points at.
        var resolveHoverTarget: (@MainActor (String) -> URL?)?
        /// Creates a note for the typed text, reporting whether it worked.
        /// Nil when the shell offers no create path, which suppresses the
        /// popup's "Create …" row entirely.
        var createLinkedNote: (@MainActor (String) -> Bool)?
        /// See `EditorContext.headingCompletions`.
        var headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)?

        /// Kept in sync by `updateNSView`, so changing a setting restyles the
        /// document the user is already looking at rather than only the next
        /// one they open.
        var settings: EditorSettings
        var completions: (@MainActor (String) -> [IndexRow])?
        /// See `MarkdownEditor.tagCompletions`.
        var tagCompletions: (@MainActor (String) -> [String])?
        var onOpenLink: (@MainActor (String) -> Void)?
        /// See `MarkdownEditor.onOpenLinkBeside`.
        var onOpenLinkBeside: (@MainActor (String) -> Void)?
        /// See `MarkdownEditor.onTagClick`.
        var onTagClick: (@MainActor (String) -> Void)?
        /// See `MarkdownEditor.resolveEmbedTarget`. Never left `nil` in
        /// practice — `makeNSView`/`updateNSView` always install at least the
        /// "no candidates" closure, matching how `completions` degrades.
        var resolveEmbedTarget: @MainActor (String) -> URL? = { _ in nil }
        var linkTarget: @MainActor (IndexRow) -> String
            = { LinkCompletionContext.insertableTarget(for: $0) }
        /// See `MarkdownEditor.allowsTaskToggle`.
        var allowsTaskToggle = false
        /// See `MarkdownEditor.writePastedImage`. `nil` — the default — means
        /// paste interception is off, matching `resolveEmbedTarget`'s
        /// "no capability supplied" shape before `makeNSView` installs the
        /// real one.
        var writePastedImage: (@MainActor (Data, String) -> String?)?
        /// See `MarkdownEditor.writeDroppedFile`.
        var writeDroppedFile: (@MainActor (URL) -> String?)?
        weak var textView: NSTextView?
        /// Shown only above the hard cap — the editor saying, in words, that it
        /// has stopped styling rather than leaving the user to wonder.
        weak var stylingNotice: NSTextField?
        let completionPanel = LinkCompletionPanel()
        /// See `MarkdownEditor.onSelectionChange`.
        var onSelectionChange: (@MainActor (String, NSRange, Int) -> Void)?

        /// Long enough that a burst of typing is one parse, short enough that
        /// the picture settles within a pause the user does not notice.
        static let parseDebounce: TimeInterval = 0.15

        /// The spans on screen and the string they describe. See
        /// `MarkdownStyleCache` for why this is not recomputed per call.
        ///
        /// Internal rather than `private(set)` only because the styling
        /// pipeline that mutates it now lives in `MarkdownEditorReveal.swift`,
        /// and Swift has no cross-file `private`. Nothing outside these two
        /// files writes it.
        var styleCache = MarkdownStyleCache()
        var parseTimer: Timer?
        /// Bumped per off-actor parse launched. A result whose generation is no
        /// longer the current one is discarded — see `parseNow`.
        var parseGeneration = 0
        var lastViewportWindow: NSRange?
        /// Block ranges, per-block span buckets and list depths for the CURRENT
        /// text. Rebuilt only when the text is re-rendered — never on a caret
        /// move, because `MarkdownReveal.blocks(in:)` scans the whole string.
        /// See `MarkdownEditorReveal.Index`.
        var revealIndex = MarkdownEditorReveal.Index.empty
        /// The source range whose markers are currently revealed, or `nil` when
        /// none are. The reveal state in full: if a caret move leaves this
        /// unchanged there is nothing to redraw, which is what keeps arrowing
        /// free of styling work.
        ///
        /// A RANGE rather than the block indices this used to hold, because the
        /// reveal unit is now the LINE — see `MarkdownReveal.revealedRange`. The
        /// cost of the change is that moving the caret between two lines of one
        /// paragraph now flips this where it used to be a no-op; the work that
        /// buys is one block restyled, not one document.
        var revealedRange: Range<Int>?
        /// Drawing regions for pipe tables, rebuilt whenever their reserved row
        /// heights are. Held here rather than recomputed at assembly time
        /// because measuring a grid and reserving room for it must come from
        /// ONE layout — a table measured one way and reserved another is drawn
        /// over the paragraph beneath it.
        var tableRegions: [MarkdownBlockBackgrounds.Region] = []
        /// Drawing regions for transcluded `![[note]]` embeds, rebuilt in the
        /// SAME pass that reserves their heights — held here for exactly the
        /// reason `tableRegions` is, and against exactly the same failure: a
        /// note measured one way and reserved another is drawn over the
        /// paragraph beneath it. Each region carries the attributed string its
        /// height was measured from, so the paint cannot drift from the gap.
        var transclusionRegions: [MarkdownBlockBackgrounds.Region] = []
        /// Resolved embed content and its measured height, per target. Lives
        /// on the coordinator — one per open document — so a re-render costs a
        /// cache hit rather than a second document's layout. This is what makes
        /// typing free of embed measurement; see
        /// `MarkdownRevealBenchmark.test_typingInHostDoesNotRemeasureEmbeds`.
        let transclusionCache = TransclusionCache()
        /// Every currently-embedded transclusion target's on-disk mtime, as of
        /// the last time `detectExternalTransclusionChanges()` checked it —
        /// see that function (`MarkdownEditorParsing.swift`).
        ///
        /// This is the BACKSTOP, not the primary mechanism: the primary path
        /// is `handleExternalChange(to:)`, invoked with NO editor interaction
        /// whenever `EditorContext.registerExternalChangeHandler`'s sink
        /// fires (a watcher-driven rescan, or another pane's save). This
        /// mtime check exists for what that push can miss — a same-second
        /// edit on a filesystem with coarse mtime resolution, where the
        /// watcher fires but the row's `updated` timestamp does not actually
        /// change (fix round 1, Critical #1's "belt and suspenders" ruling)
        /// — and is checked only off the per-keystroke path: on-appear
        /// (`makeNSView`) and on-focus (`onBecomeFirstResponder`), never from
        /// `applyStyles()` (fix round 1, Important #2 — a keystroke used to
        /// pay for one `stat()` per embed SPAN OCCURRENCE, synchronously, on
        /// every character typed).
        var embeddedTargetMTimes: [URL: Date] = [:]
        /// The token `EditorContext.registerExternalChangeHandler` handed
        /// back, and the paired unregister closure — held so `tearDown()` can
        /// unsubscribe, or the closure captured by the registration (which
        /// captures this coordinator) would keep it alive for as long as the
        /// vault stays open, well past this editor's own lifetime.
        var externalChangeToken: UUID?
        var unregisterExternalChangeHandler: (@MainActor (UUID) -> Void)?
        /// Counts `FileManager.attributesOfItem` calls made by
        /// `detectExternalTransclusionChanges()` — ONE per distinct embedded
        /// target per call, never per span occurrence. Exists so
        /// `MarkdownRevealBenchmark`'s per-keystroke gate can assert this
        /// backstop costs ZERO filesystem work on the typing path (fix round
        /// 1, Important #2), the same shape `blockBackgroundRefreshes`
        /// already asserts for decoration rebuilds.
        var externalChangeStatCalls = 0
        /// Set by `restyleBlock` when a block it just re-attributed holds a
        /// transcluded embed, and drained ONCE per pass by
        /// `prepareTransclusionsIfNeeded`. A flag rather than the work itself
        /// because `renderStylesForEdit` restyles several blocks per keystroke
        /// and the reservation is whole-document — fix round 1, Important 3.
        var needsTransclusionPass = false
        /// How many times the drawn decoration has been rebuilt. Counts the
        /// CALLS, exactly as `applyStylesCalls` does, so "one rebuild per
        /// edit" can be asserted directly rather than inferred from a timing —
        /// the claim fix round 1's Important 3 was made against.
        var blockBackgroundRefreshes = 0
        /// First-responder state as of the last reveal pass. Compared against
        /// the LIVE state on every selection-change notification so a focus
        /// change — which does not move the caret and therefore would not flip
        /// `revealedRange` — still forces a full re-apply rather than
        /// being short-circuited away as "same selection, nothing to do".
        var lastRevealFocus = true
        /// Every `.embed` span's position, source range and owning block, for
        /// the CURRENT text. Rebuilt only when the text is re-rendered, from
        /// the same pass that builds `revealIndex` — never on a caret move.
        ///
        /// Exists because an embed's reveal is NOT a block-level property:
        /// `revealForSelectionChange` only reaches `restyleBlock` when the
        /// set of revealed BLOCKS flips, and arrowing from inside a block
        /// into an embed's own range is not a block flip — so without this
        /// an image stayed collapsed and drawn with the caret invisibly
        /// inside it until the next keystroke or the 150 ms debounce. Fix
        /// round 2, I6. Documents contain very few embeds (usually zero), so
        /// scanning this per caret move is cheap where scanning
        /// `styleCache.spans` would not be.
        var embedIndex: [(fullRange: NSRange, block: Int)] = []
        /// Which entries of `embedIndex` the selection is currently inside.
        /// The embed-level analogue of `revealedBlockIndices`: if a caret
        /// move leaves this unchanged there is no embed work to do.
        var revealedEmbedSpans: Set<Int> = []
        /// Whether the LAST text change was handled by the single-block fast
        /// path rather than a full render. Exists so the bail-out cases can be
        /// asserted directly instead of inferred from a timing — "it fell back"
        /// is the claim, and a timing cannot make it.
        /// Written only by `textDidChange` in `MarkdownEditorEditPath.swift`;
        /// internal rather than `private(set)` because Swift has no cross-file
        /// `private`, exactly as `styleCache` above.
        var lastEditTookFastPath = false
        /// What the last full `renderStyles()` pass actually painted, and from
        /// what. The redundant-redraw guard in `applyStyles` compares against
        /// it; `renderStyles` is the only writer, so it cannot claim a render
        /// that did not happen.
        ///
        /// `nil` until the first render, which is why a fresh editor always
        /// renders once.
        var renderedSnapshot: (text: String, tokens: HostThemeTokens)?
        /// How many times `applyStyles()` has been entered. Counts the CALLS,
        /// not the renders — the two differ exactly when the entry point
        /// decides it has nothing to do, which is the thing under measurement.
        ///
        /// Exists for the same reason `revealIndexBuilds` does: Task 10 could
        /// establish by reading that `updateNSView` calls `applyStyles()`
        /// unconditionally on every ancestor redraw, but "SwiftUI redraws this
        /// per keystroke" is a claim about SwiftUI's scheduling, and reading
        /// cannot settle it. See `MarkdownTypingLagBenchmark`.
        var applyStylesCalls = 0
        /// How many of those calls reached a full `renderStyles()`. The gap
        /// between this and `applyStylesCalls` is what the redundant-render
        /// guard buys.
        var applyStylesRenders = 0
        /// How many times the index has been built. Exists so a test can pin
        /// the claim that a caret move never rebuilds it — the claim is the
        /// whole performance contract of the reveal path, and an earlier
        /// version of this file made it without the code supporting it.
        var revealIndexBuilds = 0
        /// The DOCUMENT's dominant writing direction — the first strong
        /// (Unicode-alphabetic) character anywhere in the text, or `.leftToRight`
        /// when none exists. Rebuilt once per full `renderStyles()` pass, from
        /// the same string every other O(document) step in that pass already
        /// scans, and reused by `applyEmbeds` (both the full-render and the
        /// block-scoped `restyleBlock` path) as the LAST-RESORT fallback for an
        /// embed image's writing direction, when neither the paragraph before
        /// nor after it has a strong character of its own to go on — see
        /// `EmbedGeometry.contextualWritingDirection`. `restyleBlock` never
        /// recomputes it: it only ever runs on a caret move, never a text
        /// change, so the document this was computed from is still current.
        var documentWritingDirection: NSWritingDirection = .leftToRight
        /// How many BLOCKS the incremental reveal path has re-attributed. The
        /// caret contract is O(1) blocks per boundary crossing — two, the one
        /// leaving reveal and the one entering it — and "O(1)" is only a claim
        /// until something counts. Reset by the benchmark, never by the editor.
        var restyledBlockCount = 0
        /// The edit `shouldChangeTextIn` announced, consumed by the very next
        /// `textDidChange`. AppKit always pairs them, and anything that edits
        /// the storage WITHOUT the pair leaves the cache describing a stale
        /// string, which `applyStyles()` then repairs with a real parse.
        /// Internal, not private: `shouldChangeTextIn` and `textDidChange` now
        /// live in `MarkdownEditorEditPath.swift`, and Swift has no cross-file
        /// `private`. Nothing outside that file touches it.
        var pendingEdit: PendingEdit?

        var cachedSpansForTesting: [StyleSpan] { styleCache.spans }
        /// `nonisolated(unsafe)` only so `deinit` can unregister it. It is
        /// written and read exclusively on the main actor; `deinit` merely
        /// hands the opaque token back to `NotificationCenter`, which is
        /// thread-safe. Without the deinit an editor that is released without a
        /// `dismantleNSView` would leak one observer per document opened.
        nonisolated(unsafe) private var scrollObserver: (any NSObjectProtocol)?

        init(text: Binding<String>, tokens: HostThemeTokens,
             settings: EditorSettings = .default) {
            self.text = text; self.tokens = tokens; self.settings = settings
            super.init()
            completionPanel.onPick = { [weak self] item in self?.accept(item) }
        }

        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

        func observeScrolling(of clipView: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.repositionCompletions()
                        self?.restyleForViewportIfNeeded()
                    }
                }
        }

        func tearDown() {
            if let externalChangeToken {
                unregisterExternalChangeHandler?(externalChangeToken)
            }
            externalChangeToken = nil
            completionPanel.hide()
            // The hover preview is a child window of the same host window, so
            // it must go with the editor — and its pending task must be
            // cancelled, or a preview appears half a second after the document
            // it belonged to has been torn down.
            hoverTask?.cancel()
            hoverTask = nil
            previewPanel.hide()
            parseTimer?.invalidate()
            parseTimer = nil
            // Any in-flight off-actor parse now belongs to a torn-down editor;
            // bumping the generation makes its result arrive and be discarded.
            parseGeneration += 1
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
        }

        /// Caret moved without the text changing (click, arrow key). Cheap and
        /// index-free: it can only ever dismiss, never open, so it never asks
        /// the store for rows.
        public func textViewDidChangeSelection(_ notification: Notification) {
            // Live Preview's other half: which markers are hidden depends on
            // where the caret IS, not only on what was typed. Cheap by
            // construction — see `revealForSelectionChange`, which parses
            // nothing and usually does no work at all.
            revealForSelectionChange()
            if let tv = textView {
                onSelectionChange?(tv.string, tv.selectedRange(), tv.spellCheckerDocumentTag)
            }
            guard completionPanel.isVisible, let tv = textView else { return }
            if activeTrigger(in: tv) == nil { completionPanel.hide() }
        }

        /// Focus left the editor. Nothing the list offers can be accepted from
        /// here, so it must not keep floating.
        ///
        /// Also re-applies reveal: `NSTextView` posts this as it loses first
        /// responder, and reveal is a function of focus, so a focus change
        /// must re-apply it exactly as a selection change does. `false` is
        /// passed explicitly rather than read live — see
        /// `tv.onResignFirstResponder`'s doc comment above; this delegate
        /// method is posted from the same `resignFirstResponder` call, before
        /// `NSWindow` has reassigned first responder away from `tv`.
        public func textDidEndEditing(_ notification: Notification) {
            completionPanel.hide()
            revealForSelectionChange(forcedFocus: false)
        }

        /// `NSText` posts this only on the first EDIT after becoming first
        /// responder, not on becoming it — `tv.onBecomeFirstResponder` above
        /// is what actually covers "focus arrived here". Kept for the case
        /// this DOES fire (a click that both focuses and edits in one step):
        /// the live read is correct here, since `becomeFirstResponder` has
        /// already returned by the time any edit can happen.
        public func textDidBeginEditing(_ notification: Notification) {
            revealForSelectionChange()
        }

        // MARK: - Keys the popup owns, and only while it is open

        public func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            // The panel owns Enter, Tab, the arrows and Escape WHILE IT IS
            // OPEN. Only once it is closed do Enter and Tab mean "continue this
            // list" and "indent it" — see `MarkdownEditorTyping`.
            guard completionPanel.isVisible else {
                return MarkdownEditorTyping.handle(selector, in: tv)
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                completionPanel.moveSelection(by: -1); return true
            case #selector(NSResponder.moveDown(_:)):
                completionPanel.moveSelection(by: 1); return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                completionPanel.pickSelected(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                completionPanel.hide(); return true
            default:
                return false
            }
        }

        // MARK: - Completion

        // MARK: - Click-to-open

        /// Returns whether a link was actually opened.
        func openLink(atUTF16 index: Int) -> Bool {
            guard let tv = textView, let onOpenLink else { return false }
            let text = tv.string
            guard let clicked = Range(NSRange(location: index, length: 0), in: text)?.lowerBound
            else { return false }
            let offset = text.distance(from: text.startIndex, to: clicked)
            guard let target = LinkCompletionContext.target(in: text, at: offset)
            else { return false }
            onOpenLink(target)
            return true
        }

        /// A click inside a RENDERED transclusion (`transclusionRegions`,
        /// built by `TransclusionStyling.prepare` every render pass — see
        /// `MarkdownEditorDecoration`) opens the embed's source note; ⌥-click
        /// opens it beside, through `onOpenLinkBeside` — the same
        /// `store.openInSecondaryPane` path an ⌥-click already opens a
        /// sidebar row beside (`LoreRootView.openRow`), not a second one.
        ///
        /// ALWAYS returns `true` once `index` falls inside a transclusion
        /// region, whether or not a handler actually fires — the region is
        /// COLLAPSED source (`TransclusionStyling.prepare` collapses it every
        /// time it is not the one the caret is literally inside), so once a
        /// click lands here it must never fall through to
        /// `super.mouseDown`'s caret placement: doing so would be exactly the
        /// "caret inside drawn content" the M6 rule forbids. The `defer`
        /// parks the caret right after the embed instead — the same "caret
        /// goes just past what the click activated" contract `toggleTask`
        /// already keeps for a flipped checkbox.
        @MainActor func openTransclusion(atUTF16 index: Int, beside: Bool) -> Bool {
            guard let tv = textView else { return false }
            guard let region = transclusionRegions.first(where: { region in
                guard case .transclusion = region.kind else { return false }
                return index >= region.range.location && index <= NSMaxRange(region.range)
            }) else { return false }

            defer {
                tv.setSelectedRange(NSRange(location: NSMaxRange(region.range), length: 0))
            }

            let ns = tv.string as NSString
            guard NSMaxRange(region.range) <= ns.length else { return true }
            // Re-read the LIVE text at the region's own range rather than
            // trusting a cached target string — the same "cached offset is a
            // candidate, never an authority" rule `toggleTask`'s doc comment
            // spells out. `region.range` is the WHOLE source form (`!`, both
            // brackets, the target — see `StyleSpan.Kind.embed`'s doc
            // comment), so stripping the fixed `![[`/`]]` delimiters is
            // enough; anything else here means the live text no longer
            // matches what this region was built from, and the click is
            // simply absorbed rather than opening something stale.
            let raw = ns.substring(with: region.range)
            guard raw.hasPrefix("![["), raw.hasSuffix("]]") else { return true }
            let target = String(raw.dropFirst(3).dropLast(2))
            guard !target.isEmpty else { return true }

            if beside {
                onOpenLinkBeside?(target)
            } else {
                onOpenLink?(target)
            }
            return true
        }

        // MARK: - Plain click: footnote jump and tag filter

        /// Dispatches a plain (unmodified, single) click to whichever of the
        /// three navigation affordances owns the clicked offset, in the same
        /// fall-through spirit as `toggleTask` — `false` means "not mine",
        /// and the caret lands exactly where the user clicked.
        ///
        /// All three work in a READ-ONLY session: they navigate, they never
        /// write, so none of them consults `allowsTaskToggle` or any
        /// read-only gate the way `toggleTask` does.
        @MainActor func handlePlainClick(atUTF16 index: Int) -> Bool {
            if toggleTask(atUTF16: index) { return true }
            if jumpFootnote(atUTF16: index) { return true }
            // `selectTag` always returns `false` — see its doc comment
            // (Finding 7): it fires `onTagClick` as a side effect but never
            // claims the click, so the caret still lands where the user
            // clicked and `#tagg` stays editable.
            _ = selectTag(atUTF16: index)
            // `.blockID` is an anchor, not a control — deliberately no case
            // for it here. A click on one falls through to ordinary caret
            // placement, same as clicking any other plain text.
            return false
        }

        /// A click on a `[^label]` reference lands on its `[^label]:`
        /// definition; a click on the definition's own label lands back on
        /// the FIRST reference sharing that label. Located via
        /// `MarkdownNavigation.footnoteJumpTarget`, which filters
        /// `styleCache.spans` to the footnote KINDS before matching offsets —
        /// a plain `first(where: { $0.range.contains(index) })` over the
        /// whole array (AST spans first, extension spans last — see
        /// `MarkdownDocumentModel.styleSpans`) would return whatever
        /// CONTAINING span got there first: a list item, a blockquote, a
        /// callout — and never reach the footnote at all. See the M6 final
        /// review, Finding 1. A stale cache can only pick a stale
        /// destination, never an out-of-bounds one, since `scrollToOffset`
        /// clamps to `[0, length]`.
        @MainActor private func jumpFootnote(atUTF16 index: Int) -> Bool {
            guard let target = MarkdownNavigation.footnoteJumpTarget(
                in: styleCache.spans, at: index) else { return false }
            scrollToOffset(target)
            return true
        }

        /// A click on a `#tag` sets `activeTag` — the SAME filter
        /// `TagChipRow`/`NoteListView` share via `EditorContext.onTagClick` —
        /// so a tag clicked in the body does exactly what one clicked in the
        /// sidebar does. No new channel: this rides the existing binding all
        /// the way up through `DocumentPane`/`DocumentPaneColumn`.
        ///
        /// Located via `MarkdownNavigation.tagSpan`, which filters to `.tag`
        /// spans before matching offsets — see `jumpFootnote`'s comment for
        /// why a plain `first(where:)` over the whole span array cannot
        /// reach a tag nested in a list item or blockquote (Finding 1).
        ///
        /// ALWAYS returns `false`. The filter fires as a side effect, but the
        /// click itself is never swallowed: `toggleTask` deliberately
        /// preserves "the caret goes here", and a swallowed click on `#tagg`
        /// would make the typo the one span the user cannot click into to
        /// fix — see Finding 7. `jumpFootnote` above is the opposite case on
        /// purpose: it swallows, because a footnote click is about to scroll
        /// the caret elsewhere anyway.
        @MainActor private func selectTag(atUTF16 index: Int) -> Bool {
            guard let onTagClick, let hit = MarkdownNavigation.tagSpan(in: styleCache.spans, at: index),
                  let tv = textView,
                  // Finding 12: the cached span's associated `name` is a
                  // CANDIDATE, never an authority — re-derive it from the
                  // live text the way `toggleTask` re-reads `tv.string`
                  // rather than trusting `styleCache`, which may lag by up
                  // to one styling debounce.
                  let name = MarkdownNavigation.liveTagName(forSpan: hit.range, in: tv.string as NSString)
            else { return false }
            onTagClick(name)
            return false
        }

        // The styling pipeline — parse debounce, render, reveal, container
        // geometry — lives in `MarkdownEditorReveal.swift`. This file is the
        // AppKit wiring and nothing else; see its line-count note.
    }
}
