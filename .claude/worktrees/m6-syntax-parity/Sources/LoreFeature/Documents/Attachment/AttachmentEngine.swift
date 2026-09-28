import SwiftUI
import AinkradAppKit

/// The last resort: any file no specific engine claims.
///
/// Its existence is what makes engine resolution TOTAL. Before it, a `.pdf` or
/// an `.xlsx` was an "unclaimed" row — indexed but unopenable, unlinkable, a
/// dead end in a vault meant to hold every document the owner has. Now every
/// file is a document: previewable through QuickLook, resolvable as a link
/// target, and movable with its links rewritten.
///
/// It indexes METADATA ONLY — filename and size, never content. An engine that
/// can read a format's text should be a specific engine instead; anything that
/// lands here is, by definition, a format nothing in Lore understands, and
/// inventing plaintext for it would make full-text search lie.
public final class AttachmentEngine: DocumentEngine {
    public static let identifier = "attachment"

    public private(set) var sourceURL: URL
    public private(set) var byteSize: Int

    private init(sourceURL: URL, byteSize: Int) {
        self.sourceURL = sourceURL
        self.byteSize = byteSize
    }

    /// Deliberately total. `EngineRegistry` guarantees this engine is consulted
    /// ONLY after every specific engine has declined, so claiming everything
    /// here cannot shadow them — see `EngineRegistry.engine(for:)`.
    public static func canOpen(_ url: URL) -> Bool { true }

    public static func load(_ url: URL) throws -> AttachmentEngine {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return AttachmentEngine(sourceURL: url, byteSize: size)
    }

    public func save(to url: URL) throws {
        throw EngineError.readOnly(url)
    }

    public var isEditable: Bool { false }

    public func replaceContents(with other: AttachmentEngine) {
        sourceURL = other.sourceURL
        byteSize = other.byteSize
    }

    /// The filename WITH its extension: there is no engine to derive anything
    /// better, and stripping `.pdf` from `Contract.pdf` would make two
    /// unrelated files in one folder show as the same title.
    public var indexTitle: String { sourceURL.lastPathComponent }

    public var indexPayload: IndexPayload {
        IndexPayload(title: sourceURL.lastPathComponent, plaintext: "")
    }

    @MainActor public func makeEditor(_ ctx: EditorContext) -> AnyView {
        AnyView(QuickLookView(url: sourceURL).background(ctx.theme.tokens.background))
    }
}
