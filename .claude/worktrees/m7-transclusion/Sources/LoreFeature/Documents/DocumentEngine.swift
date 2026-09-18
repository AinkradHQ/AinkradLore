import SwiftUI

/// One document type: how to detect it, load it, save it, index it, and edit it.
///
/// Class-bound so a loaded document is a reference the session mutates in place
/// and the editor view binds to.
public protocol DocumentEngine: AnyObject {
    /// Stable identifier, stored in the index's `type` column.
    static var identifier: String { get }

    /// True when this engine claims `url`. Must be mutually exclusive with
    /// every other registered engine — `EngineConformanceTests` enforces it.
    static func canOpen(_ url: URL) -> Bool

    static func load(_ url: URL) throws -> Self

    func save(to url: URL) throws

    var indexPayload: IndexPayload { get }

    /// Just the title, without building the rest of the payload.
    ///
    /// `DocumentSession` caches the title and refreshes it on load, save,
    /// reload and copy-adoption — four places that only ever wanted one
    /// `String`. Routing them through `indexPayload` made each one pay for a
    /// full markdown parse (outline) plus a link scan, and `save()` paid it a
    /// SECOND time immediately afterwards inside `indexDocument`. On the main
    /// actor, 500 ms after the user stops typing.
    ///
    /// Defaulted to `indexPayload.title` so no engine is forced to implement
    /// it; an engine whose title is cheap (both of them, as it happens)
    /// overrides and the parse disappears.
    var indexTitle: String { get }

    /// False for read-only citizens (PDF, rich text, attachments). The session
    /// gates autosave on this: a read-only document is never marked dirty, so a
    /// keystroke cannot become one failed write per typing pause.
    ///
    /// Defaulted to true so the two editable engines are untouched.
    var isEditable: Bool { get }

    /// True when this engine's OWN extraction already cut the document's text
    /// short, before `indexPayload` is even called — e.g. `PDFEngine` caps
    /// `document.string` inside `load`, and `RichTextEngine` caps inside
    /// `indexPayload` itself. A generic before/after comparison around
    /// `indexPayload` (what `VaultIndexCoordinator.scanVault` does for engines
    /// that DON'T pre-cap) cannot see either case: the string it receives is
    /// already capped, so the two lengths match and truncation would be
    /// reported as false. Engines that cap early must say so themselves here.
    ///
    /// Defaulted to false so engines that never cap (Markdown, plain text,
    /// attachments) are untouched.
    var isContentTruncated: Bool { get }

    /// Adopt `other`'s contents in place.
    ///
    /// `DocumentSession.engine` is `let`, so a reload copies fresh contents into
    /// the engine the session already owns rather than swapping the object.
    /// Implemented per engine because only the engine knows its document model;
    /// this requirement replaces the shell-side type switch that M0 left behind.
    func replaceContents(with other: Self)

    @MainActor func makeEditor(_ ctx: EditorContext) -> AnyView
}

public extension DocumentEngine {
    var indexTitle: String { indexPayload.title }
    var isEditable: Bool { true }
    var isContentTruncated: Bool { false }
}
