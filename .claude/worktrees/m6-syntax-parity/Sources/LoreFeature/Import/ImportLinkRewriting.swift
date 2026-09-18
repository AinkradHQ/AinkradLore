import Foundation

/// Points an imported note's links at where its neighbours actually landed.
///
/// The problem this exists for: the planner proposes `Plan.md`, but the applier
/// re-resolves against the real directory and may land it as `Plan 2.md`
/// because the user already owned that name. Every OTHER imported note that
/// said `[[Plan]]` is then pointing at the user's unrelated file — not broken
/// in a way anyone would notice, which is worse than broken. The same goes for
/// `![[pic.png]]` when the image lands as `pic 2.png`, and that one orphans an
/// embed outright.
///
/// Rewriting happens in the applier's SECOND pass, once every name in the run
/// is final. It cannot happen in the planner: the planner is pure and never
/// touches disk, so it cannot know which names were already taken.
enum ImportLinkRewriting {
    /// Applies `renames` to the links in `markdown`.
    ///
    /// Delegates the actual substitution to `LinkRewriter.replacingLinkTargets`
    /// rather than doing its own string replacement. That function drives the
    /// SAME `LinkParser` the editor and the rename pipeline use, so a link
    /// spelling this codebase understands anywhere it understands here too —
    /// and, just as importantly, a `[[Plan]]` inside a fenced code block or a
    /// frontmatter value is left alone, because the parser already knows those
    /// are not links. Hand-rolled substitution is how you rewrite the word
    /// "Plan" inside someone's code sample.
    static func rewritten(_ markdown: String, in file: URL,
                          renames: [(from: String, to: String)]) -> String {
        let edits = self.edits(in: file, renames: renames)
        guard !edits.isEmpty else { return markdown }
        return LinkRewriter.replacingLinkTargets(in: markdown, edits: edits)
    }

    /// Every spelling of a renamed file that a link might legitimately use.
    ///
    /// A wikilink to a note is written without its extension (`[[Plan]]`), an
    /// embed of an attachment keeps it (`![[pic.png]]`), and a markdown link
    /// may use either. Emitting both forms for markdown files and only the
    /// full name for everything else matches how the two are actually written,
    /// and avoids inventing an extensionless `[[pic]]` spelling for an image
    /// that nothing would have produced.
    ///
    /// DELIBERATELY basename-only. Obsidian resolves `[[Plan]]` by searching
    /// the vault, not by path, so a path-qualified rewrite would be a
    /// different link rather than the same one relocated. The cost of that is
    /// stated plainly in `KnownAmbiguity` below.
    static func edits(in file: URL,
                      renames: [(from: String, to: String)]) -> [LinkEdit] {
        var edits: [LinkEdit] = []
        for rename in renames where rename.from != rename.to {
            edits.append(LinkEdit(file: file, oldTarget: rename.from,
                                  newTarget: rename.to))
            guard (rename.from as NSString).pathExtension.lowercased() == "md" else { continue }
            let oldStem = (rename.from as NSString).deletingPathExtension
            let newStem = (rename.to as NSString).deletingPathExtension
            if oldStem != rename.from {
                edits.append(LinkEdit(file: file, oldTarget: oldStem, newTarget: newStem))
            }
        }
        return edits
    }

    /// KNOWN AND ACCEPTED: a rewrite is basename-matched, so if an imported
    /// note links `[[Plan]]` meaning some OTHER Plan — one already in the
    /// vault, or one in a different folder of the same import — this points it
    /// at the renamed one instead.
    ///
    /// Not fixed here because the alternative is worse in the common case.
    /// Obsidian's own resolution is basename-first, so at import time the two
    /// `Plan`s were already ambiguous IN THE SOURCE; rewriting picks one
    /// reading of a link that never had a single correct answer. Leaving it
    /// alone, by contrast, guarantees a broken embed every time an attachment
    /// is renamed, which is the failure with no ambiguity about it at all.
    ///
    /// This is recorded rather than fixed on purpose: it is a decision that
    /// was made, not a bug that was missed.
    private enum KnownAmbiguity {}
}
