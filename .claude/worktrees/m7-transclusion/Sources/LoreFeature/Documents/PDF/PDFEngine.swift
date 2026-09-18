import SwiftUI
import PDFKit
import AinkradAppKit

/// PDFs: viewable and full-text searchable, never editable.
///
/// A corrupt or password-protected PDF is NOT a load error. The failure rule
/// for this milestone is that an unreadable document still indexes by filename
/// and still opens — so `load` always succeeds and records why the content is
/// missing in `loadFailure`, which the viewer renders. Throwing here would put
/// the file back in the dead-end state `AttachmentEngine` exists to abolish.
public final class PDFEngine: DocumentEngine {
    public static let identifier = "pdf"

    public private(set) var sourceURL: URL
    public private(set) var extractedText: String
    /// Human-readable reason the content could not be read, or nil.
    public private(set) var loadFailure: String?
    /// The `Title` from the PDF's document attributes, when it has a non-empty
    /// one. Many PDFs carry a generator's junk title, so the filename wins
    /// unless this is present AND non-blank.
    public private(set) var metadataTitle: String?
    /// Set in `load` by comparing the raw `document.string` length against the
    /// capped `extractedText` length — the original is discarded immediately
    /// after, so this is the only place that comparison can happen.
    public private(set) var isContentTruncated: Bool

    private init(sourceURL: URL, extractedText: String,
                 loadFailure: String?, metadataTitle: String?, isContentTruncated: Bool = false) {
        self.sourceURL = sourceURL
        self.extractedText = extractedText
        self.loadFailure = loadFailure
        self.metadataTitle = metadataTitle
        self.isContentTruncated = isContentTruncated
    }

    public static func canOpen(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public static func load(_ url: URL) throws -> PDFEngine {
        guard let document = PDFDocument(url: url) else {
            return PDFEngine(sourceURL: url, extractedText: "",
                             loadFailure: "This PDF could not be read. It may be damaged.",
                             metadataTitle: nil)
        }
        if document.isLocked {
            return PDFEngine(sourceURL: url, extractedText: "",
                             loadFailure: "This PDF is password-protected.",
                             metadataTitle: nil)
        }
        // `document.string` concatenates every page — the expensive walk this
        // cache exists to skip on an unchanged file. It is called ONLY inside
        // the cache's closure, which only runs on a miss: on a hit, PDFKit
        // never touches page content at all. Capped at the index limit here
        // rather than downstream so a 900-page scan never holds its whole
        // text resident during a vault rescan. The truncation flag is
        // computed alongside the text and cached with it (see
        // `ExtractionCache.ExtractionResult`) — the raw, uncapped text is
        // gone the moment this closure returns, so a cache HIT has nothing
        // else to compare against.
        let extraction = ExtractionCache.shared.result(for: url) {
            let raw = document.string ?? ""
            let text = VaultIndexCoordinator.capped(raw)
            return ExtractionCache.ExtractionResult(
                text: text, isTruncated: text.utf8.count < raw.utf8.count)
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PDFEngine(sourceURL: url, extractedText: extraction.text, loadFailure: nil,
                         metadataTitle: (title?.isEmpty == false) ? title : nil,
                         isContentTruncated: extraction.isTruncated)
    }

    public func save(to url: URL) throws {
        throw EngineError.readOnly(url)
    }

    public var isEditable: Bool { false }

    public func replaceContents(with other: PDFEngine) {
        sourceURL = other.sourceURL
        extractedText = other.extractedText
        loadFailure = other.loadFailure
        metadataTitle = other.metadataTitle
        isContentTruncated = other.isContentTruncated
    }

    public var indexTitle: String {
        metadataTitle ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    public var indexPayload: IndexPayload {
        IndexPayload(title: indexTitle, plaintext: extractedText)
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        if let loadFailure {
            return AnyView(DocumentErrorCard(url: sourceURL, message: loadFailure,
                                             theme: ctx.theme))
        }
        var view = AnyView(PDFViewer(url: sourceURL).background(ctx.theme.tokens.background))
        if isContentTruncated {
            view = AnyView(VStack(spacing: 0) {
                TruncationNotice(theme: ctx.theme)
                view
            })
        }
        return view
    }
}

@MainActor
private struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
