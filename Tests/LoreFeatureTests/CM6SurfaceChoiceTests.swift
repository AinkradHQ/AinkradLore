import XCTest

@testable import LoreFeature

/// E3T1: which surface a document opens in, and why line endings decide it.
///
/// A document whose line endings disagree cannot round-trip through CodeMirror
/// — it stores lines with one separator and there is nowhere to record which
/// line had which. Rather than rewrite the user's bytes, such a note opens in
/// the native editor, where the text storage IS the document.
///
/// The choice itself lives in a private SwiftUI view, so what is asserted here
/// is the RULE it consults. That is the part that decides correctness; a test
/// that drove the view would be testing SwiftUI.
final class CM6SurfaceChoiceTests: XCTestCase {

    func test_aConsistentDocumentCanUseCodeMirror() {
        XCTAssertTrue(CM6LineEndings.isConsistent("one\ntwo\nthree\n"))
        XCTAssertTrue(CM6LineEndings.isConsistent("one\r\ntwo\r\n"))
        XCTAssertTrue(CM6LineEndings.isConsistent("one\rtwo\r"))
        // Nothing to be inconsistent about.
        XCTAssertTrue(CM6LineEndings.isConsistent(""))
        XCTAssertTrue(CM6LineEndings.isConsistent("no newline at all"))
    }

    func test_aMixedDocumentMayNot() {
        XCTAssertFalse(CM6LineEndings.isConsistent("one\r\ntwo\n"))
        XCTAssertFalse(CM6LineEndings.isConsistent("a\r\nb\nc\rd\n"))
        XCTAssertFalse(CM6LineEndings.isConsistent("lf\ncr\r"))
    }

    /// The property that makes the whole arrangement safe: a document allowed
    /// onto the CM6 surface survives the trip unchanged, byte for byte.
    func test_everyDocumentAllowedOntoTheSurfaceRoundTripsExactly() {
        let documents = [
            "one\ntwo\nthree\n",
            "windows\r\nlines\r\nhere\r\n",
            "old\rmac\rlines\r",
            "no trailing newline",
            "",
            "unicode ✓ and emoji 🌍\nsecond line\n",
            "trailing blank lines\n\n\n",
        ]
        for document in documents {
            guard CM6LineEndings.isConsistent(document) else {
                XCTFail("\(document.debugDescription) should be consistent")
                continue
            }
            let ending = CM6LineEndings.dominant(in: document)
            // Exactly what the coordinator does: LF on the way in, the
            // document's own ending on the way out.
            let there = CM6LineEndings.toLF(document)
            let back = CM6LineEndings.from(there, to: ending)
            XCTAssertEqual(
                back, document,
                "\(document.debugDescription) did not survive the round trip")
        }
    }

    /// The two bugs the round-trip test above uncovered, pinned individually.
    ///
    /// `toLF` guarded on `text.contains("\r")`, which is FALSE for a pure-CRLF
    /// string because Swift treats `"\r\n"` as one grapheme cluster. So it
    /// returned Windows text unconverted while claiming to have converted it —
    /// and `from` then matched the `\n` inside each existing `\r\n` and emitted
    /// CR CR LF, a stray carriage return on every line. Each bug hid the other:
    /// the round trip only looked correct because CodeMirror happened to do the
    /// normalisation `toLF` was not doing.
    func test_toLFConvertsWindowsTextAtAll() {
        XCTAssertEqual(CM6LineEndings.toLF("windows\r\nlines\r\n"), "windows\nlines\n")
        XCTAssertEqual(CM6LineEndings.toLF("old\rmac\r"), "old\nmac\n")
        XCTAssertEqual(CM6LineEndings.toLF("already\nlf\n"), "already\nlf\n")
    }

    /// And `from` is idempotent, so text that already carries the target ending
    /// is not converted a second time.
    func test_fromDoesNotDoubleAnEndingItAlreadyHas() {
        let crlf = "a\r\nb\r\n"
        XCTAssertEqual(CM6LineEndings.from(crlf, to: .crlf), crlf)
        // The specific corruption: CR CR LF must never appear.
        XCTAssertFalse(
            Array(CM6LineEndings.from(crlf, to: .crlf).utf16)
                .indices.dropLast().contains { i in
                    let units = Array(CM6LineEndings.from(crlf, to: .crlf).utf16)
                    return units[i] == 0x0D && units[i + 1] == 0x0D
                }, "a stray carriage return on every line")
        XCTAssertEqual(CM6LineEndings.from("a\nb\n", to: .crlf), "a\r\nb\r\n")
        XCTAssertEqual(CM6LineEndings.from("a\rb\r", to: .cr), "a\rb\r")
        XCTAssertEqual(CM6LineEndings.from("a\r\nb\r\n", to: .lf), "a\nb\n")
    }

    /// And the converse, stated as a test so the reason for the rule is on
    /// record: a mixed document does NOT survive, which is why it is kept off
    /// this surface rather than fixed up on the way through.
    func test_aMixedDocumentIsExactlyWhatWouldNotSurvive() {
        let mixed = "windows\r\nunix\nmac\r"
        let ending = CM6LineEndings.dominant(in: mixed)
        let back = CM6LineEndings.from(CM6LineEndings.toLF(mixed), to: ending)
        XCTAssertNotEqual(
            back, mixed,
            "if this ever passes, the surface rule can be relaxed")
    }
}
