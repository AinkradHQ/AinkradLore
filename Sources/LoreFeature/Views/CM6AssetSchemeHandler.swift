import UniformTypeIdentifiers
import WebKit

/// Serves a note's attachments to the CodeMirror surface.
///
/// ## Why a custom scheme and not a file URL
///
/// The page is loaded from `Editor/dist` with read access to that directory
/// only, so an `<img src="file:///…/vault/note.png">` is refused. Widening the
/// read access to the vault would hand the whole vault to the page instead,
/// which is the wrong trade in the other direction.
///
/// So the page asks for `lore-asset:///<raw target>` and this resolves it — and
/// the resolution is the SHELL's, `EditorContext.resolveEmbedTarget`, the same
/// closure the native renderer uses. That is the security property worth
/// stating plainly: **JavaScript never names a path.** It names a raw embed
/// target exactly as the author wrote it, and if the shell does not resolve
/// that target to a file, nothing is served. A page that asked for
/// `lore-asset:///../../.ssh/id_rsa` gets a 404, because no vault target
/// resolves to it.
///
/// ## Why the resolver is swappable
///
/// A `WKURLSchemeHandler` can be registered on a configuration exactly once,
/// and `CM6EditorSurfacePool` reuses configurations across panes and notes.
/// A handler that captured one pane's resolver would serve the previous note's
/// attachments after the surface was handed on. So the handler is installed
/// once and its `resolve` is replaced by whoever currently owns the surface.
@MainActor
final class CM6AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "lore-asset"

    /// The current owner's `resolveEmbedTarget`. Nil means "nothing resolves",
    /// which is the correct answer for a pooled surface between borrowers.
    var resolve: (@MainActor (String) -> URL?)?

    /// The URL a page should ask for, for a raw embed target.
    ///
    /// `nonisolated`, like `Coordinator.jsString`: it touches nothing but its
    /// argument, and the tests that pin the encoding have no business spinning
    /// up a main actor to check that a space comes out as `%20`.
    ///
    /// The target is percent-encoded as a single path component: a target may
    /// contain spaces, `#`, `?` and `&`, and every one of those would otherwise
    /// truncate or re-route the request.
    nonisolated static func url(forTarget target: String) -> String {
        let encoded =
            target.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? ""
        return "\(scheme):///\(encoded)"
    }

    /// The raw target a request is asking for, undoing `url(forTarget:)`.
    nonisolated static func target(from url: URL) -> String? {
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        return String(path.dropFirst()).removingPercentEncoding
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
            let target = Self.target(from: url),
            !target.isEmpty,
            let file = resolve?(target),
            let data = try? Data(contentsOf: file)
        else {
            // A 404, not an error: an embed whose target does not resolve is an
            // ordinary state of a vault being edited, and failing the task
            // instead logs a WebKit error for every broken link in the note.
            guard
                let notFound = HTTPURLResponse(
                    url: task.request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: 404, httpVersion: nil,
                    headerFields: nil)
            else {
                task.didFailWithError(URLError(.badServerResponse))
                return
            }
            task.didReceive(notFound)
            task.didFinish()
            return
        }
        let response = URLResponse(
            url: url, mimeType: Self.mimeType(of: file),
            expectedContentLength: data.count,
            textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Everything is served synchronously from a local file, so there is
        // nothing in flight to cancel.
    }

    /// From the extension, via the type system rather than a hand-written
    /// table — a vault holds `.heic`, `.webp` and `.svg`, and a wrong MIME type
    /// means the image silently does not render.
    nonisolated static func mimeType(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
