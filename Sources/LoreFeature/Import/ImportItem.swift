import Foundation

enum ImportBody: Sendable, Equatable {
    case html(String)
    case markdown(String)
}

struct ImportAttachment: Sendable, Equatable {
    let sourceID: String
    let preferredName: String
    /// Where the bytes live right now. Nil when the source could not produce them,
    /// in which case the item carries a `.attachmentUnavailable` warning instead.
    let sourceURL: URL?
    init(sourceID: String, preferredName: String, sourceURL: URL?) {
        self.sourceID = sourceID
        self.preferredName = preferredName
        self.sourceURL = sourceURL
    }
}

struct FidelityWarning: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case unsupportedElement  // converter met markup it does not model
        case attachmentUnavailable  // referenced media could not be read
        case lockedNote  // encrypted; skipped by design
        case pluginSyntax  // Dataview/callout copied through verbatim
    }
    let kind: Kind
    let detail: String
    init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// What an item IS, as declared by the source that produced it.
///
/// This exists because the applier previously inferred it from the item's
/// SHAPE — "empty body plus at least one attachment means this is really just
/// a file" — which is true for Obsidian, where a markdown item always has
/// `attachments: []` and a binary always has exactly itself. It is false for
/// Apple Notes, where a note that is just a photo with a title is completely
/// ordinary: that note would have matched the shape test and been imported as
/// a bare image, losing its title, its dates and its fidelity warnings.
///
/// A source knows which of the two it is emitting. Asking it is not a
/// refinement of the guess; it is the thing the guess was approximating.
enum ImportItemKind: Sendable, Equatable {
    /// A document. Always written as a note file, even when its body is empty
    /// — an empty note the user wrote is still their note, and a note whose
    /// body could not be read needs somewhere to carry the warning saying so.
    case note
    /// A file that IS the item, with no note of its own. Every non-`.md` file
    /// in an Obsidian vault. Writing a note for one of these produces a junk
    /// `pic.png.md` beside the real `pic.png` for every binary in the vault.
    case file
}

struct ImportItem: Sendable, Equatable {
    let sourceID: String
    let title: String
    let body: ImportBody
    let attachments: [ImportAttachment]
    let folderPath: [String]
    let created: Date
    let modified: Date
    let fidelity: [FidelityWarning]
    let kind: ImportItemKind

    /// `kind` defaults to `.note`, which is the safe default in the precise
    /// sense that matters here: a `.note` misdeclared always produces a FILE
    /// TOO MANY (a junk note beside the real bytes), which is visible and
    /// recoverable, while a `.file` misdeclared produces data LOST (title,
    /// dates and warnings with nowhere to live). Given a source that forgets
    /// to say, err toward the recoverable failure.
    init(
        sourceID: String, title: String, body: ImportBody,
        attachments: [ImportAttachment], folderPath: [String],
        created: Date, modified: Date, fidelity: [FidelityWarning],
        kind: ImportItemKind = .note
    ) {
        self.sourceID = sourceID
        self.title = title
        self.body = body
        self.attachments = attachments
        self.folderPath = folderPath
        self.created = created
        self.modified = modified
        self.fidelity = fidelity
        self.kind = kind
    }
}
