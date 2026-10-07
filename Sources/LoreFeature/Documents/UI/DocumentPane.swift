import AinkradAppKit
import SwiftUI

/// Routes one session to its engine's editor, and owns the banners that are
/// shared by every document type: read-only, save failure, and conflict.
struct DocumentPane: View {
    @Bindable var store: LoreStore
    let session: DocumentSession
    let theme: HostTheme
    /// Rename / move / trash, owned by `LoreRootView` and shared with both
    /// sidebars — so the header's document menu drives the SAME confirmations
    /// and refusals the sidebar's context menu does.
    let ops: SidebarOperations
    /// Publishes this document's headings upward, so the ⌘⇧O palette can list
    /// them without re-parsing the document (`MarkdownEngine.outline` is a
    /// full AST parse, and this view already caches it).
    let onOutlineChange: ([OutlineEntry]) -> Void
    /// Publishes the editor's scroll handler upward, so a heading picked in
    /// the palette can jump. Same channel `OutlineSection` already uses, just
    /// forwarded one level further.
    let onScrollHandler: (((Int) -> Void)?) -> Void
    /// A `#tag` clicked in the editor. Forwarded straight to `LoreRootView`'s
    /// `activeTag`, the same binding `TagChipRow`/`NoteListView` already
    /// share — see `EditorContext.onTagClick`.
    let onTagClick: @MainActor (String) -> Void
    /// The raw target of a Cmd-clicked link that resolved to nothing. Non-nil
    /// only while the "create it?" prompt is up — clicking a dead link must
    /// never create a file silently.
    @State var unresolved: String?
    /// Why creating that note failed, when it did.
    @State var createFailure: String?
    /// Handed back by the markdown editor via `registerScrollHandler` — the
    /// only channel `OutlineSection` has to reach an editor it is a SIBLING
    /// of, not a parent of. `nil` until the editor has appeared once.
    @State var scrollHandler: ((Int) -> Void)?

    /// The current document's outline, cached rather than read off
    /// `MarkdownEngine.outline` inside `body` — `outline` is a full AST parse,
    /// and `body` re-evaluates on every unrelated redraw (a banner appearing,
    /// a theme change). Same reasoning `BacklinksPanel` already applies to
    /// `backlinks`/`unresolved`. `@State`, not `let`, because a reference type
    /// (`MainRunLoopDebouncer`) is fine to hold across redraws but this
    /// needs SwiftUI to redraw ON assignment.
    @State var outline: [OutlineEntry] = []
    /// Debounces the ONE trigger that can fire many times per second: typing.
    /// `onAppear` / `.onChange(of: session.url)` / `.onChange(of:
    /// session.reloadGeneration)` each fire at most once per real event and
    /// refresh immediately; a keystroke goes through this instead, exactly
    /// the way `MarkdownEditor.Coordinator.scheduleParse` debounces its own
    /// re-parse — an outline refresh is the same class of cost (a full
    /// `Document(parsing:)`) and firing it on every keystroke, on the main
    /// actor, inside a SwiftUI `body`, is the exact regression Task 6 spent a
    /// task removing from the styling path.
    @State var outlineDebouncer = MainRunLoopDebouncer()

    /// Cached the same way `outline` is, and for the same reason: the bottom
    /// bar's badge needs a count even while the slideover is shut, but
    /// `store.backlinks(to:)` hits SQLite — reading it straight from `body`
    /// would re-query on every unrelated redraw. Refreshed on exactly the
    /// triggers `BacklinksPanel` itself uses (`onAppear`, `onChange(of: url)`)
    /// plus `reloadGeneration`, matching `outline`'s triggers, so the badge
    /// never falls behind the panel's own count once it's opened.
    @State var backlinksCount: Int = 0
    /// The footer's data, cached exactly as `backlinksCount` is and refreshed
    /// on the same triggers — `backlinks(to:)`/`unresolvedLinks(from:)` hit
    /// SQLite, so they must never be read from `body`.
    @State var backlinks: [LoreStore.Backlink] = []
    @State var unresolvedLinks: [UnresolvedLink] = []
    @State var related: [IndexRow] = []
    @State var suggestedTags: [String] = []
    /// Whether the linked-mentions slideover is up.
    ///
    /// ON DEMAND, and closed by default. It began as a band below the document
    /// and that was wrong: on a short note — most of a vault — it landed
    /// directly under the title and competed with the writing area, which is
    /// the opposite of the "costs nothing while you write" it was meant to be.
    /// Reaching for it deliberately is the only presentation that holds for
    /// both a one-line note and a long one.
    @State private var showingMentions = false
    /// A request from the actions menu or ⌘⇧B, consumed here — the same
    /// one-shot shape the panel request used, and for the same reason: the
    /// state belongs to the pane, the trigger does not.
    @Binding var mentionsRequest: Bool
    /// Whether the ⋯ menu is open, and what it offers. Rendered here rather
    /// than in the header bar, which is too short to host a dropdown without
    /// clipping it.
    @Binding var showingActions: Bool
    let actionItems: [AinkradMenuItem]
    /// The caret's body-relative offset, reported by the editor, for the spine
    /// rail's active tick. `0` before the editor has appeared, which places
    /// the active heading at "none" rather than at a wrong one.
    @State var caretOffset: Int = 0
    /// Body length, for the rail's proportional placement.
    @State var documentLength: Int = 0

    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradToastCenter) private var toasts
    @Environment(\.ainkradSkin) private var skin

    /// The document stack and the modifiers that belong to it.
    ///
    /// `body` is split in two because the combined chain — the stack, six
    /// modifiers, three overlays, a confirm dialog and a change handler — exceeded
    /// what the type-checker will attempt in one expression. The split point
    /// is arbitrary; the need for one is not.
    @ViewBuilder private var pane: some View {
        VStack(spacing: 0) {
            if session.isReadOnly { readOnlyBanner }
            if session.conflict { conflictBanner }
            // A save error and a conflict are different situations with
            // different affordances, so they are different banners. Both can be
            // true at once only transiently; showing both is still honest.
            if let error = session.lastSaveError, !session.conflict { saveErrorBanner(error) }

            editor

        }
        .background(theme.tokens.background)
        // A banner appearing used to SNAP the editor down by its full height
        // mid-typing — the most jarring motion in the app, and it fired on the
        // save-failure path, i.e. exactly when the user was least in the mood
        // for a surprise. Animating the insertion keeps the text's movement
        // legible as "something arrived above you" rather than a jump cut.
        .animation(
            reduceMotion ? nil : AinkradMotion.materialize,
            value: bannerSignature
        )
        .onAppear {
            refreshOutline()
            refreshBacklinksCount()
        }
        // Same two triggers `BacklinksPanel` uses for the reasons it already
        // documents (a rename changes `url` without changing `session.id`),
        // plus `reloadGeneration`: "Reload from disk" replaces the engine's
        // note in place without either of those changing, and the outline
        // must not keep showing headings from the text that was just
        // discarded.
        .onChange(of: session.url) {
            refreshOutline()
            refreshBacklinksCount()
        }
        .onChange(of: session.reloadGeneration) {
            refreshOutline()
            refreshBacklinksCount()
        }
    }

    var body: some View {
        pane
            // The ⋯ menu, with a scrim catching the click-away. IN-WINDOW, not a
            // floating panel: a menu hung off a toolbar button has no reason to
            // live in another window, and the panel-based attempt dismissed on
            // click without running the item.
            .overlay(alignment: .topTrailing) {
                if showingActions {
                    ZStack(alignment: .topTrailing) {
                        skin.color(.palette("black", skin.opacity.hitTarget))
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showingActions = false }
                            .accessibilityHidden(true)
                        DocumentActionsMenu(items: actionItems, theme: theme) {
                            showingActions = false
                        }
                        .padding(.trailing, LoreMetrics.gutter)
                    }
                }
            }
            // Linked mentions, summoned from that menu or ⇧⌘B. Overlays the
            // editor rather than narrowing it, so the text column never reflows.
            .overlay(alignment: .topTrailing) {
                if showingMentions {
                    DocumentSlideover(
                        title: "Connections", theme: theme,
                        onClose: { showingMentions = false }
                    ) {
                        mentionsList
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
            .animation(reduceMotion ? nil : AinkradMotion.hover, value: showingMentions)
            // Esc closes whichever is up, claimed only while one is — the same
            // gating that keeps it from stealing `cancelOperation` from the
            // `[[`-completion popup.
            .overlay {
                if showingActions || showingMentions {
                    Button("Close") {  // design-lint: allow raw-control key-equivalent claim
                        showingActions = false
                        showingMentions = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: mentionsRequest) { _, requested in
                guard requested else { return }
                mentionsRequest = false
                showingMentions.toggle()
            }
            .loreConfirmDialog(
                unresolved.map { target in
                    LoreConfirmation.createNote(
                        named: target, store: store, onFailure: { createFailure = $0 },
                        dismiss: { unresolved = nil })
                }
            )
            // A TOAST, not the "Not done" sheet this used to raise.
            //
            // The sentences are unchanged and still shown — the point of the
            // original fix (a failed write that silently did nothing is worse than
            // no affordance) is intact. What changed is the weight: a refused
            // paste or drop leaves the document exactly as it was and asks nothing
            // of the user, so a modal that must be dismissed before typing can
            // continue is out of proportion to it. The sidebar's refused TRASH
            // keeps the sheet, because that one names a condition the user has to
            // resolve before the delete can happen at all.
            .onChange(of: createFailure) { _, failure in
                guard let failure else { return }
                createFailure = nil
                toasts.show(failure, status: .danger)
            }
    }

    /// Which banners are currently up, as a value `.animation(_:value:)` can
    /// compare.
    ///
    /// Deliberately NOT the whole session: animating on every session change
    /// would re-run the transition on each keystroke (`markChanged` mutates
    /// the session), which is both wasted work and visibly wrong. These three
    /// booleans are the only inputs the banner stack has.
    private var bannerSignature: [Bool] {
        [session.isReadOnly, session.conflict, session.lastSaveError != nil]
    }
}
