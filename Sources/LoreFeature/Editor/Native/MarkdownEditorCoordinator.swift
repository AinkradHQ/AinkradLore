import AinkradAppKit
import AppKit
import SwiftUI

extension MarkdownEditor {
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
        /// The link currently wearing the hover underline, so the next pointer
        /// move can take it off again. Held rather than re-derived: the
        /// underline is a TEMPORARY attribute and nothing else records where
        /// it was put.
        var hoveredLinkRange: NSRange?
        /// Guards the one re-render a stale table box schedules, so a render
        /// cannot queue another from its own tail. See
        /// `remeasureTablesIfTheyWereMeasuredAtAnotherWidth`.
        var isRemeasuringTables = false
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
        /// The environment's skin, kept in sync by `updateNSView` exactly as
        /// `settings` is. `.standard` until the first update reads it.
        var skin: AinkradSkin = .standard

        /// The scale and the faces the current `tokens`, `settings` and `skin`
        /// imply.
        ///
        /// CACHED against both, rather than constructed per access. It was
        /// constructed per access — `MarkdownTheme(tokens:settings:)` inline at
        /// half a dozen call sites — which was free while the type held only
        /// numbers. It no longer does: building one resolves two fonts and
        /// measures a space advance (see `MarkdownTheme.spaceAdvance`), and the
        /// render and decoration paths below ask for the theme several times
        /// per pass.
        ///
        /// Self-invalidating by comparison rather than by a `didSet` on each
        /// input: both are `Equatable`, `updateNSView` assigns them freely, and
        /// a cache that has to be manually poisoned is a cache that eventually
        /// is not.
        private var themeCache:
            (
                tokens: HostThemeTokens,
                settings: EditorSettings,
                skin: AinkradSkin,
                theme: MarkdownTheme
            )?

        var theme: MarkdownTheme {
            if let cached = themeCache,
                cached.tokens == tokens, cached.settings == settings, cached.skin == skin
            {
                return cached.theme
            }
            let built = MarkdownTheme(tokens: tokens, settings: settings, skin: skin)
            themeCache = (tokens, settings, skin, built)
            return built
        }
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
        var linkTarget: @MainActor (IndexRow) -> String = { LinkCompletionContext.insertableTarget(for: $0) }
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

        init(
            text: Binding<String>, tokens: HostThemeTokens,
            settings: EditorSettings = .default
        ) {
            self.text = text
            self.tokens = tokens
            self.settings = settings
            super.init()
            completionPanel.onPick = { [weak self] item in self?.accept(item) }
        }

        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

        func observeScrolling(of clipView: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView,
                queue: .main
            ) { [weak self] _ in
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
                completionPanel.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completionPanel.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertTab(_:)):
                completionPanel.pickSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                completionPanel.hide()
                return true
            default:
                return false
            }
        }

        // MARK: - Completion

        // The styling pipeline — parse debounce, render, reveal, container
        // geometry — lives in `MarkdownEditorReveal.swift`. This file is the
        // AppKit wiring and nothing else; see its line-count note.
    }
}
