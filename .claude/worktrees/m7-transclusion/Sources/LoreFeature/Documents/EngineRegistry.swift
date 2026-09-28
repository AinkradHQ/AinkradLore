import Foundation

/// Ordered engine lookup. Order is significance order: the first engine whose
/// `canOpen` returns true wins. Within `specificEngines`, engines are required
/// to be mutually exclusive with one another, so order among THEM is a
/// tie-break that should never actually be needed — it exists so a bug there
/// produces deterministic behavior rather than a coin flip. `fallbackEngine`
/// is the opposite case: `AttachmentEngine` claims everything, so it being
/// consulted LAST is not a tie-break at all but the entire point — it is
/// where order genuinely matters.
public enum EngineRegistry {
    /// Engines that claim specific formats. Required to be mutually exclusive
    /// with one another — `EngineRegistryTests` enforces it.
    public static let specificEngines: [any DocumentEngine.Type] = [
        MarkdownEngine.self,
        PlainTextEngine.self,
        PDFEngine.self,
        RichTextEngine.self,
    ]

    /// Consulted ONLY when every specific engine declines. `AttachmentEngine`
    /// claims everything, so it must never be in `specificEngines` and must
    /// never be consulted first — both halves are asserted by test.
    public static let fallbackEngine: any DocumentEngine.Type = AttachmentEngine.self

    /// Every engine, fallback last. Kept for call sites that enumerate.
    public static var engines: [any DocumentEngine.Type] {
        specificEngines + [fallbackEngine]
    }

    /// Total: every file resolves to an engine. There is no longer an
    /// "unclaimed" outcome — that type is gone, and with it the class of bug
    /// where a vault full of PDFs looked like a vault full of dead rows.
    public static func engine(for url: URL) -> any DocumentEngine.Type {
        specificEngines.first { $0.canOpen(url) } ?? fallbackEngine
    }

    public static func load(_ url: URL) throws -> any DocumentEngine {
        try engine(for: url).load(url)
    }
}

public enum EngineError: Error, Equatable {
    case unsupported(URL)
    /// The in-memory document cannot reproduce the file's original bytes
    /// (e.g. a non-UTF-8 file was opened via a lossy decode), so writing it
    /// would destroy data rather than represent it. Thrown by `save` instead
    /// of overwriting the file.
    case notRoundTrippable(URL)
    /// The engine is a read-only citizen: it can load, index and display this
    /// document but will never write it. Distinct from `notRoundTrippable`,
    /// which means "editable format, but THIS file's bytes cannot be
    /// reproduced" — a condition the user can sometimes fix.
    case readOnly(URL)
}
