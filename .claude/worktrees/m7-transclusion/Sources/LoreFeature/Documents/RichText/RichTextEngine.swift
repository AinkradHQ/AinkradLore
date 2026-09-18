import SwiftUI
import AppKit
import AinkradAppKit

/// Word processor and markup formats, read-only.
///
/// AppKit reads `.docx`, `.rtf`, `.rtfd`, `.odt` and HTML natively through
/// `NSAttributedString(url:options:documentAttributes:)`. That is the entire
/// reason this engine can exist without adding a third-party parser to the
/// dependency graph — and why fidelity is "good enough to read", which is all a
/// read-only citizen owes. Editing these formats is explicitly out of scope;
/// converting them to markdown is M4's job, not this engine's.
public final class RichTextEngine: DocumentEngine {
    public static let identifier = "richtext"

    public static let extensions: Set<String> = ["docx", "rtf", "rtfd", "odt", "html", "htm"]

    public private(set) var sourceURL: URL
    public private(set) var attributed: NSAttributedString
    public private(set) var loadFailure: String?

    private init(sourceURL: URL, attributed: NSAttributedString, loadFailure: String?) {
        self.sourceURL = sourceURL
        self.attributed = attributed
        self.loadFailure = loadFailure
    }

    public static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Never throws, for the same reason `PDFEngine.load` never throws: an
    /// unreadable document must still index by filename and still open.
    ///
    /// AppKit's readers are notoriously permissive: garbage bytes named
    /// `.docx` do not always throw. Instead the reader can silently fall
    /// through to a bare plain-text interpretation and hand back the raw
    /// bytes as "content" (e.g. control characters `NUL SOH STX ETX`) — that
    /// is invented text, exactly what the failure rule forbids. We guard
    /// against it by inspecting the reader's own `documentType` in
    /// `documentAttributes`: for any structured extension (everything except
    /// HTML, which legitimately degrades to plain text for real HTML
    /// fragments) a `.plain` result means the reader never actually
    /// recognized the format — that is treated as a load failure, not a
    /// successful parse.
    ///
    /// This `.plain` guard is NOT what catches a JavaScript-built HTML page
    /// (a React/Vue SPA whose `<body>` is empty and whose content is built
    /// at runtime by its `<script>` tags): the HTML importer never runs
    /// script, so it happily reports `documentType == .html` — a technically
    /// correct, successful parse of an empty document. That case succeeds
    /// HERE and is caught downstream instead, in `makeEditor`'s
    /// `hasNoExtractableText` check: a load that "succeeds" with next to no
    /// extracted text must still not render as a silently blank pane.
    public static func load(_ url: URL) throws -> RichTextEngine {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        var attributes: NSDictionary?
        do {
            let attributed = try NSAttributedString(
                url: url, options: options, documentAttributes: &attributes)
            let ext = url.pathExtension.lowercased()
            let isHTML = ext == "html" || ext == "htm"
            let documentType = attributes?[NSAttributedString.DocumentAttributeKey.documentType]
                as? NSAttributedString.DocumentType
            if !isHTML, documentType == .plain {
                return RichTextEngine(
                    sourceURL: url, attributed: NSAttributedString(string: ""),
                    loadFailure: "Lore couldn't read this \(url.pathExtension.uppercased()) file.")
            }
            return RichTextEngine(sourceURL: url, attributed: attributed, loadFailure: nil)
        } catch {
            return RichTextEngine(
                sourceURL: url, attributed: NSAttributedString(string: ""),
                loadFailure: "Lore couldn't read this \(url.pathExtension.uppercased()) file.")
        }
    }

    public func save(to url: URL) throws {
        throw EngineError.readOnly(url)
    }

    public var isEditable: Bool { false }

    public func replaceContents(with other: RichTextEngine) {
        sourceURL = other.sourceURL
        attributed = other.attributed
        loadFailure = other.loadFailure
    }

    public var indexTitle: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: indexTitle, plaintext: cachedExtraction().text)
    }

    /// Computed rather than stored, and routed through the SAME cache entry
    /// as `indexPayload` (via `cachedExtraction()`) rather than independently
    /// re-deriving it from `attributed.string`. Two independent computations
    /// of "is this truncated" from the same underlying text can never
    /// disagree in principle, but they COULD disagree in practice if one
    /// route hit the cache and the other read `attributed` fresh after
    /// `replaceContents` swapped it — sharing one lookup makes that
    /// impossible by construction, not just unlikely.
    public var isContentTruncated: Bool {
        cachedExtraction().isTruncated
    }

    /// `attributed.string` is already resident (it backs the viewer), so the
    /// extraction this caches is cheap on its own — unlike `PDFEngine`, this
    /// does not skip AppKit's document parse (that already ran, unconditionally,
    /// in `load`). What it DOES buy: `indexPayload` is read at least twice per
    /// save (`scanVault` and `indexDocument`) and `isContentTruncated` is read
    /// again by the editor, and each of those used to re-walk and re-cap
    /// `attributed.string` from scratch. Caching means only the first of those
    /// calls, for a given file version, pays for the walk.
    ///
    /// Keyed by the FILE's `(path, mtime, size)`, not by this instance — so a
    /// `replaceContents(with:)` swap (only ever called after an external edit
    /// changed the file on disk, i.e. after its mtime/size already changed)
    /// naturally misses the old entry and re-extracts from the new
    /// `attributed`, rather than serving stale text under the old key.
    private func cachedExtraction() -> ExtractionCache.ExtractionResult {
        ExtractionCache.shared.result(for: sourceURL) {
            let raw = attributed.string
            let text = VaultIndexCoordinator.capped(raw)
            return ExtractionCache.ExtractionResult(
                text: text, isTruncated: text.utf8.count < raw.utf8.count)
        }
    }

    /// True when AppKit's reader "succeeded" — no `loadFailure`, a
    /// recognized `documentType` — but the text it actually extracted is
    /// empty or whitespace-only. The concrete case this exists for: a React/
    /// Vue single-page app saved as `.html`, whose `<body>` is empty and
    /// whose content is built at runtime by seven `<script>` tags. AppKit's HTML
    /// importer does not run JavaScript, so `attributed` ends up with next
    /// to nothing in it, `load`'s `.plain`-documentType guard never fires
    /// (HTML is explicitly exempt from it, and rightly so — the format WAS
    /// recognized), and without this check `makeEditor` would hand back a
    /// working-but-empty `NSTextView`: no error card, no message, a blank
    /// pane indistinguishable from a genuinely blank document. An
    /// image-only scan saved as `.rtf`/`.docx` (no OCR layer, so no text
    /// runs at all) hits the identical branch for the identical reason.
    ///
    /// Checked directly on `attributed.string`, not through
    /// `cachedExtraction()`: the cache exists to avoid re-walking a
    /// PLAUSIBLY-large string, and this only ever needs to know whether that
    /// string is essentially empty, which is cheap to ask of the string
    /// itself and does not need to share the cache's truncation bookkeeping.
    var hasNoExtractableText: Bool {
        attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        if let loadFailure {
            return AnyView(DocumentErrorCard(url: sourceURL, message: loadFailure,
                                             theme: ctx.theme))
        }
        if hasNoExtractableText {
            // NOT auto-rendered: `AttachmentEngine` already wraps
            // `QLPreviewView` for a format Lore does not model itself, and
            // that same fallback is what makes a JS-built SPA (or a scanned
            // image) viewable here where the plain-text importer returned
            // nothing. But QuickLook's HTML preview is WebKit, and WebKit
            // EXECUTES the page's JavaScript and can fetch remote
            // subresources it references — that is a hazard, not a
            // convenience: a vault `.html` file is untrusted content, and
            // merely opening the note must not run its script or make
            // network calls the owner did not ask for. `EmptyExtractionFallbackView`
            // is the gate — it shows only the notice and a "Render this
            // page" button until the owner explicitly presses it, one fresh
            // `RenderGate` per open, so nothing executes on open and
            // pressing render in one tab can never opt in any other
            // document. The document is still opened and still indexed
            // regardless (`indexPayload` above already reports EMPTY
            // plaintext for this case — never invented text, so full-text
            // search cannot match content nobody parsed) — only the
            // PREVIEW is gated behind the owner's explicit action.
            return AnyView(EmptyExtractionFallbackView(url: sourceURL, theme: ctx.theme))
        }
        var view = AnyView(RichTextViewer(attributed: attributed)
            .background(ctx.theme.tokens.background))
        if isContentTruncated {
            view = AnyView(VStack(spacing: 0) {
                TruncationNotice(theme: ctx.theme)
                view
            })
        }
        return view
    }
}

/// Read-only `NSTextView`. Not editable: the document's own attributes are
/// shown as authored, because reformatting someone's Word file to match
/// Lore's theme would misrepresent it.
@MainActor
private struct RichTextViewer: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(attributed)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributed.string {
            textView.textStorage?.setAttributedString(attributed)
        }
    }
}
