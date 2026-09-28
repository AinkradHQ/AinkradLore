import Foundation

/// One link edit inside one file.
public struct LinkEdit: Sendable, Equatable {
    public let file: URL
    public let oldTarget: String
    public let newTarget: String
    public init(file: URL, oldTarget: String, newTarget: String) {
        self.file = file; self.oldTarget = oldTarget; self.newTarget = newTarget
    }
}

/// An inbound link the planner could not rewrite. Surfaced rather than
/// dropped: "the index says this file links here, and the rename cannot fix
/// it" is exactly the condition that, swallowed, produces a rename that looks
/// clean while a link quietly breaks.
public struct UnrewritableLink: Sendable, Equatable {
    public let sourceFile: URL
    public let rawTarget: String
    public init(sourceFile: URL, rawTarget: String) {
        self.sourceFile = sourceFile; self.rawTarget = rawTarget
    }
}

/// The complete change set for a rename or move, computed before anything is
/// written. Nothing in M1 mutates more than one file without one of these.
public struct RenamePlan: Sendable {
    public let source: URL
    public let destination: URL
    public let edits: [LinkEdit]
    /// Links the planner had to give up on — reported by `apply` as failures.
    public let unrewritable: [UnrewritableLink]

    /// Each affected file's modification date AS OF PLANNING TIME, keyed by
    /// path. `apply` refuses to write a file whose mtime has moved past its
    /// entry: with Obsidian open on the same vault, that is an edit made
    /// between the preview and the confirmation, and overwriting it destroys
    /// it. Empty means "no baseline known", which is treated as unsafe-to-
    /// compare rather than safe-to-write — see `LinkRewriter.applyEdits`.
    ///
    /// Captured in `LoreStore.plan`, NOT here: `LinkRewriter` stays pure.
    /// Reading the mtime inside `apply` instead would make the check
    /// tautological (the value is read microseconds before it is compared) and
    /// the guard would never fire.
    public let baselines: [String: Date]

    /// Non-nil when the operation was refused at PLAN time, before anything was
    /// computed — today only an invalid new name (empty, a path separator, `.`,
    /// `..`, or a destination outside the vault root). A refusal is carried on
    /// the plan rather than thrown so the preview UI can render it beside every
    /// other outcome, and so `apply` has exactly one place to report it.
    ///
    /// `apply` writes NOTHING and creates NOTHING for a refused plan.
    public let refusal: String?

    public init(source: URL, destination: URL, edits: [LinkEdit],
                unrewritable: [UnrewritableLink] = [],
                baselines: [String: Date] = [:],
                refusal: String? = nil) {
        self.source = source; self.destination = destination; self.edits = edits
        self.unrewritable = unrewritable; self.baselines = baselines
        self.refusal = refusal
    }

    /// A copy carrying freshly-read mtimes. Keeps the mtime read (I/O) out of
    /// `LinkRewriter` while keeping the value on the plan, where `apply` needs
    /// it and where the preview UI (Task 10) can see it too.
    public func withBaselines(_ baselines: [String: Date]) -> RenamePlan {
        RenamePlan(source: source, destination: destination, edits: edits,
                   unrewritable: unrewritable, baselines: baselines,
                   refusal: refusal)
    }

    /// First-seen order, deduplicated, so the confirmation UI shows a stable
    /// file list rather than one entry per edit.
    public var affectedFiles: [URL] {
        var seen = Set<String>()
        return edits.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
    }
    public var isEmpty: Bool { edits.isEmpty }
}

/// Computes — but never applies — every inbound-link edit a rename or move
/// requires. Pure computation: no disk access, no store, nothing mutated.
/// Task 7 owns applying the resulting `RenamePlan`.
public enum LinkRewriter {
    /// Computes every inbound-link edit a rename or move requires.
    ///
    /// The rewritten target preserves the AUTHOR'S style: a bare `[[Design]]`
    /// becomes `[[Architecture]]`, a foldered `[[Projects/Design]]` keeps its
    /// folder, an extensioned `[[Design.md]]` keeps its extension, and any
    /// `#fragment` survives untouched. Normalizing every link to a full path
    /// would be a bulk mutation nobody asked for.
    ///
    /// An explicit-path target (one containing `/`) is rewritten relative to
    /// `vaultRoot`, since Obsidian's explicit paths are vault-relative, not
    /// relative to the linking document.
    ///
    /// No edit is produced when the rewritten target equals the original —
    /// an unchanged link is not an edit, and listing it would inflate the
    /// count shown in the confirmation UI. This is also why a plain move
    /// (same basename, new folder) produces no edit for a bare link: a bare
    /// link resolves by basename, so it still resolves after the move.
    public static func plan(renaming source: URL,
                            to destination: URL,
                            inboundLinks: [(sourceFile: URL, rawTarget: String,
                                            syntax: LinkSyntax)],
                            vaultRoot: URL) -> RenamePlan {
        var edits: [LinkEdit] = []
        var unrewritable: [UnrewritableLink] = []
        for link in inboundLinks {
            guard let newTarget = rewritten(link.rawTarget, syntax: link.syntax,
                                            from: source,
                                            to: destination,
                                            vaultRoot: vaultRoot) else {
                // Not "no change needed" — no rewrite EXISTS. Recorded so the
                // rename reports a link it cannot keep working, instead of
                // returning a zero-edit plan that reads as success.
                unrewritable.append(UnrewritableLink(sourceFile: link.sourceFile,
                                                     rawTarget: link.rawTarget))
                continue
            }
            // Compared DECODED on both sides: `rewritten` returns a decoded
            // target, so a percent-encoded link that needs no change
            // (`Design%20Doc.md` → `Design Doc.md`) would otherwise look like
            // an edit and be written back unencoded.
            guard newTarget != decodedTarget(link.rawTarget, syntax: link.syntax)
            else { continue }
            edits.append(LinkEdit(file: link.sourceFile, oldTarget: link.rawTarget,
                                  newTarget: newTarget))
        }
        return RenamePlan(source: source, destination: destination,
                          edits: edits, unrewritable: unrewritable)
    }

    /// A raw target with its path part percent-decoded and its fragment left
    /// alone — the form `rewritten` both analyses and returns.
    ///
    /// Decoding is conditional on `syntax`, for exactly the reason
    /// `DocumentLink.resolutionTarget` makes it conditional: Obsidian never
    /// percent-encodes a WIKILINK target, so a `%` inside one is a literal `%`
    /// in a filename. Decoding it unconditionally (as this used to) produced
    /// two silent faults — `[[C%2FD]]` turned into `C/D`, so the planner
    /// treated a bare target as a vault-relative PATH it never was; and
    /// renaming `100%20off.md` to `100 off` made the "decoded" old target equal
    /// the new one, so the equality guard below skipped the edit and left the
    /// wikilink dangling. One decoding rule, keyed on syntax, everywhere.
    static func decodedTarget(_ rawTarget: String, syntax: LinkSyntax) -> String {
        guard syntax == .markdown else { return rawTarget }
        let split = splitFragment(rawTarget)
        return (split.body.removingPercentEncoding ?? split.body) + split.fragment
    }

    /// Rewrites a single raw link target to reflect `destination`, or returns
    /// `nil` when no sensible rewrite exists — currently only when the target
    /// names an explicit path or extension (so it must track the move) but
    /// `destination` does not live under `vaultRoot`. In that case there is no
    /// vault-relative path to produce, and inventing one (e.g. an absolute
    /// filesystem path) would hand the confirmation UI a corrupted-looking
    /// target that is worse than simply omitting the edit.
    static func rewritten(_ rawTarget: String, syntax: LinkSyntax,
                          from source: URL,
                          to destination: URL,
                          vaultRoot: URL) -> String? {
        // Split off the fragment; it is carried through untouched.
        let split = splitFragment(rawTarget)
        let fragment = split.fragment
        // Percent-DECODED for analysis and for the value returned, but ONLY for
        // a markdown link: one written `Design%20Doc.md` names a file called
        // `Design Doc.md`, and the style questions below ("does it carry an
        // extension?", "does it name a folder?") are about the real name, not
        // the escaping. A WIKILINK is never encoded, so its `%` is literal —
        // see `decodedTarget`. The result is handed back decoded;
        // `written(_:like:)` re-encodes it at write time, where the link's
        // SYNTAX is known and a wikilink can be excluded from encoding.
        let body = syntax == .markdown
            ? (split.body.removingPercentEncoding ?? split.body) : split.body
        // ANY explicit extension names a location precisely enough that it
        // must track a move — not just `.md`. A bare `[[Contract.pdf]]` is as
        // explicit as `[[Design.md]]`, and this generalizes past `.md` so a
        // non-markdown attachment's extension is not silently dropped on
        // rewrite (renaming `Contract.pdf` to `Agreement.pdf` used to leave
        // the note pointing at `[[Agreement]]`, still resolvable by basename
        // but not what the author wrote). See
        // `M3AcceptanceTests.test_criterion7_renamingThePDFRewritesTheLinkInTheReferringNote`.
        //
        // BUT: `(body as NSString).pathExtension` alone cannot tell an
        // extension from a dotted TITLE — `[[Chapter 1.1]]`, `[[v1.2]]`,
        // `[[Report 2024.10]]` all have a non-empty trailing dot-suffix that
        // is not an extension at all. The only ground truth for "is this
        // suffix really an extension" is `source`, the actual file the link
        // resolves to: a trailing dot-suffix counts as an explicit extension
        // only when it MATCHES `source`'s real extension (case-insensitively).
        // `source.pathExtension` naturally handles multi-dot extensions too
        // (`archive.tar.gz` → `.pathExtension` is `"gz"`, and a body ending
        // `.tar.gz` matches that the same way).
        let bodyExtension = (body as NSString).pathExtension
        let sourceExtension = source.pathExtension
        let hadExtension = !bodyExtension.isEmpty && !sourceExtension.isEmpty
            && bodyExtension.lowercased() == sourceExtension.lowercased()
        let withoutExtension = hadExtension
            ? String(body.dropLast(bodyExtension.count + 1)) : body
        let hadPath = withoutExtension.contains("/")

        let newBase = destination.deletingPathExtension().lastPathComponent
        var newBody: String
        if hadPath || hadExtension {
            // An explicit path, or an explicit extension, names a location
            // precisely enough that it must track a move — recompute it
            // against the vault root rather than only swapping the basename.
            guard let relative = vaultRelativePath(of: destination.deletingPathExtension(),
                                                    vaultRoot: vaultRoot) else {
                return nil
            }
            newBody = relative
        } else {
            newBody = newBase
        }
        // The rewritten extension tracks `destination`'s actual extension
        // (not a hardcoded `.md`), so a non-markdown rename keeps its own
        // extension rather than borrowing markdown's. Guarded against an
        // empty `destination.pathExtension`: latent today (`plan(rename:to:)`
        // always re-appends the source's extension, so `hadExtension` implies
        // a non-empty destination extension too), but an unguarded concat on
        // a file-mutating path is worth closing rather than trusting a caller
        // invariant to hold forever.
        if hadExtension, !destination.pathExtension.isEmpty {
            newBody += "." + destination.pathExtension
        }
        return newBody + fragment
    }

    /// Strips `vaultRoot`'s path components from the front of `path`'s
    /// components, returning `nil` if `path` is not actually nested under
    /// `vaultRoot`. Compares components, not raw strings, so it is immune to
    /// trailing slashes and to the root's path text recurring elsewhere
    /// inside the destination path (a plain `replacingOccurrences` would
    /// mangle both of those cases).
    ///
    /// Deliberately does NOT use `.standardizedFileURL` here, despite the
    /// name suggesting it is the right tool: `stringByStandardizingPath`
    /// (what it calls under the hood) strips a leading `/private` from
    /// `/private/var`, `/private/tmp`, `/private/etc` — but ONLY when the
    /// shortened path can be verified to resolve to the same file, which
    /// requires that shortened path to actually exist. `vaultRoot` almost
    /// always exists (it is a real, already-active vault) and gets stripped;
    /// `path` is a rename/move DESTINATION that, for a folder rename or a
    /// move into a not-yet-created folder, does not exist yet and is left
    /// alone. The two sides then disagree only in whether they still carry
    /// `/private`, every prefix match fails, and every explicit-path or
    /// explicit-extension inbound link for that document is silently dropped
    /// as "outside the vault" — with no error, just an empty edit list. Both
    /// `vaultRoot` and `path` arrive here already canonicalized consistently
    /// by the caller (`LoreStore+Rename.swift` sources everything through
    /// `VaultIndexCoordinator.canonical`), so comparing raw path components
    /// is enough and does not need — must NOT use — a second pass through
    /// path standardization.
    private static func vaultRelativePath(of path: URL, vaultRoot: URL) -> String? {
        let rootComponents = vaultRoot.pathComponents
        let pathComponents = path.pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return pathComponents.suffix(from: rootComponents.count).joined(separator: "/")
    }
}

/// Why one file was left alone by a rewrite pass.
///
/// Carried per file rather than implied by the list it lands in, because
/// `skipped` has THREE causes that are not interchangeable to the person
/// reading the report: "another app edited this file" is a fact about the
/// vault, while "your own tab has unsaved edits" is an instruction to go and
/// save. The first cut of the confirmation UI described every skip as "changed
/// by another app and left alone", which is simply false for the unsaved-edits
/// case — a report that misattributes a cause is worse than one that omits it,
/// because the user acts on it.
public enum SkipReason: Sendable, Equatable {
    /// The file's mtime moved past the plan-time baseline: someone edited it
    /// between the preview and the confirmation.
    case changedOnDisk
    /// No usable baseline, or the mtime could not be read. We cannot prove the
    /// file is the one we planned against, so we do not write it.
    case unverifiable
    /// An open tab still holds unsaved edits to it and flushing them refused,
    /// so the file was excluded from the rewrite entirely.
    case unsavedEdits

    /// Completes the sentence "This file …". Present tense, because each of
    /// these is still true when the user reads it.
    public var phrase: String {
        switch self {
        case .changedOnDisk: "was changed outside Lore after the preview"
        case .unverifiable: "could not be confirmed unchanged since the preview"
        case .unsavedEdits: "has unsaved edits in an open tab"
        }
    }
}

/// One file a rewrite pass declined to write, with the reason it declined.
public struct SkippedFile: Sendable, Equatable {
    public let url: URL
    public let reason: SkipReason
    public init(url: URL, reason: SkipReason) {
        self.url = url; self.reason = reason
    }
}

/// What actually happened when a plan was applied. Partial success is the
/// EXPECTED case, not an error state: a file that changed on disk is skipped
/// so an edit made seconds ago in another app is not destroyed. `apply` does
/// not throw — the caller decides how to present this.
public struct RenameReport: Sendable {
    /// Files whose inbound links were rewritten.
    public let rewritten: [URL]
    /// Files left ALONE, each carrying WHY — see `SkipReason`. Their links still
    /// point at the old name; nothing was lost.
    public let skipped: [SkippedFile]
    /// Files that were opened and matched nothing — no delimiter-anchored
    /// occurrence of the old target survived to rewrite time. Nothing was
    /// written, so they must not be listed as `rewritten` (an untruthful
    /// report) nor as `skipped` (nothing was refused).
    public let unchanged: [URL]
    /// Files that could not be processed, with a human-readable reason. Also
    /// carries plan-time unrewritable links and a refused move.
    public let failed: [(url: URL, reason: String)]
    /// The new location, or nil if the file was not moved.
    public let movedTo: URL?

    public init(rewritten: [URL], skipped: [SkippedFile], unchanged: [URL] = [],
                failed: [(url: URL, reason: String)], movedTo: URL?) {
        self.rewritten = rewritten; self.skipped = skipped
        self.unchanged = unchanged
        self.failed = failed; self.movedTo = movedTo
    }

    /// True when every file the plan named was handled and the move (if any)
    /// happened. The UI shows a confirmation only for this.
    public var isCompleteSuccess: Bool { skipped.isEmpty && failed.isEmpty }
}

extension LinkRewriter {
    /// What `applyEdits` did to one file. Three states, not a `Bool`: "opened
    /// it and nothing matched" is neither a write nor a refusal, and collapsing
    /// it into either one makes the report lie — and, worse, drags that file's
    /// tab through a `resolveByReloading()` it never needed.
    /// Explicitly `Equatable`: an enum stops synthesizing it as soon as a case
    /// carries an associated value, and `.skipped` now carries its cause.
    enum EditOutcome: Equatable {
        case written
        /// No delimiter-anchored occurrence matched. Nothing was written.
        case unchanged
        /// Refused, with the cause: the file changed on disk since the plan, or
        /// we have no baseline to compare against. The cause travels with the
        /// outcome so the report can word each case correctly instead of
        /// describing every skip as somebody else's edit.
        case skipped(SkipReason)
    }

    /// Applies one file's edits, refusing if the file changed since `baseline`.
    ///
    /// A nil `baseline` is treated as "changed": we cannot prove the file is
    /// the one we planned against, and this operation edits files the user did
    /// not open. Failing closed costs a redo; failing open costs their text.
    static func applyEdits(_ edits: [LinkEdit], to file: URL,
                           baseline: Date?) throws -> EditOutcome {
        guard let baseline else { return .skipped(.unverifiable) }
        // Split from the comparison so the two causes stay distinguishable in
        // the report: an unreadable mtime is "cannot verify", a newer one is
        // "somebody edited it". Same behaviour, honest wording.
        guard let disk = try? FileManager.default
                .attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        else { return .skipped(.unverifiable) }
        guard disk <= baseline else { return .skipped(.changedOnDisk) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let out = replacingLinkTargets(in: text, edits: edits)
        // Rewriting identical bytes would only bump the mtime and make every
        // OTHER open editor think the file changed underneath it.
        guard out != text else { return .unchanged }
        try out.write(to: file, atomically: true, encoding: .utf8)
        return .written
    }

    /// Rewrites the targets of REAL links only — `[[old]]`, `[[old|display]]`,
    /// `![[old]]` and `[t](old)` — leaving display text, surrounding prose and
    /// every non-link region of the document untouched.
    ///
    /// ## Why by range, and not by string
    ///
    /// This used to be a whole-document `replacingOccurrences` anchored on the
    /// link delimiters. Anchoring stopped it hitting the word "design" in a
    /// sentence, but it could not stop it hitting a `[[Design]]` written INSIDE
    /// a fenced code block, inside inline code, or in the frontmatter — all
    /// three of which `LinkParser` deliberately excludes from the link graph.
    /// So one real link anywhere in a file caused documentation ABOUT a link,
    /// in a file the user never opened, to be silently edited. There is no undo.
    ///
    /// The fix asks `LinkParser` — the ONE scanner that already knows where
    /// code regions are — for the spans it found, and replaces those spans by
    /// range. A second scanner living here would only have to agree with the
    /// first one forever, and the whole class of bug is two scanners drifting.
    /// Spans are applied BACK TO FRONT so that an earlier replacement of a
    /// different length cannot invalidate a later span's offsets.
    ///
    /// Frontmatter is excluded by starting the scan at `Frontmatter.bodyOffset`
    /// — the parser never sees frontmatter either, because it is fed
    /// `Note.body`.
    static func replacingLinkTargets(in text: String, edits: [LinkEdit]) -> String {
        guard !edits.isEmpty else { return text }
        let offset = Frontmatter.bodyOffset(in: text)
        let body = String(text.dropFirst(offset))
        var chars = Array(text)
        for span in LinkParser.spans(in: body).reversed() {
            // Matched on the RAW target: that is the spelling the index stored
            // and therefore the spelling `LinkEdit.oldTarget` carries.
            guard let edit = edits.first(where: { $0.oldTarget == span.link.rawTarget })
            else { continue }
            let start = offset + span.targetRange.lowerBound
            let end = offset + span.targetRange.upperBound
            guard start <= end, end <= chars.count else { continue }
            chars.replaceSubrange(start..<end,
                                  with: written(edit.newTarget, like: span.link))
        }
        return String(chars)
    }

    /// The new target, spelled so that it still resolves OUTSIDE Lore.
    ///
    /// `newTarget` arrives percent-DECODED (see `rewritten`).
    ///
    /// This used to key off the author's style — encode the new target only if
    /// the OLD one was encoded — which is why it is now written the other way
    /// round. Renaming a note to a name containing a space rewrote every
    /// unencoded markdown link `[t](Design.md)` to `[t](New Name.md)`. Lore's
    /// own parser reads that back, but CommonMark and Obsidian do not: an
    /// unencoded space TERMINATES a link destination, so the link silently
    /// broke in the very editor the vault is shared with. Style preservation is
    /// the right instinct, but it cannot outrank producing a target that
    /// actually resolves.
    ///
    /// So: encode whenever the NEW target requires it, regardless of the old
    /// spelling. A target that needs no encoding is left alone, so an ordinary
    /// rename still produces a clean, unencoded link. A WIKILINK is never
    /// encoded — Obsidian does not encode those, and an encoded one would stop
    /// resolving there.
    private static func written(_ newTarget: String, like link: DocumentLink) -> String {
        guard link.syntax == .markdown else { return newTarget }
        // The `#` fragment is a DELIMITER, not part of the path: encoding it to
        // `%23` would fold the heading into the filename. Split first, encode
        // only the path, put the fragment back as it came.
        let (body, fragment) = splitFragment(newTarget)
        return markdownDestination(body) + fragment
    }

    /// Percent-encodes exactly the characters that stop a CommonMark link
    /// destination from being read as one whole destination:
    ///
    /// * **space** (and any other whitespace) — terminates the destination; the
    ///   remainder is parsed as a link TITLE, or the link fails outright.
    /// * **`(`, `)`** — the destination's own delimiters. An unbalanced one
    ///   closes the link early.
    /// * **control characters** — not valid in a destination, and invisible in
    ///   the file, which makes the breakage unexplainable.
    /// * **`%`** — not a CommonMark requirement but a ROUND-TRIP one. Every
    ///   reader of a markdown destination (Lore's own `resolutionTarget`
    ///   included) percent-DECODES it, so a literal `%` written raw comes back
    ///   as something else: a file genuinely named `100%20off` would be read as
    ///   `100 off`. Encoded to `%25`, it decodes back to itself.
    ///
    /// Deliberately NOT the whole of `.urlPathAllowed`'s complement: that
    /// encodes `#`, `?`, `[`, `]`, `&`, non-ASCII letters and more, none of
    /// which a markdown reader needs escaped, and all of which would turn an
    /// ordinary rename into an unreadable churn of `%`-triplets in the user's
    /// own file.
    static func markdownDestination(_ body: String) -> String {
        var out = ""
        for character in body {
            if needsEncoding(character) {
                for byte in String(character).utf8 {
                    out += String(format: "%%%02X", byte)
                }
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func needsEncoding(_ character: Character) -> Bool {
        if character == "(" || character == ")" || character == "%" { return true }
        return character.unicodeScalars.allSatisfy {
            $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F
        }
    }

    /// Splits a raw target into its path part and its `#…` fragment (empty
    /// when there is none). Both halves are returned verbatim.
    private static func splitFragment(_ rawTarget: String) -> (body: String, fragment: String) {
        guard let hash = rawTarget.firstIndex(of: "#") else { return (rawTarget, "") }
        return (String(rawTarget[..<hash]), String(rawTarget[hash...]))
    }
}
