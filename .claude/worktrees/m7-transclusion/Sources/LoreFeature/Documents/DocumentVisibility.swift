import Foundation

/// Whether a row is shown in the BROWSE list (sidebar) by default.
///
/// This is a PRESENTATION filter only — it decides what a browse list draws,
/// never what the index contains, what a link resolves to, or what rename
/// rewrites. That split looks like it contradicts `AttachmentEngine`'s own
/// premise ("a vault full of `.xlsx` must not make the file list lie about
/// what's there" / engine resolution being TOTAL) but it does not: totality
/// is about every file being INDEXED and OPENABLE, not about every file
/// being listed in a folder browser. The owner's actual complaint was a
/// `.zip` and a Google OAuth credentials file cluttering the sidebar next to
/// his notes — not that Lore failed to resolve them. Hiding them from the
/// browse list while keeping them fully indexed, linkable, embeddable and
/// rename-safe (`[[Budget.xlsx]]` still resolves, renaming it still rewrites
/// links, opening it via a link or a search hit still works) satisfies both:
/// the sidebar stops lying about being "notes", and the index keeps its
/// promise of never lying about what is on disk.
///
/// Rule (revised in fix round 1, after the owner reviewed round 0's
/// engine-identity-only version): "documents stay, code/config/junk goes."
/// Round 0 hid everything `AttachmentEngine` claims and nothing else — which
/// missed the owner's own named example. His `client_secret_….json`
/// credentials file has extension `.json`, and `.json` is one of
/// `PlainTextEngine.extensions`, so it resolves to `PlainTextEngine`, never
/// `AttachmentEngine` — engine identity alone left it sitting in the sidebar
/// exactly as before. Extension checks are therefore unavoidable for the one
/// engine (`PlainTextEngine`) that spans both prose and code/config, and for
/// distinguishing which `AttachmentEngine` formats are still "documents"
/// (Office/iWork) from the ones that are not (archives, binaries). That is
/// `nonProseTextExtensions` and `documentAttachmentExtensions` below: two
/// small, NAMED, documented, owner-approved curations — not a scattered set
/// of ad hoc extension checks, and each is anchored to a specific engine's
/// own extension set rather than invented independently.
public enum DocumentVisibility {
    /// Owner ruling (fix round 1): "documents stay, code/config/junk goes."
    /// This is a DELIBERATE, curated list of `PlainTextEngine` extensions
    /// that are developer-ish text rather than prose — a `.json` credentials
    /// file or a `.log`/`.sh`/`.csv` is exactly the kind of "junk in the
    /// sidebar" the owner complained about, but `PlainTextEngine` (not
    /// `AttachmentEngine`) is what claims it, so filtering on engine
    /// identity ALONE (this file's original approach) missed it entirely —
    /// that was Critical 1 in fix round 1's review. Kept as exactly
    /// `PlainTextEngine.extensions` minus its two prose extensions
    /// (`txt`, `text`), which stay visible. MUST be revisited by hand if
    /// `PlainTextEngine.extensions` changes — nothing ties the two
    /// automatically, since the whole point is that not every plaintext
    /// extension belongs in this set (a future prose-ish addition to
    /// `PlainTextEngine` should stay visible, not get silently swept in).
    /// `DocumentVisibilityTests.test_nonProseTextExtensions_isASubsetOfPlainTextEngineExtensions`
    /// pins the "subset of" half of that relationship so a typo here fails
    /// loudly instead of silently no-opping.
    static let nonProseTextExtensions: Set<String> = [
        "json", "yaml", "yml", "toml", "log", "csv", "sh",
        "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp",
    ]

    /// Owner ruling (fix round 1): Office and iWork documents are documents
    /// "by any human reading", even though nothing in `EngineRegistry` parses
    /// their content and they therefore resolve to `AttachmentEngine` like a
    /// `.zip` does. Exactly the five extensions the owner named — not a
    /// broader "every office format" guess — so this stays a deliberate,
    /// reviewable list rather than a proxy for "whatever seems document-y".
    static let documentAttachmentExtensions: Set<String> = [
        "pages", "key", "numbers", "xlsx", "pptx",
    ]

    /// - Parameters:
    ///   - type: `IndexRow.type`, an engine identifier (`DocumentEngine
    ///     .identifier`), NOT a file extension.
    ///   - pathExtension: the file's extension, compared case-insensitively
    ///     against `EmbedRendering.imageExtensions` the same way `EmbedRendering
    ///     .kind(for:)` already does — a `.PNG` screenshot must not be treated
    ///     as junk just because it was saved with an upper-case extension.
    public static func isHiddenByDefault(type: String, pathExtension: String) -> Bool {
        let ext = pathExtension.lowercased()
        switch type {
        case PlainTextEngine.identifier:
            // Markdown, PDF and rich text never land here — only the format
            // `PlainTextEngine` itself claims can be prose OR code/config,
            // so this is the one engine whose files need a second,
            // extension-level check rather than an engine-identity-only one.
            return Self.nonProseTextExtensions.contains(ext)
        case AttachmentEngine.identifier:
            // Everything AttachmentEngine claims is hidden UNLESS it is
            // either an image (renders inline, never junk) or one of the
            // named Office/iWork document extensions the owner explicitly
            // wants kept visible despite resolving to the fallback engine.
            return !EmbedRendering.imageExtensions.contains(ext)
                && !Self.documentAttachmentExtensions.contains(ext)
        default:
            // MarkdownEngine, PDFEngine, RichTextEngine: always documents.
            return false
        }
    }

    public static func isHiddenByDefault(_ row: IndexRow) -> Bool {
        isHiddenByDefault(type: row.type, pathExtension: row.path.pathExtension)
    }

    /// `rows`, minus the ones hidden by default — the browse-list view. Callers
    /// pass `showAllFiles: true` (from `LoreStore.showAllFiles`, the "Show all
    /// files" setting) to get `rows` back unfiltered, without a second index
    /// rebuild: this is a filter over already-loaded rows, so flipping the
    /// setting takes effect on the very next redraw.
    public static func visibleRows(_ rows: [IndexRow], showAllFiles: Bool) -> [IndexRow] {
        showAllFiles ? rows : rows.filter { !isHiddenByDefault($0) }
    }
}
