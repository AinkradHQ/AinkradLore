import Foundation

/// Every user-facing sentence `SidebarOperations` produces for a failed or
/// refused operation, in one file.
///
/// Split out of `SidebarOperations.swift` purely for the 500-line ceiling —
/// these are the same `static` members on the same type, and they stay
/// together because they share one rule: EVERY case of `LoreError` is spelled
/// out in every switch, including the ones a given operation cannot raise.
/// That is deliberate and load-bearing. A `default` arm would silently absorb
/// a newly added error and ship it to the user as whichever generic sentence
/// happened to be nearest; an exhaustive switch breaks the build instead, and
/// makes someone write a true sentence for it. Several of the sentences in
/// here exist only because that break happened.
extension SidebarOperations {

    /// `describeCreate` phrases everything as a failed document create, so
    /// folder creation gets its own sentences — the errors that can actually
    /// reach it (`invalidName`, `alreadyExists`, `outsideVault`) barely
    /// overlap with the document-create ones anyway.
    static func describeCreateFolder(_ error: LoreError) -> String {
        switch error {
        case .invalidName(let name):
            return "“\(name)” is not a valid folder name. "
                + "Folder names cannot be empty, cannot contain “/” or “:”, cannot start "
                + "with “.”, and cannot contain control characters."
        case .alreadyExists(let url):
            return "A folder named “\(url.lastPathComponent)” already exists here."
        case .outsideVault(let url):
            return "“\(url.lastPathComponent)” is outside the vault, so nothing was created."
        case .noVault:
            return "No vault is open, so there is nowhere to put a new folder."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The folder could not be created: \(reason)"
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was created."
        case .notARegularFile:
            // Not reachable from `createFolder` — raised only by
            // `writeAttachment(copying:besideNote:)` — kept for the same
            // reason the other unreachable cases are kept.
            return "The folder could not be created."
        case .restoreBlocked, .restoreFailed:
            // Not reachable from `createFolder` — raised only by `undoTrash()`
            // — kept for the same reason as `notARegularFile` above.
            return "The folder could not be created."
        }
    }

    /// `describe(_:row:)` phrases everything as a failed DELETE and needs a row
    /// that does not exist yet, so create gets its own sentences.
    static func describeCreate(_ error: LoreError) -> String {
        switch error {
        case .noVault:
            return "No vault is open, so there is nowhere to put a new document. "
                + "Choose a vault folder first."
        case .outsideVault(let url):
            return "A new document would have been written outside the vault "
                + "(“\(url.lastPathComponent)”), so nothing was created."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The document could not be created: \(reason)"
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was created."
        case .invalidName, .alreadyExists:
            // Not reachable from a document create — those errors are raised
            // only by `createFolder` — but the switch is exhaustive on
            // purpose, so this says something true rather than nothing.
            return "The document could not be created."
        case .notARegularFile:
            // Not reachable from a document create — raised only by
            // `writeAttachment(copying:besideNote:)` — kept for the same
            // reason as `invalidName`/`alreadyExists` above.
            return "The document could not be created."
        case .restoreBlocked, .restoreFailed:
            // Not reachable from a document create — raised only by
            // `undoTrash()` — kept for the same reason as the cases above.
            return "The document could not be created."
        }
    }

    /// The user-facing sentence for a failed paste-image or drop-file
    /// attachment write (`LoreStore.writeAttachment`'s two overloads).
    ///
    /// Whole-branch review round 3, Important 3: `DocumentPane` used to
    /// format these with bare `error.localizedDescription`. That reads fine
    /// for a genuine `NSError` (`Data.write` on the paste path throws a real
    /// `CocoaError` with a real message), but `LoreError` — thrown by both
    /// overloads' own guards — is a plain `Error, Equatable` with no
    /// `LocalizedError` conformance, so the SAME formatting produced
    /// `"The operation couldn't be completed. (LoreFeature.LoreError error
    /// 8.)"` for exactly the case this wave's directory-drop guard exists to
    /// explain. `LoreError` cases get the same hand-written treatment
    /// `describeCreate`/`describeCreateFolder` already give the errors THEY
    /// see; anything else (a `CocoaError` from the underlying write, a
    /// filesystem error from `copyItem`) falls back to its own
    /// `localizedDescription`, which is reliable for those types.
    static func describeAttachmentWrite(_ error: Error) -> String {
        guard let loreError = error as? LoreError else {
            return error.localizedDescription
        }
        switch loreError {
        case .notARegularFile(let url):
            return "“\(url.lastPathComponent)” is a folder, not a file, so it "
                + "was not added. Only individual files can be attached."
        case .outsideVault(let url):
            return "“\(url.lastPathComponent)” would have been written outside "
                + "the vault, so nothing was added."
        case .noVault:
            return "No vault is open, so there is nowhere to put the attachment."
        case .externalChange(let url):
            return "“\(url.lastPathComponent)” changed outside Lore, so nothing was added."
        case .trashFailed(_, let reason), .unsavedEdits(_, let reason):
            return "The attachment could not be added: \(reason)"
        case .invalidName, .alreadyExists, .restoreBlocked, .restoreFailed:
            // Not reachable from an attachment write — raised only by
            // `createFolder` and `undoTrash()` — kept for the same reason the
            // other "not reachable" arms in this file are kept.
            return "The attachment could not be added."
        }
    }

    static func describe(_ error: LoreError, folder: URL) -> String {
        let name = folder.lastPathComponent
        switch error {
        case .trashFailed(_, let reason):
            return "“\(name)” could not be moved to the Trash: \(reason) "
                + "Nothing was deleted — Lore never falls back to deleting it permanently."
        case .noVault:
            return "No vault is open, so nothing was deleted."
        // Reachable: `applyTrashFolder` refuses per-session, before touching
        // anything, when a tab under the folder is dirty and its flush fails
        // — same rule and same reason as single-document `LoreStore.trash`.
        case .unsavedEdits(_, let reason):
            return "“\(name)” was not deleted because \(reason)"
        // Reachable: `applyTrashFolder`'s own containment guard throws this
        // for the vault root itself or a target outside the vault, in case a
        // stale or forged plan reaches here without going through
        // `planTrashFolder`'s own refusal.
        case .outsideVault:
            return "“\(name)” was not deleted: it is the vault's own folder, or outside "
                + "the vault entirely."
        case .externalChange, .invalidName, .alreadyExists, .notARegularFile,
             .restoreBlocked, .restoreFailed:
            // Not reachable from `applyTrashFolder` — kept for the same reason
            // the single-document `describe(_:row:)` keeps its own unreachable
            // cases: a true sentence rather than a silent gap in the switch.
            return "“\(name)” was not deleted."
        }
    }

    static func describe(_ error: LoreError, row: IndexRow) -> String {
        let name = row.path.lastPathComponent
        switch error {
        case .unsavedEdits(_, let reason):
            // `reason` already names the unsaved edits AND the way out
            // (reload, overwrite, or save a copy) — see `LoreStore.trash`.
            return "“\(name)” was not deleted because \(reason)"
        case .trashFailed(_, let reason):
            return "“\(name)” could not be moved to the Trash: \(reason) "
                + "Nothing was deleted — Lore never falls back to deleting it permanently."
        case .noVault:
            return "No vault is open, so nothing was deleted."
        case .externalChange:
            return "“\(name)” changed outside Lore, so nothing was deleted. "
                + "Resolve it in the open tab, then delete it again."
        case .outsideVault(let url):
            // Not reachable from a delete — `outsideVault` is raised only by
            // `create` — but the switch is exhaustive on purpose, so this says
            // something true rather than nothing.
            return "“\(url.lastPathComponent)” is outside the vault, so nothing was deleted."
        case .invalidName, .alreadyExists, .notARegularFile:
            // Not reachable from a document delete either — raised only by
            // `createFolder` / `writeAttachment(copying:besideNote:)` — kept
            // for the same reason as `outsideVault` above.
            return "“\(name)” was not deleted."
        case .restoreBlocked, .restoreFailed:
            // Raised by `undoTrash()`, which is the REVERSE of this operation
            // and has its own sentences — see `describeRestore`. A delete that
            // failed never armed an undo, so this pairing cannot occur.
            return "“\(name)” was not deleted."
        }
    }

    /// Separate from `describe(_:row:)` because it describes the opposite
    /// operation: those sentences all end in "nothing was deleted", which is
    /// the wrong reassurance entirely when the user was trying to put a file
    /// BACK. Pure, so it is asserted directly.
    static func describeRestore(_ error: LoreError) -> String {
        switch error {
        case .restoreBlocked(let url):
            return "“\(url.lastPathComponent)” wasn't restored: a file with that name "
                + "exists again, and Lore won't overwrite it to recover the old one. "
                + "The deleted file is still in the Trash."
        case .restoreFailed(let url, let reason):
            return "“\(url.lastPathComponent)” couldn't be restored from the Trash: "
                + "\(reason)"
        case .noVault:
            return "No vault is open, so there is nowhere to restore it to."
        // Every other case belongs to an operation `undoTrash()` never
        // performs. Spelled out rather than defaulted, so a new error still
        // breaks this switch and gets a sentence written for it.
        case .externalChange, .trashFailed, .unsavedEdits, .outsideVault,
             .invalidName, .alreadyExists, .notARegularFile:
            return "The file couldn't be restored."
        }
    }}
