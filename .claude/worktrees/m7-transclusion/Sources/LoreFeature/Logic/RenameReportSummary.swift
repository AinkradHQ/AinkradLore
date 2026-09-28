import Foundation

// How a `RenamePlan`/`FolderRenamePlan` outcome is DESCRIBED to the user.
//
// Pure text, deliberately separate from the view: SwiftUI is only
// smoke-testable here, and the thing most likely to be wrong about a report is
// not the layout but the sentence. Every claim below is asserted in
// `RenameReportSummaryTests`.
//
// Three inherited requirements are encoded here, each from an earlier review:
//
//  1. `skipped` is never described as somebody else's edit. Its entries are
//     grouped by `SkipReason` and each group gets its own true sentence — the
//     unsaved-edits case even gets the instruction that clears it.
//  2. `unchanged` is SURFACED. A rename where no link text matched anywhere
//     produces empty `rewritten`, empty `skipped` and empty `failed`, which the
//     first cut rendered as "Renamed." with a blank list — indistinguishable
//     from a rename that rewrote everything. Silence about a bulk operation
//     that did nothing is the failure the preview exists to prevent.
//  3. Partial success is stated plainly, not as an error: a skipped file lost
//     nothing, and saying so is what stops the user "fixing" it destructively.
extension RenameReport {

    /// One line, first: what happened at the top level.
    public var headline: String {
        if let refusal = refusalReason { return refusal }
        if movedTo != nil {
            return isCompleteSuccess ? "Renamed." : "Renamed, with some files left alone."
        }
        return isCompleteSuccess ? "Links updated." : "Finished, with some files left alone."
    }

    /// The refusal message when the operation was declined outright — a refused
    /// plan, a name that is not a name, a destination that already exists. Such
    /// a report has a `failed` entry and NOTHING else, and reads better as its
    /// own sentence than as a bullet under "Renamed."
    public var refusalReason: String? {
        guard movedTo == nil, rewritten.isEmpty, skipped.isEmpty, unchanged.isEmpty,
              failed.count == 1 else { return nil }
        return failed[0].reason
    }

    /// The body of the report: one line per fact, in decreasing severity.
    /// Empty only when there is genuinely nothing to add to the headline.
    public var detailLines: [String] {
        guard refusalReason == nil else { return [] }
        var lines: [String] = []

        for failure in failed {
            lines.append("Failed — \(failure.url.lastPathComponent): \(failure.reason)")
        }

        // Grouped in a FIXED order, not dictionary order: a report whose lines
        // reshuffle between two runs of the same operation reads as a different
        // report.
        for reason in [SkipReason.unsavedEdits, .changedOnDisk, .unverifiable] {
            let files = skipped.filter { $0.reason == reason }
            guard !files.isEmpty else { continue }
            lines.append(Self.skipLine(files.map(\.url), reason))
        }

        if !rewritten.isEmpty {
            lines.append("Updated links in \(Self.files(rewritten.count)).")
        } else if !unchanged.isEmpty {
            // Requirement 3. `unchanged` means the files were opened and no
            // delimiter-anchored occurrence of the old target survived to
            // rewrite time — nothing was lost, but nothing was fixed either,
            // and links in them may still name the old title.
            lines.append(
                "No link text matched in \(Self.files(unchanged.count)), "
                + "so nothing was rewritten there — check those links by hand.")
        } else if skipped.isEmpty, failed.isEmpty {
            lines.append("No other document linked to it, so no links needed updating.")
        }

        if !rewritten.isEmpty, !unchanged.isEmpty {
            lines.append("\(Self.files(unchanged.count).capitalizedFirst) matched no link "
                         + "text and were left unchanged.")
        }
        return lines
    }

    /// Requirement 1: each cause gets its own sentence, and the sentence is
    /// TRUE of that cause. The unsaved-edits case carries the way out, because
    /// unlike the other two it is entirely in the user's hands.
    static func skipLine(_ files: [URL], _ reason: SkipReason) -> String {
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        switch reason {
        case .unsavedEdits:
            return "Left alone (\(names)): an open tab still holds unsaved edits, so the "
                 + "links were not rewritten. Save or close that tab and rename again."
        case .changedOnDisk:
            return "Left alone (\(names)): changed outside Lore after the preview, so the "
                 + "links were not rewritten rather than overwrite that change."
        case .unverifiable:
            return "Left alone (\(names)): could not be confirmed unchanged since the "
                 + "preview, so the links were not rewritten."
        }
    }

    /// True when the operation did nothing at all to any link — the case that
    /// used to render as an empty success.
    public var rewroteNothing: Bool { rewritten.isEmpty }

    private static func files(_ n: Int) -> String {
        "\(n) file\(n == 1 ? "" : "s")"
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
