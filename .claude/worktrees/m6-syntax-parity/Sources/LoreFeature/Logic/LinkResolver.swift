import Foundation

/// Resolves raw link targets to documents, using Obsidian's rules.
///
/// Basename-first: `[[Design]]` finds `Projects/Design.md` although the link
/// names neither the folder nor the extension. A target containing a `/`
/// is treated as a path suffix and disambiguates. Matching is case-insensitive,
/// as Obsidian is on macOS. Frontmatter aliases participate.
///
/// Since M3, a target can also name an attachment WITH its extension —
/// `[[Contract.pdf]]`, `![[diagram.png]]` — because both the extension-bearing
/// and extension-stripped spellings of every document's filename are
/// registered as keys. See `init`.
///
/// Ambiguity is resolved with markdown notes preferred first (see
/// `sortByPreference`), then to the SHORTEST path, matching Obsidian — a link
/// can therefore point somewhere the author did not intend when two documents
/// share a basename, which is why the backlinks panel surfaces ambiguity.
///
/// Resolution MUST be a pure function of the vault's contents, independent of
/// the order documents were passed to `init` or of `Dictionary` iteration
/// order (which Swift randomizes per process via hash seeding). Two places
/// need this discipline:
///  - the suffix-match branch of `resolve`, which used to filter
///    `byKey.values.flatMap { $0 }` — iterating a dictionary's `.values` — and
///    could resolve the same link to a different document on different runs
///    of the same, unchanged vault;
///  - the per-key candidate lists in `byKey`, whose equal-length ties used to
///    fall back to `Array.sorted`'s stability, i.e. to input order (which is
///    filesystem enumeration order in `scanVault`, row order in
///    `indexDocument` — neither guaranteed stable across runs).
/// Both are fixed the same way: sort markdown-first, then by path length,
/// then lexicographically by the full path, so equal-length ties break on
/// path content alone.
/// What a `[[Note#…]]` fragment names: a heading, or a `^block-id` anchor.
/// The discriminator is a single `^` immediately after the `#`.
public enum LinkFragment: Sendable, Equatable {
    case heading(String)
    case block(String)
}

public struct LinkResolver: Sendable {
    private let byKey: [String: [URL]]
    /// All document URLs, sorted deterministically (markdown-first, then
    /// length, then lexicographic path) — the candidate source for the
    /// suffix-match branch. Built once so a per-call `.values.flatMap`
    /// (dictionary iteration order, and O(total documents) per call) is
    /// never needed.
    private let sortedDocuments: [URL]

    public init(documents: [(url: URL, title: String, aliases: [String])]) {
        var map: [String: [URL]] = [:]
        var seen = Set<String>()
        var allURLs: [URL] = []
        for doc in documents {
            if seen.insert(doc.url.path).inserted { allURLs.append(doc.url) }
            // Both spellings of the filename are keys now: `Contract` and
            // `Contract.pdf`. An attachment is normally written WITH its
            // extension (`[[Contract.pdf]]`, `![[diagram.png]]`) because that
            // is what the file is called, while a note is written without one.
            // Registering only the extension-stripped form is why every
            // attachment link resolved to nothing before M3.
            var keys = [doc.url.deletingPathExtension().lastPathComponent,
                        doc.url.lastPathComponent,
                        doc.title]
            keys.append(contentsOf: doc.aliases)
            for key in keys where !key.isEmpty {
                map[key.lowercased(), default: []].append(doc.url)
            }
        }
        byKey = map.mapValues { Self.sortByPreference($0) }
        sortedDocuments = Self.sortByPreference(allURLs)
    }

    /// Markdown first, then shortest path, then lexicographic.
    ///
    /// The markdown tier is new in M3 and is NOT cosmetic. Before attachments
    /// were resolvable, every candidate was a note and length alone decided.
    /// Now a vault can hold `Budget.xlsx` at the root and `Notes/Budget.md`
    /// below it, and length-first would silently redirect every existing
    /// `[[Budget]]` in the vault to the spreadsheet. Links that already work
    /// must keep working — that is what this tier guarantees.
    ///
    /// The last two tiers are unchanged and exist for determinism: ties broken
    /// by insertion or dictionary iteration order made the same unchanged vault
    /// resolve differently across runs.
    private static func sortByPreference(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let lhsMarkdown = MarkdownEngine.canOpen(lhs)
            let rhsMarkdown = MarkdownEngine.canOpen(rhs)
            if lhsMarkdown != rhsMarkdown { return lhsMarkdown }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
    }

    /// Strips any `#Heading` / `#^block` fragment, and — unconditionally — a
    /// trailing `.md`.
    ///
    /// The `.md` strip is restored (owner ruling, post-review): it preserves
    /// pre-M3 resolution EXACTLY, including cases the M3 dual-key scheme in
    /// `init` doesn't cover on its own — e.g. a decoded markdown-syntax link
    /// `[t](Design%20Doc.md)` resolves to `"Design Doc.md"`, which is not a
    /// registered key when the note's title (`Design Doc`) slugs to a
    /// different filename (`design-doc.md`); stripping first makes it hit the
    /// `title` key the way it always did. It costs nothing for attachments:
    /// only the literal suffix `.md` is stripped, so `Contract.pdf` is
    /// untouched and still resolves via its own extension-bearing key from
    /// `init`. Any OTHER extension-bearing target (`Contract.pdf`,
    /// `diagram.png`) is looked up verbatim, via the keys `init` registers.
    public static func basename(of rawTarget: String) -> String {
        var target = rawTarget
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces)
        if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
        return target
    }

    /// The `#…` fragment a raw target carries, if any — distinguishing
    /// `#^block-id` from `#Heading`. `nil` when there is no `#` at all.
    public static func fragment(of rawTarget: String) -> LinkFragment? {
        guard let hash = rawTarget.firstIndex(of: "#") else { return nil }
        let raw = String(rawTarget[rawTarget.index(after: hash)...])
        if raw.hasPrefix("^") {
            return .block(String(raw.dropFirst()))
        }
        return .heading(raw)
    }

    public func resolve(_ rawTarget: String) -> URL? {
        let target = Self.basename(of: rawTarget)
        guard !target.isEmpty else { return nil }

        if target.contains("/") {
            // Explicit path. The WITH-extension suffix match runs first, and
            // ALONE, when the target carries an extension: `Docs/Contract.pdf`
            // must resolve to the PDF even when `Docs/Contract.md` also exists
            // at the same stem. Falling through to a without-extension match
            // in that case is the bug a review caught — `sortedDocuments` is
            // markdown-first, so an extension-STRIPPED suffix match on
            // `Docs/Contract.pdf` would find `Docs/Contract.md` and win on the
            // markdown tier, silently redirecting an attachment link (and any
            // rename `LinkRewriter` later plans from it) to the wrong file.
            // The without-extension pass exists only for a target that HAS no
            // extension of its own (`Docs/Contract`) — there "extension" isn't
            // part of what the author named, so any spelling of the stem is
            // fair game — or as a fallback when the with-extension pass finds
            // nothing at all (a target whose exact extension isn't indexed).
            let lowered = target.lowercased()
            let withExtension = "/" + lowered
            let targetHasExtension = !(lowered as NSString).pathExtension.isEmpty
            if targetHasExtension {
                if let match = sortedDocuments.first(where: { $0.path.lowercased().hasSuffix(withExtension) }) {
                    return match
                }
            }
            let withoutExtension = "/" + (lowered as NSString).deletingPathExtension
            return sortedDocuments.first {
                $0.deletingPathExtension().path.lowercased().hasSuffix(withoutExtension)
            }
        }
        return byKey[target.lowercased()]?.first
    }
}
