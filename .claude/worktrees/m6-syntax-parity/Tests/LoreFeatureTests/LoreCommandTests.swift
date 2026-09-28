import XCTest
@testable import LoreFeature

/// The command catalog's rules.
///
/// The collision test is the whole reason the registry exists as data: with
/// shortcuts scattered as hidden `Button` overlays at their points of use,
/// nothing could see two of them at once, so nothing could notice that two
/// had claimed the same key. Discovering that by pressing it is a bad way to
/// find out — SwiftUI picks one arbitrarily and the other command becomes
/// silently unreachable.
@MainActor
final class LoreCommandTests: XCTestCase {

    private let everything = LoreCommands.Context(hasVault: true, hasDocument: true,
                                                  canUndoDelete: true)

    // MARK: - Catalog integrity

    /// No two commands may claim the same key equivalent.
    func test_noTwoCommandsShareAShortcut() {
        var seen: [String: String] = [:]
        for command in LoreCommands.all {
            guard let shortcut = command.shortcut else { continue }
            let key = shortcut.display
            if let existing = seen[key] {
                XCTFail("\(key) is claimed by both “\(existing)” and “\(command.title)”")
            }
            seen[key] = command.title
        }
    }

    /// Every command is reachable and nameable: a blank title would render as
    /// an empty palette row that does something when pressed.
    func test_everyCommandHasATitleAndAnIcon() {
        for command in LoreCommands.all {
            XCTAssertFalse(command.title.isEmpty, "\(command.id) has no title")
            XCTAssertFalse(command.systemName.isEmpty, "\(command.id) has no icon")
        }
    }

    /// Every case of the ID enum appears exactly once in the catalog. Guards
    /// the two failure modes of a hand-maintained list: a command declared
    /// twice (whichever entry loses is unreachable) and one never declared at
    /// all (an ID nothing can run).
    func test_theCatalogCoversEveryIDExactlyOnce() {
        let ids = LoreCommands.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a command is declared twice")
        XCTAssertEqual(Set(ids), Set(LoreCommand.ID.allCases),
                       "a declared ID has no catalog entry, or vice versa")
    }

    /// The display string is the one the binding is derived from, so a
    /// cheat-sheet built off it cannot drift from the key that actually works.
    func test_shortcutDisplayRendersModifiersInOrder() {
        XCTAssertEqual(LoreShortcut("k").display, "⌘K")
        XCTAssertEqual(LoreShortcut("o", shift: true).display, "⇧⌘O")
        XCTAssertEqual(LoreShortcut("p", shift: true, option: true).display, "⌥⇧⌘P")
    }

    // MARK: - Availability

    /// A command that cannot run is ABSENT, not present and dead — and this is
    /// load-bearing beyond tidiness: `LoreCommandShortcuts` mounts a binding
    /// only for available commands, so availability is what stops ⌘Z from
    /// being claimed when there is nothing to undo (and therefore stops it
    /// stealing undo from the text editor).
    func test_undoIsUnavailableWithNothingToUndo() {
        let context = LoreCommands.Context(hasVault: true, hasDocument: true,
                                           canUndoDelete: false)
        XCTAssertFalse(LoreCommands.available(in: context).contains { $0.id == .undoDelete })
        XCTAssertTrue(LoreCommands.available(in: everything).contains { $0.id == .undoDelete })
    }

    /// With no vault, only the commands that can genuinely run are offered —
    /// notably "Choose Vault…", which is the one way OUT of that state.
    func test_withNoVaultOnlyAlwaysCommandsAreOffered() {
        let available = LoreCommands.available(in: .empty)
        XCTAssertTrue(available.contains { $0.id == .chooseVault },
                      "the first-run state must still offer the way out of it")
        XCTAssertFalse(available.contains { $0.id == .newNote },
                       "a create that cannot succeed must not be offered")
        XCTAssertFalse(available.contains { $0.id == .rebuildIndex })
    }

    /// Document commands need a document.
    func test_documentCommandsRequireAnOpenDocument() {
        let noDoc = LoreCommands.Context(hasVault: true, hasDocument: false,
                                         canUndoDelete: false)
        for id in [LoreCommand.ID.saveNow, .closeDocument, .toggleOutline, .toggleBacklinks] {
            XCTAssertFalse(LoreCommands.available(in: noDoc).contains { $0.id == id },
                           "\(id) must not be offered with no document open")
        }
    }

    // MARK: - Ranking

    /// A prefix match outranks a mid-string one, so Return does the obvious
    /// thing rather than whatever was declared first.
    func test_prefixMatchesRankAboveSubstringMatches() {
        // "re" prefixes "Rebuild Index" and appears mid-string in "Find and
        // Replace…", which is declared EARLIER in the catalog — so this only
        // passes if match position outranks declaration order.
        let matches = LoreCommands.matching("re", in: everything)
        XCTAssertEqual(matches.first?.id, .rebuildIndex,
                       "a prefix match must beat a mid-string one")
        XCTAssertTrue(matches.contains { $0.id == .replaceInDocument },
                      "the substring match must still be offered, just lower")
    }

    /// Ties break on CATALOG order, not alphabetically. "New Note" and "New
    /// Folder…" both prefix-match "n"; sorting the tie by title would put
    /// Folder first purely because F precedes N, which is meaningless to the
    /// person typing. This test caught exactly that.
    func test_tiesBreakOnCuratedOrderNotTheAlphabet() {
        XCTAssertEqual(LoreCommands.matching("n", in: everything).first?.id, .newNote,
                       "typing “n” must reach New Note, not New Folder")
    }

    func test_anEmptyQueryReturnsEverythingAvailable() {
        XCTAssertEqual(LoreCommands.matching("  ", in: everything).count,
                       LoreCommands.available(in: everything).count)
    }

    /// Matching never offers an unavailable command, however well it matches.
    func test_matchingRespectsAvailability() {
        XCTAssertFalse(LoreCommands.matching("undo", in: .empty).contains { $0.id == .undoDelete })
    }
}
