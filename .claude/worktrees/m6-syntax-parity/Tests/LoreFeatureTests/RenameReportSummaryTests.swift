import XCTest
@testable import LoreFeature

/// The report's WORDING, which is the part of a partial-success report most
/// likely to be wrong and least likely to be caught by a view test. Two
/// inherited review findings are pinned here.
final class RenameReportSummaryTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/v/\(name)") }

    /// INHERITED REQUIREMENT. `skipped` has two everyday causes, and the first
    /// cut described both as "changed by another app and were left alone" —
    /// false for the unsaved-edits case, and it sends the user looking for an
    /// external editor that was never involved.
    func test_eachSkipCauseIsDescribedTruthfullyAndSeparately() {
        let report = RenameReport(
            rewritten: [url("ok.md")],
            skipped: [SkippedFile(url: url("mine.md"), reason: .unsavedEdits),
                      SkippedFile(url: url("theirs.md"), reason: .changedOnDisk)],
            failed: [], movedTo: url("New.md"))

        let lines = report.detailLines
        let unsaved = try? XCTUnwrap(lines.first { $0.contains("mine.md") })
        let external = try? XCTUnwrap(lines.first { $0.contains("theirs.md") })

        // Two distinct sentences, not one blanket claim.
        XCTAssertNotEqual(unsaved, external)
        XCTAssertTrue(unsaved?.contains("unsaved edits") == true, unsaved ?? "")
        XCTAssertTrue(unsaved?.contains("Save or close that tab") == true, unsaved ?? "")
        XCTAssertFalse(unsaved?.contains("outside Lore") == true,
                       "an unsaved-edits skip must not be blamed on another app")
        XCTAssertTrue(external?.contains("changed outside Lore") == true, external ?? "")
        XCTAssertFalse(external?.contains("unsaved") == true, external ?? "")
        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertEqual(report.headline, "Renamed, with some files left alone.")
    }

    func test_unverifiableSkipIsNotDescribedAsAnExternalEdit() {
        let report = RenameReport(rewritten: [], skipped: [
            SkippedFile(url: url("a.md"), reason: .unverifiable)
        ], failed: [], movedTo: nil)
        let line = report.detailLines.first { $0.contains("a.md") }
        XCTAssertTrue(line?.contains("could not be confirmed unchanged") == true, line ?? "")
        XCTAssertFalse(line?.contains("changed outside Lore") == true, line ?? "")
    }

    /// INHERITED REQUIREMENT. Files where no link text matched land in
    /// `unchanged` — neither `rewritten` nor `skipped` — so a rename that
    /// rewrote NOTHING used to render as complete success with an empty list.
    func test_aRenameThatRewroteNothingSaysSo() {
        let report = RenameReport(rewritten: [], skipped: [],
                                  unchanged: [url("a.md"), url("b.md")],
                                  failed: [], movedTo: url("New.md"))

        XCTAssertTrue(report.isCompleteSuccess, "nothing failed — this is not an error")
        XCTAssertTrue(report.rewroteNothing)
        let joined = report.detailLines.joined(separator: " ")
        XCTAssertTrue(joined.contains("No link text matched in 2 files"), joined)
        XCTAssertTrue(joined.contains("check those links by hand"), joined)
    }

    /// `unchanged` alongside a real rewrite is still reported: a partial match
    /// is exactly the case where the user needs to look at the rest.
    func test_unchangedIsReportedEvenWhenSomethingWasRewritten() {
        let report = RenameReport(rewritten: [url("a.md")], skipped: [],
                                  unchanged: [url("b.md")], failed: [], movedTo: nil)
        let joined = report.detailLines.joined(separator: " ")
        XCTAssertTrue(joined.contains("Updated links in 1 file"), joined)
        XCTAssertTrue(joined.contains("matched no link text"), joined)
    }

    func test_aRenameWithNoInboundLinksSaysThatPlainly() {
        let report = RenameReport(rewritten: [], skipped: [], failed: [],
                                  movedTo: url("New.md"))
        XCTAssertEqual(report.headline, "Renamed.")
        XCTAssertEqual(report.detailLines,
                       ["No other document linked to it, so no links needed updating."])
    }

    /// A refusal reads as its own sentence rather than as a bullet under a
    /// success headline.
    func test_aRefusalIsTheHeadline() {
        let report = RenameReport(rewritten: [], skipped: [],
                                  failed: [(url("a.md"), "A file with that name already exists.")],
                                  movedTo: nil)
        XCTAssertEqual(report.headline, "A file with that name already exists.")
        XCTAssertTrue(report.detailLines.isEmpty)
    }

    func test_aFailureAlongsideWorkIsListedNotHidden() {
        let report = RenameReport(rewritten: [url("a.md")], skipped: [],
                                  failed: [(url("b.md"), "Could not rewrite the link “X”.")],
                                  movedTo: nil)
        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertTrue(report.detailLines[0].hasPrefix("Failed — b.md:"), report.detailLines[0])
    }
}
