import AinkradAppKit
import SwiftUI
import WebKit

/// The CodeMirror editor surface.
///
/// ## Why this exists
///
/// See `2026-08-19-lore-obsidian-parity-architecture-design`. The native
/// renderer can style text and paint pictures over collapsed source; it cannot
/// put a caret inside a rendered element, which is what Obsidian's tables,
/// embeds and callouts all rest on. CodeMirror replaces a source range with
/// real content, so the caret has somewhere to go.
///
/// ## Who owns the document
///
/// **Swift does.** `text` is the source of truth; CM6 holds a copy and reports
/// what the user did to it. Two rules follow, and both are load-bearing:
///
/// 1. A change that came FROM Swift is never reported back to Swift (see
///    `applyingFromSwift` in `editor.js`). Otherwise the two push at each other
///    and drop keystrokes under a fast typist — silently, only under load.
/// 2. Swift never pushes text it has just been told about. `lastFromEditor`
///    is what makes an ordinary keystroke cost one message instead of two and
///    a caret reset.
///
/// Nothing here transforms the text. Not line endings, not normalisation,
/// nothing: this surface is a VIEW of the document, and a view that quietly
/// rewrites what it shows is how a vault gets corrupted one save at a time.
struct CM6EditorView: NSViewRepresentable {
    @Binding var text: String
    let tokens: HostThemeTokens
    let settings: EditorSettings
    /// Open a `[[wikilink]]`'s target. The SAME closure the native editor is
    /// given (`EditorContext.openLink`), because resolution is the shell's job
    /// and neither editor surface should have an opinion about it.
    var onOpenLink: (@MainActor (String) -> Void)?
    /// Cmd-click. Native behaviour, kept identical here.
    var onOpenLinkBeside: (@MainActor (String) -> Void)?
    /// A tag chip was clicked. The same `onTagClick` the sidebar's chip row
    /// uses, so a click in the body does exactly what a click in the sidebar
    /// does.
    var onTagClick: (@MainActor (String) -> Void)?
    /// A read-only session can never persist a toggle, so it must not offer
    /// one — `EditorContext.isReadOnly`, inverted, exactly as the native
    /// editor's `allowsTaskToggle`.
    var allowsTaskToggle: Bool = true
    /// Resolves an `![[target]]` to a file. The shell's own resolver, which is
    /// also the reason the page can never name a path of its own — see
    /// `CM6AssetSchemeHandler`.
    var resolveEmbedTarget: (@MainActor (String) -> URL?)?
    /// `[[` completion. The same closures the native editor is given: the vault
    /// knowledge stays in the shell, and this surface only draws the list.
    var completions: (@MainActor (String) -> [IndexRow])?
    var headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)?
    var tagCompletions: (@MainActor (String) -> [String])?
    var createLinkedNote: (@MainActor (String) -> Bool)?
    var linkTarget: (@MainActor (IndexRow) -> String)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            text: $text, onOpenLink: onOpenLink,
            onOpenLinkBeside: onOpenLinkBeside,
            onTagClick: onTagClick)
        coordinator.completions = completions
        coordinator.headingCompletions = headingCompletions
        coordinator.tagCompletions = tagCompletions
        coordinator.createLinkedNote = createLinkedNote
        coordinator.linkTarget = linkTarget
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        // Pooled, not created — see `CM6EditorSurfacePool`. A surface costs
        // ~40 MB, so switching notes must reuse one rather than open another.
        let (webView, isPreloaded) = CM6EditorSurfacePool.shared.acquire { config in
            config.userContentController.add(coordinator, name: Coordinator.bridgeName)
            // Once per configuration, and never again: registering a scheme
            // handler twice traps. The pool reuses configurations, so the
            // handler is installed here and its RESOLVER is replaced below on
            // every borrow.
            config.setURLSchemeHandler(
                CM6AssetSchemeHandler(),
                forURLScheme: CM6AssetSchemeHandler.scheme)
        }
        if isPreloaded {
            // A reused surface already has the handler of whoever had it last
            // removed by `release`, so this one has to be installed now.
            webView.configuration.userContentController.add(
                coordinator,
                name: Coordinator.bridgeName)
        }
        webView.navigationDelegate = coordinator
        // No bounce, no zoom: this is a text editor, not a web page.
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.webView = webView
        coordinator.pendingDocument = text
        coordinator.skin = context.environment.ainkradSkin
        coordinator.pendingTheme = (tokens, settings)
        coordinator.allowsTaskToggle = allowsTaskToggle
        coordinator.adopt(assetHandlerOf: webView, resolving: resolveEmbedTarget)

        if isPreloaded {
            // `didFinish` will NOT fire again for a page that is already
            // loaded, so the boot that normally happens there happens here.
            coordinator.adoptPreloadedSurface()
            return webView
        }
        guard let index = Coordinator.bundledIndexURL else {
            assertionFailure("Editor/dist is missing from the plugin bundle")
            return webView
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        return webView
    }

    /// Hand the surface back when the pane goes away, rather than letting a
    /// ~40 MB web view be deallocated and rebuilt for the next note.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.webView = nil
        // The next borrower installs its own; until then the surface resolves
        // nothing, rather than still serving this note's attachments.
        coordinator.adopt(assetHandlerOf: webView, resolving: nil)
        CM6EditorSurfacePool.shared.release(webView, handlerName: Coordinator.bridgeName)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowsTaskToggle = allowsTaskToggle
        context.coordinator.adopt(assetHandlerOf: webView, resolving: resolveEmbedTarget)
        context.coordinator.skin = context.environment.ainkradSkin
        context.coordinator.push(document: text)
        context.coordinator.push(tokens: tokens, settings: settings)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let bridgeName = "lore"

        /// `Editor/dist/index.html`, copied into the plugin's Resources by the
        /// build. `Bundle(for:)` rather than `.main`: `.main` is the HOST app,
        /// and this is a plugin bundle.
        static var bundledIndexURL: URL? {
            Bundle(for: Coordinator.self).url(forResource: "index", withExtension: "html")
        }

        private let text: Binding<String>
        private let onOpenLink: (@MainActor (String) -> Void)?
        private let onOpenLinkBeside: (@MainActor (String) -> Void)?
        private let onTagClick: (@MainActor (String) -> Void)?
        var webView: WKWebView?
        /// Set before the page has loaded; applied on `didFinish`.
        var pendingDocument: String?
        var pendingTheme: (HostThemeTokens, EditorSettings)?
        /// The environment's skin, kept in sync by `updateNSView` as the
        /// native editor's coordinator keeps its own.
        var skin: AinkradSkin = .standard
        /// What the page's variables were last set from; cleared on every
        /// load, since a fresh page has only its `:root` defaults.
        private var lastPushedTheme: (HostThemeTokens, EditorSettings, AinkradSkin)?
        private var isLoaded = false

        /// The last text the EDITOR told us about.
        ///
        /// Rule 2 above. Without it, every keystroke round-trips: CM6 reports,
        /// SwiftUI re-renders, `updateNSView` pushes the same string back, and
        /// the caret is reset mid-word.
        private var lastFromEditor: String?

        /// The line ending this document arrived with. CodeMirror normalises
        /// to LF and cannot be talked out of it, so the ending is recorded on
        /// the way in and restored on the way out — see `CM6LineEndings`.
        private var ending: CM6LineEndings.Ending = .lf

        init(
            text: Binding<String>,
            onOpenLink: (@MainActor (String) -> Void)? = nil,
            onOpenLinkBeside: (@MainActor (String) -> Void)? = nil,
            onTagClick: (@MainActor (String) -> Void)? = nil
        ) {
            self.text = text
            self.onOpenLink = onOpenLink
            self.onOpenLinkBeside = onOpenLinkBeside
            self.onTagClick = onTagClick
            super.init()
        }

        // MARK: - Swift to the editor

        func push(document: String) {
            guard isLoaded else {
                pendingDocument = document
                return
            }
            // Already came from there; pushing it back is the loop.
            if document == lastFromEditor { return }
            ending = CM6LineEndings.dominant(in: document)
            if !CM6LineEndings.isConsistent(document) {
                // Declared, not hidden: this note's bytes are about to change.
                let normalised = String(describing: ending)
                Log.editor.notice(
                    "Lore: mixed line endings normalised to \(normalised, privacy: .public) on open")
            }
            evaluate(
                "window.loreEditor.setDocument("
                    + Self.jsString(CM6LineEndings.toLF(document)) + ")")
        }

        /// Set by `updateNSView` before every theme push, so it is always the
        /// current value when the push happens.
        var allowsTaskToggle = true

        /// The shell's embed resolver, for `![[Note.md]]`. Set alongside the
        /// asset handler, from the same place and for the same reason.
        var resolveEmbedTarget: (@MainActor (String) -> URL?)?

        var completions: (@MainActor (String) -> [IndexRow])?
        var headingCompletions: (@MainActor (String, String) -> HeadingCompletions?)?
        var tagCompletions: (@MainActor (String) -> [String])?
        var createLinkedNote: (@MainActor (String) -> Bool)?
        var linkTarget: (@MainActor (IndexRow) -> String)?

        /// Answer the page's question "what is the caret completing?".
        ///
        /// Every decision here is `CM6Completion`'s, which is in turn the native
        /// editor's — see that file. This method only supplies the closures and
        /// hands the answer across.
        private func provideCompletions(caret: Int) {
            let text = text.wrappedValue
            let query = CM6Completion.query(
                text: CM6LineEndings.toLF(text), utf16Caret: caret,
                documents: { self.completions?($0) ?? [] },
                headings: { self.headingCompletions?($0, $1) },
                tags: { self.tagCompletions?($0) ?? [] },
                linkTarget: {
                    self.linkTarget?($0)
                        ?? LinkCompletionContext.insertableTarget(for: $0)
                },
                canCreate: createLinkedNote != nil)
            evaluate("window.loreEditor.showCompletions(\(CM6Completion.json(query)))")
        }

        /// Answer the page's `preview` request for a link's contents.
        ///
        /// The file read happens OFF the main actor: it is small, but it is disk
        /// I/O on a path triggered by pointer movement, and this codebase's
        /// standing rule is that the main actor does not wait on the filesystem.
        /// The same rule, and the same excerpt function, as
        /// `MarkdownEditorHover.presentPreview`.
        ///
        /// Staleness is the page's decision, not this one's: `showPreview`
        /// ignores an answer whose target is no longer under the pointer, which
        /// is where that fact actually lives.
        private func presentPreview(of target: String) {
            let name = LinkCompletionContext.documentName(of: target)
            guard let url = resolveEmbedTarget?(name) else { return }
            let title = url.deletingPathExtension().lastPathComponent
            Task { [weak self] in
                let excerpt = await Task.detached(priority: .userInitiated) {
                    guard let contents = try? String(contentsOf: url, encoding: .utf8)
                    else { return String?.none }
                    return LinkPreview.excerpt(from: contents)
                }.value
                guard let self, let excerpt else { return }
                self.evaluate(
                    "window.loreEditor.showPreview("
                        + Self.jsString(target) + ", "
                        + Self.jsString(title) + ", "
                        + Self.jsString(excerpt) + ")")
            }
        }

        /// A "create this note" row was accepted.
        ///
        /// The note is made FIRST and the text inserted only if that succeeded,
        /// so a refused create leaves the document untouched rather than writing
        /// a link to a note that was never made. Same order as the native
        /// `accept(_:)`.
        private func createAndComplete(name: String, from: Int, to: Int, insert: String) {
            guard createLinkedNote?(name) == true else { return }
            evaluate(
                "window.loreEditor.applyCompletion(\(from), \(to), "
                    + Self.jsString(insert) + ")")
        }

        /// Answer the page's request for a transcluded note.
        ///
        /// The slicing is `TransclusionResolver`'s, not this file's. That type
        /// already knows what `![[note#Heading]]` and `![[note#^block-id]]`
        /// mean, that a whole-note embed strips frontmatter, and what a cycle,
        /// an over-deep chain and an over-large file should say — and it is pure
        /// logic with no editor in it. A second slicer written in JavaScript
        /// would disagree with this one the first time either changed.
        private func provideTransclusion(of target: String) {
            let content = resolve(target)
            let (kind, text): (String, String) =
                switch content {
                case .content(let slice): ("content", slice)
                case .truncated(let slice): ("truncated", slice)
                case .missingFragment(_, let fragment):
                    ("missingFragment", "No section \"\(fragment)\" in this note.")
                case .circular: ("error", "This note embeds itself.")
                case .tooDeep: ("error", "Embedded too deeply.")
                case .unreadable(let message): ("error", message)
                }
            evaluate(
                "window.loreEditor.provideTransclusion("
                    + Self.jsString(target) + ", "
                    + Self.jsString(kind) + ", "
                    + Self.jsString(text) + ")")
        }

        private func resolve(_ target: String) -> TransclusionContent {
            guard let url = resolveEmbedTarget?(target) else {
                return .unreadable("Could not resolve \"\(target)\".")
            }
            // A single-document resolver over the file the shell already
            // picked: the resolution has HAPPENED, and re-deriving it from a
            // vault index here would be a second opinion about what this embed
            // points at. Same construction as `TransclusionStyling`.
            let resolver = LinkResolver(
                documents: [
                    (
                        url: url, title: LinkResolver.basename(of: target),
                        aliases: []
                    )
                ])
            return TransclusionResolver.resolve(
                rawTarget: target, resolver: resolver,
                path: []
            ) {
                try String(contentsOf: $0, encoding: .utf8)
            }
        }

        /// Point the surface's asset handler at this pane's resolver.
        ///
        /// Called on borrow, on every update and on release. A pooled surface's
        /// configuration outlives its borrower, so a handler left pointing at
        /// the previous note would serve that note's attachments to this one —
        /// the same failure mode, and the same fix, as removing the script
        /// message handler by name in `CM6EditorSurfacePool.release`.
        func adopt(
            assetHandlerOf webView: WKWebView,
            resolving resolve: (@MainActor (String) -> URL?)?
        ) {
            let handler = webView.configuration
                .urlSchemeHandler(forURLScheme: CM6AssetSchemeHandler.scheme)
            (handler as? CM6AssetSchemeHandler)?.resolve = resolve
            resolveEmbedTarget = resolve
        }

        func push(tokens: HostThemeTokens, settings: EditorSettings) {
            guard isLoaded else {
                pendingTheme = (tokens, settings)
                return
            }
            // Colour stays the host's, scale stays Lore's — see
            // `CM6ThemeBridge`. Pushed only when an input changed:
            // `updateNSView` runs on every keystroke, and the set is the
            // whole skin.
            if lastPushedTheme?.0 != tokens || lastPushedTheme?.1 != settings
                || lastPushedTheme?.2 != skin
            {
                lastPushedTheme = (tokens, settings, skin)
                let theme = MarkdownTheme(tokens: tokens, settings: settings, skin: skin)
                evaluate(
                    CM6ThemeBridge.pushScript(CM6ThemeBridge.cssVariables(skin: skin, theme: theme)))
            }
            // Not everything is a CSS variable. These two change what is
            // DECORATED, not how it looks, so they have to reach the editor as
            // state and force a redraw — a setting that only takes effect on
            // the next document opened is a setting that looks broken.
            evaluate("window.loreEditor.setTagsAsChips(\(settings.renderTagsAsChips))")
            evaluate("window.loreEditor.setTasksToggleable(\(allowsTaskToggle))")
        }

        private func evaluate(_ source: String) {
            webView?.evaluateJavaScript(source) { _, error in
                if let error {
                    Log.editor.error("CM6 bridge: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // MARK: - The editor to Swift

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                let kind = body["kind"] as? String
            else { return }
            switch kind {
            case "doc":
                guard let reported = body["text"] as? String else { return }
                // CM6 speaks LF; the document speaks whatever it arrived with.
                let incoming = CM6LineEndings.from(reported, to: ending)
                lastFromEditor = incoming
                // Only when it really differs: SwiftUI bindings are not free,
                // and an identical write still invalidates the view.
                if text.wrappedValue != incoming { text.wrappedValue = incoming }
            case "openLink":
                // The RAW target, exactly as written. Not resolved, not
                // decoded, not trimmed of its `#Heading` fragment — every one
                // of those is `LinkResolver`'s decision, and a second opinion
                // formed in JavaScript is how the editor and the link graph
                // come to disagree about what a link points at.
                guard let target = body["target"] as? String, !target.isEmpty else { return }
                if body["beside"] as? Bool == true, let beside = onOpenLinkBeside {
                    beside(target)
                } else {
                    onOpenLink?(target)
                }
            case "openTag":
                guard let tag = body["tag"] as? String, !tag.isEmpty else { return }
                onTagClick?(tag)
            case "completion":
                guard let caret = body["caret"] as? Int else { return }
                provideCompletions(caret: caret)
            case "completionCreate":
                guard let name = body["name"] as? String,
                    let from = body["from"] as? Int,
                    let to = body["to"] as? Int,
                    let insert = body["insert"] as? String
                else { return }
                createAndComplete(name: name, from: from, to: to, insert: insert)
            case "preview":
                guard let target = body["target"] as? String, !target.isEmpty else { return }
                presentPreview(of: target)
            case "transclude":
                guard let target = body["target"] as? String, !target.isEmpty else { return }
                provideTransclusion(of: target)
            default:
                return
            }
        }

        /// The boot path for a POOLED surface, whose page is already loaded and
        /// whose `didFinish` therefore never fires again.
        func adoptPreloadedSurface() {
            // Deliberately routed through the same code the fresh path uses,
            // so the two cannot drift: a reused surface that initialised
            // slightly differently from a new one is a bug that only appears
            // on the second note opened.
            finishLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishLoading()
        }

        private func finishLoading() {
            isLoaded = true
            lastPushedTheme = nil
            if let document = pendingDocument {
                ending = CM6LineEndings.dominant(in: document)
                evaluate(
                    "window.loreEditor.init("
                        + Self.jsString(CM6LineEndings.toLF(document)) + ")")
                pendingDocument = nil
            }
            if let (tokens, settings) = pendingTheme {
                push(tokens: tokens, settings: settings)
                pendingTheme = nil
            }
        }

        // MARK: - Encoding

        /// A JS string literal for `value`, via `JSONSerialization`.
        ///
        /// NOT hand-escaped. The document can hold quotes, backslashes,
        /// newlines, emoji, lone surrogates and U+2028, and every one of those
        /// is a way to end up injecting or truncating. This is the single place
        /// text crosses into JavaScript, so it is the single place that has to
        /// be right.
        ///
        /// `nonisolated` because it touches nothing but its argument, and the
        /// tests that pin the escaping have no business spinning up a main
        /// actor to check that a backslash comes out escaped.
        nonisolated static func jsString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                let array = String(data: data, encoding: .utf8)
            else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
    }
}
