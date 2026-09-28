import SwiftUI
import AinkradAppKit

/// The result of attempting a paste/drop attachment write: embed syntax to
/// insert on success, or a human-readable failure message to surface, never
/// both and never neither.
struct AttachmentWriteResult {
    let embedSyntax: String?
    let failureMessage: String?
}

/// Attempts an attachment write and turns the outcome into
/// `AttachmentWriteResult`, with NO SwiftUI dependency — this is the seam
/// `AttachmentWriteTests` exercises directly.
///
/// Exists because whole-branch review round 2 fixed `DocumentPane`'s
/// `try? … else { return nil }` (which silently dropped `LoreError
/// .notARegularFile` — a dropped Finder folder did nothing with no
/// explanation) by inlining a `do`/`catch` straight into the view's body.
/// That fix was correct but UNTESTABLE where it lived: nothing outside a
/// running SwiftUI host could prove the catch block still runs, still calls
/// `SidebarOperations.describeAttachmentWrite`, and still returns `nil`
/// rather than partial embed syntax — so a future edit reverting the
/// `do`/`catch` back to a `try?` would compile clean and break silently
/// again. Pulling the logic out here — pure, synchronous, no `@State` — is
/// what lets a test call it directly and assert on `failureMessage` without
/// standing up a view host.
@MainActor
func attemptAttachmentWrite(
    write: () throws -> URL, embedSyntax: (URL) -> String
) -> AttachmentWriteResult {
    do {
        let written = try write()
        return AttachmentWriteResult(embedSyntax: embedSyntax(written), failureMessage: nil)
    } catch {
        return AttachmentWriteResult(embedSyntax: nil,
                                     failureMessage: SidebarOperations.describeAttachmentWrite(error))
    }
}

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
    @State private var unresolved: String?
    /// Why creating that note failed, when it did.
    @State private var createFailure: String?
    /// Handed back by the markdown editor via `registerScrollHandler` — the
    /// only channel `OutlineSection` has to reach an editor it is a SIBLING
    /// of, not a parent of. `nil` until the editor has appeared once.
    @State private var scrollHandler: ((Int) -> Void)?

    /// The current document's outline, cached rather than read off
    /// `MarkdownEngine.outline` inside `body` — `outline` is a full AST parse,
    /// and `body` re-evaluates on every unrelated redraw (a banner appearing,
    /// a theme change). Same reasoning `BacklinksPanel` already applies to
    /// `backlinks`/`unresolved`. `@State`, not `let`, because a reference type
    /// (`OutlineRefreshDebouncer`) is fine to hold across redraws but this
    /// needs SwiftUI to redraw ON assignment.
    @State private var outline: [OutlineEntry] = []
    /// Debounces the ONE trigger that can fire many times per second: typing.
    /// `onAppear` / `.onChange(of: session.url)` / `.onChange(of:
    /// session.reloadGeneration)` each fire at most once per real event and
    /// refresh immediately; a keystroke goes through this instead, exactly
    /// the way `MarkdownEditor.Coordinator.scheduleParse` debounces its own
    /// re-parse — an outline refresh is the same class of cost (a full
    /// `Document(parsing:)`) and firing it on every keystroke, on the main
    /// actor, inside a SwiftUI `body`, is the exact regression Task 6 spent a
    /// task removing from the styling path.
    @State private var outlineDebouncer = OutlineRefreshDebouncer()

    /// Cached the same way `outline` is, and for the same reason: the bottom
    /// bar's badge needs a count even while the slideover is shut, but
    /// `store.backlinks(to:)` hits SQLite — reading it straight from `body`
    /// would re-query on every unrelated redraw. Refreshed on exactly the
    /// triggers `BacklinksPanel` itself uses (`onAppear`, `onChange(of: url)`)
    /// plus `reloadGeneration`, matching `outline`'s triggers, so the badge
    /// never falls behind the panel's own count once it's opened.
    @State private var backlinksCount: Int = 0
    /// The footer's data, cached exactly as `backlinksCount` is and refreshed
    /// on the same triggers — `backlinks(to:)`/`unresolvedLinks(from:)` hit
    /// SQLite, so they must never be read from `body`.
    @State private var backlinks: [LoreStore.Backlink] = []
    @State private var unresolvedLinks: [UnresolvedLink] = []
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
    @State private var caretOffset: Int = 0
    /// Body length, for the rail's proportional placement.
    @State private var documentLength: Int = 0

    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradToastCenter) private var toasts

    /// The document stack and the modifiers that belong to it.
    ///
    /// `body` is split in two because the combined chain — the stack, six
    /// modifiers, three overlays, an alert and a change handler — exceeded
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
        .animation(reduceMotion ? nil : AinkradMotion.materialize,
                   value: bannerSignature)
        .onAppear { refreshOutline(); refreshBacklinksCount() }
        // Same two triggers `BacklinksPanel` uses for the reasons it already
        // documents (a rename changes `url` without changing `session.id`),
        // plus `reloadGeneration`: "Reload from disk" replaces the engine's
        // note in place without either of those changing, and the outline
        // must not keep showing headings from the text that was just
        // discarded.
        .onChange(of: session.url) { refreshOutline(); refreshBacklinksCount() }
        .onChange(of: session.reloadGeneration) { refreshOutline(); refreshBacklinksCount() }
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
                    Color.black.opacity(0.001)
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
                DocumentSlideover(title: "Linked mentions", theme: theme,
                                  onClose: { showingMentions = false }) {
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
                Button("Close") {
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
        .alert("Create this note?",
               isPresented: Binding(get: { unresolved != nil },
                                    set: { if !$0 { unresolved = nil } })) {
            Button("Cancel", role: .cancel) { unresolved = nil }
            Button("Create") {
                if let target = unresolved { createUnresolved(target) }
                unresolved = nil
            }
        } message: {
            Text("\"\(unresolved ?? "")\" doesn't exist in this vault yet.")
        }
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


    /// The engine's editor, plus the rail drawn over its margin.
    ///
    /// A separate property, not inline in `body`: `EditorContext` carries
    /// fourteen closures, and building it inside a `VStack` alongside the
    /// banners and the panel bar pushed the whole chain past what the
    /// type-checker will attempt in reasonable time. Splitting it is not
    /// cosmetic — without it the file does not compile.
    @ViewBuilder private var editor: some View {
            session.engine.makeEditor(
                EditorContext(theme: theme,
                              editorSettings: store.editorSettings,
                              headingCompletions: { document, prefix in
                                  store.headingCompletions(inDocumentNamed: document,
                                                           matching: prefix)
                              },
                              createLinkedNote: { name in
                                  // Creates WITHOUT opening: this fires
                                  // mid-sentence, and navigating to the note
                                  // just referenced is the opposite of what
                                  // the writer asked for.
                                  guard !session.isReadOnly else { return false }
                                  do {
                                      try store.createNote(forLinkTarget: name,
                                                           syntax: .wikilink)
                                      refreshBacklinksCount()
                                      return true
                                  } catch {
                                      createFailure = "Couldn't create “\(name)”: "
                                          + error.localizedDescription
                                      return false
                                  }
                              },
                              reportCaretOffset: { caretOffset = $0 },
                              onChange: {
                                  session.markChanged()
                                  // Debounced — see `outlineDebouncer`'s doc
                                  // comment. `refreshOutline` is cheap to call
                                  // repeatedly; the debouncer just makes sure
                                  // only the LAST call in a typing burst runs.
                                  outlineDebouncer.schedule(after: 0.3) { refreshOutline() }
                              },
                              completions: { store.linkCompletions(matching: $0) },
                              // Prefix-matched in Swift over `allTags` —
                              // already in memory, deduplicated and sorted,
                              // and (since inline `#tags` feed the same
                              // pipeline) already including inline tags. No
                              // new query, no SQL.
                              tagCompletions: { prefix in
                                  guard !prefix.isEmpty else { return store.allTags }
                                  let needle = prefix.lowercased()
                                  return store.allTags.filter {
                                      $0.lowercased().hasPrefix(needle)
                                  }
                              },
                              openLink: { target in
                                  // `documentName` first: `openLink` funnels into
                                  // `LinkResolver.basename`, which strips a
                                  // `#fragment` but NOT an `|alias`, so
                                  // `[[Design|why]]` would look up "Design|why"
                                  // and never resolve.
                                  let name = LinkCompletionContext.documentName(of: target)
                                  if !store.openLink(name) { unresolved = name }
                              },
                              onTagClick: onTagClick,
                              resolveEmbedTarget: { store.resolveLink($0) },
                              linkTarget: { store.linkTarget(for: $0) },
                              registerScrollHandler: { handler in
                                  scrollHandler = handler
                                  onScrollHandler(handler)
                              },
                              isReadOnly: session.isReadOnly,
                              // Beside `session.url`, never in a vault-wide
                              // folder — see `LoreStore.writeAttachment`'s doc
                              // comment. A failed write (no vault, permission
                              // denied, outside-vault guard, or — since the
                              // directory-drop guard — a Finder folder) means
                              // "insert nothing" into the document, same as
                              // before, but is no longer swallowed silently:
                              // it now surfaces through `createFailure`, the
                              // same "Not done" sheet an unresolved-link
                              // create failure already uses below, so a
                              // refused drop is visible rather than a drop
                              // that just does nothing with no explanation.
                              // Gated on `session.isReadOnly` FIRST — same
                              // reasoning as `allowsTaskToggle: !ctx.isReadOnly`
                              // below: a read-only session's `saveNow()`
                              // refuses to write, so letting these two
                              // closures write a real file into the vault and
                              // insert an embed `saveNow()` will then never
                              // persist is exactly the affordance
                              // `EditorContext.isReadOnly` exists to withhold
                              // — read-only stays a silent no-op, not an
                              // error, since it is not a failure but the
                              // expected behavior of a read-only tab.
                              writePastedImage: { data, name in
                                  guard !session.isReadOnly else { return nil }
                                  let result = attemptAttachmentWrite(write: {
                                      try store.writeAttachment(
                                          data: data, preferredName: name, besideNote: session.url)
                                  }, embedSyntax: { store.embedSyntax(for: $0) })
                                  if let failure = result.failureMessage {
                                      createFailure = "Couldn't paste that image: \(failure)"
                                  }
                                  return result.embedSyntax
                              },
                              writeDroppedFile: { url in
                                  guard !session.isReadOnly else { return nil }
                                  let result = attemptAttachmentWrite(write: {
                                      try store.writeAttachment(copying: url, besideNote: session.url)
                                  }, embedSyntax: { store.embedSyntax(for: $0) })
                                  if let failure = result.failureMessage {
                                      createFailure = "Couldn't add \"\(url.lastPathComponent)\": \(failure)"
                                  }
                                  return result.embedSyntax
                              },
                              commitTitle: { newTitle in
                                  store.commitTitleChange(for: session, to: newTitle)
                              }))
                // The engines' editors seed their `@State` in `.onAppear` only,
                // and `resolveByReloading()` mutates the engine in place — so
                // without the generation in the identity the user clicks
                // "Reload" and the OLD text stays on screen. Changing the id
                // tears the editor down and builds a fresh one, which re-runs
                // `.onAppear` against the reloaded engine.
                .id("\(session.id)-\(session.reloadGeneration)")
                // Drawn in the margin the editor's own measure already leaves
                // empty, so it costs the text column nothing — see
                // `LoreSpineRail`. An overlay rather than an HStack sibling for
                // the same reason: a rail that took layout width would narrow
                // the measure every time a document happened to have headings.
                .overlay(alignment: .topLeading) { spineRail }
    }

    /// The heading rail. A separate property, not inline in `body`: the editor
    /// expression it decorates is already large enough that adding this made
    /// the type-checker give up on the whole chain.
    @ViewBuilder private var spineRail: some View {
        LoreSpineRail(outline: outline,
                      documentLength: documentLength,
                      caretOffset: caretOffset,
                      theme: theme,
                      onSelect: { offset in scrollHandler?(offset) })
            .padding(.leading, AinkradSpacing.xs)
            .padding(.vertical, AinkradSpacing.md)
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

    /// Re-derives `outline` from the engine's own `outline` accessor — a
    /// heading-only parse, NOT `indexPayload` (which also runs a link scan
    /// this view has no use for). `nil` for a non-markdown engine, same as
    /// the gating above.
    ///
    /// Staleness between refreshes: a click that lands mid-debounce scrolls
    /// to an offset computed from the text as it was UP TO 0.3s ago. Purely
    /// additive edits above the clicked heading shift where it visually sits
    /// without changing the offset math (headings below an edit still start
    /// where they started, relative to the edit's own position) — the only
    /// case that can go visibly wrong is the debounce window closing between
    /// an edit that changes a HEADING'S OWN text and a click on the OLD
    /// label the user is still looking at. `MarkdownEditor.Coordinator.
    /// scrollToOffset` clamps to `[0, length]`, so a stale offset can select
    /// the wrong place; it can never crash or select out of bounds.
    private func refreshOutline() {
        outline = (session.engine as? MarkdownEngine)?.outline ?? []
        // Read from the same engine and on the same triggers as the outline,
        // so the rail's proportional placement can never be computed against a
        // length from a different revision of the text.
        documentLength = (session.engine as? MarkdownEngine)?.note.body.utf16.count ?? 0
        onOutlineChange(outline)
    }

    /// The same accessor `BacklinksPanel` itself uses to count referrers
    /// (`LoreStore.backlinks(to:)`) — cached here rather than queried a
    /// second time from a separate path, so the bottom bar's badge and the
    /// panel's own count can never disagree.
    private func refreshBacklinksCount() {
        backlinks = store.backlinks(to: session.url)
        unresolvedLinks = store.unresolvedLinks(from: session.url)
        backlinksCount = backlinks.count
    }

    /// The linked-mentions list, shown in a slideover on request.
    private var mentionsList: some View {
        DocumentMentionsList(
                backlinks: backlinks,
                unresolved: unresolvedLinks,
                theme: theme,
                onOpen: { store.open(url: $0) },
            onCreate: { link in
                do {
                    try store.createAndOpenNote(forLinkTarget: link.rawTarget,
                                                syntax: link.syntax)
                    // The target just created is no longer unresolved:
                    // re-querying is what keeps the list honest.
                    refreshBacklinksCount()
                } catch {
                    createFailure = "Couldn't create “\(link.rawTarget)”: "
                        + error.localizedDescription
                }
            })
    }

    /// Creates the note this dead link names, via the store's single
    /// create-from-a-link path — see `LoreStore.createAndOpenNote(forLinkTarget:)`,
    /// which owns the alias/fragment stripping and the folder split. The view's
    /// only job is to show a failure instead of swallowing it.
    ///
    /// `.wikilink` is not a guess: this alert is reachable only from
    /// `MarkdownEditor.Coordinator.openLink(atUTF16:)`, whose target comes from
    /// `LinkCompletionContext.target(in:at:)` — a scanner that recognises `[[`
    /// and `]]` and nothing else. A markdown link is not clickable here, so no
    /// percent-decoding applies.
    private func createUnresolved(_ target: String) {
        do {
            try store.createAndOpenNote(forLinkTarget: target, syntax: .wikilink)
        } catch {
            createFailure = "Couldn't create \"\(target)\": \(error.localizedDescription)"
        }
    }

}

/// Coalesces a burst of `ctx.onChange` calls (one per keystroke) into a
/// single refresh, exactly the shape `MarkdownEditor.Coordinator.
/// scheduleParse` already uses for the same reason: only the LAST call in a
/// burst should do the expensive work.
///
/// A class, not a struct, so `DocumentPane`'s `@State` can hold the SAME
/// instance — and therefore the same in-flight `Timer` — across every body
/// re-evaluation between keystrokes; a struct copy would lose the pending
/// timer on every redraw and never coalesce anything.
@MainActor
final class OutlineRefreshDebouncer {
    private var timer: Timer?

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer = t
        // `.common`, matching `Coordinator.scheduleParse`: the refresh must
        // still land while the user is scrolling or holding a menu open.
        RunLoop.main.add(t, forMode: .common)
    }
}
