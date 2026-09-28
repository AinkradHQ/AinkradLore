import SwiftUI
import AppKit
import QuickLookUI
import AinkradAppKit

/// QuickLook preview of an arbitrary file.
///
/// `QLPreviewView` is the only renderer in the app that handles formats Lore
/// will never model itself — `.pages`, `.key`, `.numbers`, images, archives —
/// which is exactly what makes `AttachmentEngine` viable as a last resort.
@MainActor
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Reassigning an unchanged item restarts the preview and flickers.
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}

/// What a viewer shows when the document cannot be rendered at all.
///
/// The failure rule: never a crash, never a blank pane. The user gets the
/// filename, the reason, and the one action that always works.
@MainActor
struct DocumentErrorCard: View {
    let url: URL
    let message: String
    let theme: HostTheme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
            Text(url.lastPathComponent)
                .font(.headline)
                .foregroundStyle(theme.tokens.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
    }
}

/// Banner shown above the render-gated QuickLook fallback for a rich-text
/// document whose AppKit-extracted content was empty or whitespace-only —
/// see `RichTextEngine.makeEditor`'s `hasNoExtractableText` branch and
/// `EmptyExtractionFallbackView`. Distinct from `DocumentErrorCard`: this is
/// not a failure (the file DID open), so it stays a small notice rather than
/// replacing the whole pane.
///
/// Fix round 1, Minor 6: the wording must not assert that anything went
/// WRONG. `hasNoExtractableText` fires identically for a JS-built page AppKit
/// genuinely could not read AND for a document that is simply, legitimately
/// blank — this view cannot tell those apart, so it describes what it found
/// (no text) rather than accusing the file of being broken.
@MainActor
struct EmptyExtractionNotice: View {
    let theme: HostTheme

    var body: some View {
        Text("No text was extracted from this file.")
            .font(.caption)
            .foregroundStyle(theme.tokens.foreground.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.tokens.background.opacity(0.9))
    }
}

/// The render gate an empty-extraction rich-text document's "Render this
/// page" button flips.
///
/// One instance per document OPEN — see `EmptyExtractionFallbackView`, the
/// sole owner of a `RenderGate`, for how that lifetime is actually achieved
/// (fix round 2, Important 8: constructing this and handing it in from the
/// OUTSIDE, as fix round 1 did, is NOT enough — a fresh instance built by a
/// caller whose `body` re-evaluates for unrelated reasons — an outline
/// refresh, a banner, a theme change, see `DocumentPane.outline`'s doc
/// comment for that exact list — silently replaces it, snapping an
/// already-pressed render back to closed). Nothing shares one gate across
/// documents or across two opens of the same document, which is what makes
/// pressing render in one tab unable to silently opt in any other: there is
/// no persisted or global "trust this file" state anywhere, only this one
/// object's lifetime.
@MainActor
final class RenderGate: ObservableObject {
    @Published private(set) var isRendered = false
    func render() { isRendered = true }
}

/// What replaces a blank pane for a rich-text document with no extractable
/// text (`RichTextEngine.hasNoExtractableText`) — WITHOUT auto-instantiating
/// `QLPreviewView` on open.
///
/// THE HAZARD THIS GATES: QuickLook's HTML preview is WebKit, and WebKit
/// executes the page's JavaScript and can fetch remote subresources it
/// references. That is exactly the capability that lets it render a
/// scripted single-page app where the plain-text importer returned nothing —
/// and exactly why it must never run merely because the owner opened a note.
/// A vault `.html` file is, from Lore's point of view, untrusted content:
/// opening it must not itself execute arbitrary script or make network
/// calls the owner did not separately ask for. So this view shows only the
/// notice and a button until the owner explicitly presses it — nothing
/// executes on open, only on that explicit action — and `gate.isRendered`
/// is the only thing that ever flips it to the live `QuickLookView`.
///
/// `@StateObject`, NOT `@ObservedObject` (fix round 2, Important 8): the
/// gate is constructed HERE, once, and SwiftUI preserves a `@StateObject`
/// across every `body` re-evaluation of the SAME view identity — which is
/// exactly "per document open", since `DocumentPane` gives the editor a
/// stable `.id("\(session.id)-\(session.reloadGeneration)")` that only
/// changes when the document itself changes. `RichTextEngine.makeEditor`
/// constructing a fresh `EmptyExtractionFallbackView` value on every call is
/// harmless BECAUSE of this — `@StateObject` looks at the view's IDENTITY in
/// the hierarchy, not whether the struct literal was freshly initialized,
/// and only creates a new `RenderGate` the first time that identity
/// appears. A NEW identity (a genuinely different document, or the SAME
/// document reloaded via `reloadGeneration`) still starts closed, because
/// it is a new identity SwiftUI has never seen before.
@MainActor
struct EmptyExtractionFallbackView: View {
    let url: URL
    let theme: HostTheme
    @StateObject private var gate = RenderGate()
    /// Test-only hook: called with the LIVE `gate` on every `body`
    /// evaluation, so a test can capture its identity across re-renders and
    /// assert it never changes — see `EmptyExtractionFallbackViewTests`.
    /// `nil` in production; has no effect on what is drawn.
    var onGateAvailable: ((RenderGate) -> Void)?

    /// Only HTML/HTM actually routes through WebKit — `QLPreviewView`'s
    /// previewer for `.rtf`/`.rtfd`/`.docx`/`.odt` is a document-format
    /// renderer, not a browser engine, and runs no script and makes no
    /// network call. Fix round 2, Minor 9: the risk warning below must say
    /// so only where it is actually true, or it wrongly accuses a blank
    /// Word document of a hazard that applies only to HTML.
    private var previewExecutesScript: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    var body: some View {
        onGateAvailable?(gate)
        return Group {
            if gate.isRendered {
                QuickLookView(url: url).background(theme.tokens.background)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                    EmptyExtractionNotice(theme: theme)
                    Button("Render this page") { gate.render() }
                        .buttonStyle(.borderedProminent)
                    if previewExecutesScript {
                        // Said plainly, at the point of the action that
                        // carries the risk — not buried in a doc comment
                        // nobody using the app will ever read.
                        Text("This runs the file's own code and may contact the network.")
                            .font(.caption2)
                            .foregroundStyle(theme.tokens.foreground.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.tokens.background)
            }
        }
    }
}

/// One-line banner shown above a read-only viewer whose engine capped its own
/// extraction (`DocumentEngine.isContentTruncated`) — e.g. `PDFEngine` and
/// `RichTextEngine`, which cap before `indexPayload` even runs and so cannot
/// rely on `VaultIndexCoordinator.scanVault`'s generic before/after check.
/// Without this, a search that finds nothing past the cut is indistinguishable
/// from the phrase genuinely being absent from the document.
@MainActor
struct TruncationNotice: View {
    let theme: HostTheme

    var body: some View {
        Text("Only the first part of this document is searchable.")
            .font(.caption)
            .foregroundStyle(theme.tokens.foreground.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.tokens.background.opacity(0.9))
    }
}
