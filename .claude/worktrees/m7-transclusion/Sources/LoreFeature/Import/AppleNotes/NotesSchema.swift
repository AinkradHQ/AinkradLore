import Foundation
import GRDB

/// Checks that Apple's store looks the way the reader assumes before the
/// reader assumes it.
///
/// This is what makes the AppleScript fallback meaningful rather than
/// decorative. `ZICNOTEDATA` and `ZICCLOUDSYNCINGOBJECT` are undocumented
/// internal Core Data tables that Apple is free to change in any OS update.
/// Without this check, a renamed column produces garbage items — notes with
/// empty bodies, or titles read from the wrong field — and the fallback never
/// triggers, because nothing ever reported a problem. An honest
/// `.unsupported` is what routes the run to a path that still works.
public enum NotesSchema {
    public enum Support: Sendable, Equatable {
        case supported
        case unsupported(missing: [String])
    }

    /// Every table and column the reader dereferences, in one place so the
    /// check cannot drift from what `AppleNotesSource` actually reads. A
    /// column added to a query and not added here is a column the fallback
    /// will not protect.
    static let required: [String: [String]] = [
        "ZICNOTEDATA": ["ZNOTE", "ZDATA"],
        "ZICCLOUDSYNCINGOBJECT": ["Z_PK", "ZTITLE1", "ZIDENTIFIER", "ZFOLDER",
                                  "ZCREATIONDATE1", "ZMODIFICATIONDATE1",
                                  "ZMARKEDFORDELETION"],
    ]

    public static func check(_ queue: DatabaseQueue) throws -> Support {
        var missing: [String] = []
        try queue.read { db in
            // Sorted so the reported list is deterministic — a diagnostic that
            // reorders itself between runs is a diagnostic nobody can diff.
            for (table, columns) in required.sorted(by: { $0.key < $1.key }) {
                guard try db.tableExists(table) else {
                    // The whole table is missing: report it once rather than
                    // listing every column of a table that is not there.
                    missing.append(table)
                    continue
                }
                let present = Set(try db.columns(in: table).map(\.name))
                for column in columns.sorted() where !present.contains(column) {
                    missing.append("\(table).\(column)")
                }
            }
        }
        return missing.isEmpty ? .supported : .unsupported(missing: missing)
    }
}
