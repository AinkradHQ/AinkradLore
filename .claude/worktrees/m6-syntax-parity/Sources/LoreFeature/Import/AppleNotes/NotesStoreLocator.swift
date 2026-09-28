import Foundation

/// Finds Apple's Notes database and, more importantly, says WHY it cannot be
/// read when it cannot.
///
/// Verified empirically on 2026-08-09: `ls ~/Library/Group
/// Containers/group.com.apple.notes` returns `Operation not permitted`. The
/// entire container is TCC-protected, not merely the database inside it — so
/// the failure arrives as an unlistable directory, not a permissions error on
/// a file.
///
/// Both grants this milestone needs attach to the HOST app, not to Lore: a
/// plugin bundle cannot hold its own TCC grants. Development grants go to
/// `com.ainkrad.devhost`, release grants to `com.ainkrad.app`.
public enum NotesStoreLocator {
    public enum Availability: Sendable, Equatable {
        case available(URL)
        case permissionDenied
        case notPresent
    }

    static let containerPath = "Library/Group Containers/group.com.apple.notes"
    static let storeName = "NoteStore.sqlite"

    /// Distinguishes "no Notes data" from "Notes data we are not allowed to
    /// see".
    ///
    /// The difference is the whole point of this type. `.notPresent` is a dead
    /// end; `.permissionDenied` is something the user can fix in System
    /// Settings in about fifteen seconds. Conflating them shows the wrong
    /// message for the case that is actually recoverable — and since the
    /// recoverable case is the one almost every user will hit, that is the
    /// message that matters.
    ///
    /// `home` is a parameter so tests can point at a temp directory. A test
    /// must never probe the user's real Notes container.
    public static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Availability
    {
        let container = home.appendingPathComponent(containerPath)
        guard FileManager.default.fileExists(atPath: container.path) else {
            return .notPresent
        }
        // A readable container lists; a TCC-denied one throws EPERM. This is
        // the exact shape the real denial takes — hence testing listability
        // rather than the store file's own readability, which under TCC we
        // cannot even get far enough to ask about.
        guard (try? FileManager.default.contentsOfDirectory(atPath: container.path)) != nil
        else { return .permissionDenied }

        let store = container.appendingPathComponent(storeName)
        guard FileManager.default.isReadableFile(atPath: store.path) else {
            return .notPresent
        }
        return .available(store)
    }
}
