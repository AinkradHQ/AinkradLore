import AinkradAppKit
import SwiftUI

extension DocumentPane {
    /// The engine's editor, plus the rail drawn over its margin.
    ///
    /// A separate property, not inline in `body`: `EditorContext` carries
    /// fourteen closures, and building it inside a `VStack` alongside the
    /// banners and the panel bar pushed the whole chain past what the
    /// type-checker will attempt in reasonable time. Splitting it is not
    /// cosmetic — without it the file does not compile.
    @ViewBuilder var editor: some View {
        session.engine.makeEditor(
            EditorContext(
                theme: theme,
                editorSettings: store.editorSettings,
                headingCompletions: { document, prefix in
                    store.headingCompletions(
                        inDocumentNamed: document,
                        matching: prefix)
                },
                createLinkedNote: { name in
                    // Creates WITHOUT opening: this fires
                    // mid-sentence, and navigating to the note
                    // just referenced is the opposite of what
                    // the writer asked for.
                    guard !session.isReadOnly else { return false }
                    do {
                        try store.createNote(
                            forLinkTarget: name,
                            syntax: .wikilink)
                        refreshBacklinksCount()
                        return true
                    } catch {
                        createFailure =
                            "Couldn't create “\(name)”: "
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
                openLinkBeside: { target in
                    // Same target-resolution rule `openLink`
                    // above follows, then `openInSecondaryPane`
                    // — the exact path `LoreRootView.openRow`
                    // already uses for an ⌥-clicked sidebar
                    // row, so an ⌥-click means the same thing
                    // everywhere in this app.
                    let name = LinkCompletionContext.documentName(of: target)
                    guard let url = store.resolveLink(name) else {
                        unresolved = name
                        return
                    }
                    store.openInSecondaryPane(url: url)
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
                    let result = attemptAttachmentWrite(
                        write: {
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
                    let result = attemptAttachmentWrite(
                        write: {
                            try store.writeAttachment(copying: url, besideNote: session.url)
                        }, embedSyntax: { store.embedSyntax(for: $0) })
                    if let failure = result.failureMessage {
                        createFailure = "Couldn't add \"\(url.lastPathComponent)\": \(failure)"
                    }
                    return result.embedSyntax
                },
                commitTitle: { newTitle in
                    store.commitTitleChange(for: session, to: newTitle)
                },
                registerExternalChangeHandler: { handler in
                    store.registerExternalChangeHandler(handler)
                },
                unregisterExternalChangeHandler: { token in
                    store.unregisterExternalChangeHandler(token)
                })
        )
        // The engines' editors seed their `@State` in `.onAppear` only,
        // and `resolveByReloading()` mutates the engine in place — so
        // without the generation in the identity the user clicks
        // "Reload" and the OLD text stays on screen. Changing the id
        // tears the editor down and builds a fresh one, which re-runs
        // `.onAppear` against the reloaded engine.
        .id("\(session.id)-\(session.reloadGeneration)")
        // The heading rail is NOT drawn — see `LoreSpineRail`, which
        // still holds the reasoning and the one line that restores it.
        // The owner read the ticks as marks at the edge of the panel
        // rather than as texture, and asked for them gone.
        //
        // `outline`, `documentLength` and `caretOffset` are kept: the
        // outline is published upward for the ⌘⇧O jump palette, which is
        // untouched and remains the way to move between headings.
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
    func refreshOutline() {
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
    func refreshBacklinksCount() {
        backlinks = store.backlinks(to: session.url)
        unresolvedLinks = store.unresolvedLinks(from: session.url)
        related = store.relatedNotes(to: session.url)
        suggestedTags = session.engine is MarkdownEngine ? store.suggestedTags(for: session.url) : []
        backlinksCount = backlinks.count
    }

    /// The linked-mentions list, shown in a slideover on request.
    var mentionsList: some View {
        DocumentMentionsList(
            backlinks: backlinks,
            unresolved: unresolvedLinks,
            related: related,
            suggestedTags: suggestedTags,
            theme: theme,
            onOpen: { store.open(url: $0) },
            onAddTag: { tag in
                do {
                    try store.addTag(tag, to: session.url)
                    refreshBacklinksCount()
                } catch {
                    createFailure = "Couldn't add #\(tag): " + error.localizedDescription
                }
            },
            onCreate: { link in
                do {
                    try store.createAndOpenNote(
                        forLinkTarget: link.rawTarget,
                        syntax: link.syntax)
                    // The target just created is no longer unresolved:
                    // re-querying is what keeps the list honest.
                    refreshBacklinksCount()
                } catch {
                    createFailure =
                        "Couldn't create “\(link.rawTarget)”: "
                        + error.localizedDescription
                }
            })
    }
}
