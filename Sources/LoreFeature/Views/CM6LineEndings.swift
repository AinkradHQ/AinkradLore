import Foundation

/// Line endings across the CodeMirror boundary.
///
/// ## The defect this exists for
///
/// CodeMirror's document model stores lines with ONE separator and normalises
/// on input. Measured, not assumed:
///
///     in "one\r\ntwo\n"    out "one\ntwo\n"
///     in "one\rtwo\n"      out "one\ntwo\n"
///     in "a\r\nb\nc\rd\n"  out "a\nb\nc\nd\n"
///
/// So handing a CRLF document to CM6 and taking it back rewrites every line
/// ending in the file. On a Windows-authored or imported note that is a
/// whole-file diff on open, before the reader has typed anything — and it would
/// have shipped invisibly, because nothing in the editor LOOKS different.
///
/// This codebase already takes line endings seriously: `MarkdownReveal.blocks`
/// counts terminators rather than characters, and `SourceOffsetMap` documents
/// CRLF as one terminator and two UTF-16 units. Losing them at the editor
/// boundary would undo that care.
///
/// ## The trade, stated plainly
///
/// A document with CONSISTENT endings round-trips exactly: the ending is
/// recorded on the way in and restored on the way out.
///
/// A document with MIXED endings cannot round-trip — CM6 has one separator and
/// there is nowhere to record which line had which.
///
/// So such a document never reaches this surface. `MarkdownDocumentEditor
/// .chooseSurface(for:)` opens it in the NATIVE editor instead, where the text
/// storage is the document character for character and every byte survives.
/// `isConsistent` exists for that decision; the normalisation below is the
/// fallback for a document that somehow arrives here anyway, and it logs when
/// it fires.
///
/// This replaced an earlier answer — normalise to the dominant ending and
/// declare it — which was rejected on the grounds that changing the user's
/// bytes before they have typed anything is the one thing this editor may never
/// do, whether or not it is declared. Refusing to open the note was rejected
/// too. Sending it to the editor that can hold it costs the reader only the
/// affordances CM6 adds, on a file that is almost always mixed by accident.
enum CM6LineEndings {

    enum Ending: String {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    /// The ending a document should be written back with: whichever it uses
    /// most. Ties and empty documents answer `.lf`, which is what a new note
    /// gets and what every Obsidian vault uses.
    static func dominant(in text: String) -> Ending {
        let units = Array(text.utf16)
        var crlf = 0
        var lf = 0
        var cr = 0
        var index = 0
        while index < units.count {
            if units[index] == 0x0D {
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    crlf += 1
                    index += 2
                } else {
                    cr += 1
                    index += 1
                }
            } else {
                if units[index] == 0x0A { lf += 1 }
                index += 1
            }
        }
        if crlf > lf, crlf >= cr { return .crlf }
        if cr > lf, cr > crlf { return .cr }
        return .lf
    }

    /// Whether every terminator in `text` is the same — i.e. whether the round
    /// trip is lossless. `false` means opening this note WILL change its bytes.
    static func isConsistent(_ text: String) -> Bool {
        let units = Array(text.utf16)
        var seen: Set<Ending> = []
        var index = 0
        while index < units.count {
            if units[index] == 0x0D {
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    seen.insert(.crlf)
                    index += 2
                } else {
                    seen.insert(.cr)
                    index += 1
                }
            } else {
                if units[index] == 0x0A { seen.insert(.lf) }
                index += 1
            }
        }
        return seen.count <= 1
    }

    /// To what CodeMirror will hold anyway, done deliberately in Swift so the
    /// conversion is one function with tests rather than a side effect of a
    /// third-party document model.
    ///
    /// The guard is on UTF-16 units, not on Characters. It was
    /// `text.contains("\r")`, and that is FALSE for a pure-CRLF document:
    /// Swift treats `"\r\n"` as a single grapheme cluster, which does not equal
    /// `Character("\r")`. So the whole function short-circuited and returned
    /// Windows text unconverted, while claiming in its own name to have
    /// converted it. Measured:
    ///
    ///     "windows\r\nlines\r\n".contains("\r")  ->  false
    ///     .count 14, .utf16.count 16
    static func toLF(_ text: String) -> String {
        guard text.utf16.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Back to the document's own ending.
    ///
    /// IDEMPOTENT, deliberately: `toLF` is applied first, so text that already
    /// carries the target ending is returned unchanged rather than converted
    /// twice. Without it, `from("a\r\nb", to: .crlf)` replaced the `\n` inside
    /// each existing `\r\n` and produced `0D 0D 0A` — CR CR LF, a stray
    /// carriage return on every line of a Windows note. It reached that state
    /// only because `toLF` above was silently doing nothing, so one bug hid the
    /// other; both are fixed here rather than one, because either alone leaves
    /// a function that corrupts text when called the obvious way.
    static func from(_ text: String, to ending: Ending) -> String {
        let lf = toLF(text)
        switch ending {
        case .lf: return lf
        case .crlf: return lf.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return lf.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}
