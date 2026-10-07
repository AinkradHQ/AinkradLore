import AinkradAppKit
import SwiftUI

/// Plain text and source files: no frontmatter, no structure, the file's bytes
/// are the document.
///
/// Deliberately the dumbest possible engine. Its job in M0 is to prove the
/// shell contains no markdown assumptions — if anything here needs a special
/// case in `VaultIndexCoordinator` or `DocumentSession`, the abstraction leaks.
final class PlainTextEngine: DocumentEngine {
    static let identifier = "plaintext"

    var text: String
    /// True when `load` could not decode the file's bytes as strict UTF-8 and
    /// fell back to a lossy decode (invalid sequences replaced with U+FFFD).
    /// A lossily-decoded document's in-memory `text` no longer matches the
    /// file's original bytes, so `save` refuses to write it — see `save(to:)`.
    private(set) var isLossilyDecoded: Bool
    private let sourceURL: URL

    private init(text: String, isLossilyDecoded: Bool, sourceURL: URL) {
        self.text = text
        self.isLossilyDecoded = isLossilyDecoded
        self.sourceURL = sourceURL
    }

    static let extensions: Set<String> = [
        "txt", "text", "log", "csv", "json", "yaml", "yml", "toml",
        "swift", "sh", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp",
    ]

    static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func load(_ url: URL) throws -> PlainTextEngine {
        // Not every file with a text extension is valid UTF-8. Falling back to
        // a lossy decode keeps a mis-encoded log openable and searchable rather
        // than making it an error state the user cannot act on. The fallback is
        // recorded in `isLossilyDecoded` so `save` can refuse to overwrite the
        // original bytes with a reconstruction it cannot represent faithfully.
        let data = try Data(contentsOf: url)
        if let strict = String(data: data, encoding: .utf8) {
            return PlainTextEngine(text: strict, isLossilyDecoded: false, sourceURL: url)
        }
        let lossy = String(decoding: data, as: UTF8.self)
        return PlainTextEngine(text: lossy, isLossilyDecoded: true, sourceURL: url)
    }

    func save(to url: URL) throws {
        // A lossily-decoded document's `text` cannot reproduce the file's
        // original bytes (invalid sequences were replaced with U+FFFD).
        // Writing it would silently destroy data the user never asked to
        // change, so we refuse rather than degrade further. The content stays
        // visible and searchable via `indexPayload` — only saving is blocked.
        guard !isLossilyDecoded else { throw EngineError.notRoundTrippable(url) }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The filename, so the protocol default's payload construction (which
    /// copies the whole file's text) is skipped — see `DocumentEngine.indexTitle`.
    var indexTitle: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    var indexPayload: IndexPayload {
        IndexPayload(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            plaintext: text)
    }

    /// A lossily-decoded document cannot reproduce the file's original bytes,
    /// so it is not editable — this is the same condition `save(to:)` guards,
    /// promoted to the property the session reads.
    var isEditable: Bool { !isLossilyDecoded }

    func replaceContents(with other: PlainTextEngine) {
        text = other.text
        isLossilyDecoded = other.isLossilyDecoded
    }

    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(PlainTextDocumentEditor(engine: self, ctx: ctx))
    }
}

@MainActor
private struct PlainTextDocumentEditor: View {
    let engine: PlainTextEngine
    let ctx: EditorContext
    @State private var text: String = ""

    var body: some View {
        MarkdownEditor(
            text: $text, tokens: ctx.theme.tokens,
            settings: ctx.editorSettings,
            headingCompletions: ctx.headingCompletions,
            createLinkedNote: ctx.createLinkedNote
        )
        .onChange(of: text) {
            engine.text = text
            ctx.onChange()
        }
        .onAppear { text = engine.text }
        .background(ctx.theme.tokens.background)
    }
}
