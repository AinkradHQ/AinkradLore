import XCTest
@testable import LoreFeature

/// The drag-and-drop rule.
///
/// Asserted directly rather than by dragging things in a running app — and
/// because this ONE rule is consulted by two readers (the drop highlight and
/// the move itself), every case here is also a guarantee that a folder cannot
/// light up as a valid target and then refuse the drop.
@MainActor
final class SidebarDropTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/vault")

    private func row(_ path: String) -> IndexRow {
        IndexRow(path: URL(fileURLWithPath: path), id: path, title: path,
                 tags: [], aliases: [], updated: Date(),
                 type: MarkdownEngine.identifier, properties: [])
    }

    // MARK: - Refusals

    func test_aMoveIntoAFolderInsideTheVaultIsAllowed() {
        XCTAssertNil(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/a.md"),
                                           into: URL(fileURLWithPath: "/tmp/vault/Notes"),
                                           root: root))
    }

    /// Refused rather than performed: the store would happily move the file,
    /// but its inbound links have no vault-relative path to be rewritten to,
    /// so every explicit-path link to it breaks and the file leaves the index.
    func test_aMoveOutsideTheVaultIsRefused() {
        XCTAssertEqual(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/a.md"),
                                             into: URL(fileURLWithPath: "/tmp/elsewhere"),
                                             root: root),
                       .outsideVault)
    }

    /// Not an error — just nothing to do — but it must not be PLANNED, because
    /// a move that changes nothing still raises a preview and a confirmation
    /// the user has no reason to read.
    func test_droppingIntoTheFolderItIsAlreadyInIsRefused() {
        XCTAssertEqual(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/Notes/a.md"),
                                             into: URL(fileURLWithPath: "/tmp/vault/Notes"),
                                             root: root),
                       .alreadyThere)
    }

    func test_withNoVaultEverythingIsRefused() {
        XCTAssertEqual(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/a.md"),
                                             into: URL(fileURLWithPath: "/tmp/vault/Notes"),
                                             root: nil),
                       .noVault)
    }

    func test_aFolderCannotBeDroppedIntoItsOwnDescendant() {
        XCTAssertEqual(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/Notes"),
                                             into: URL(fileURLWithPath: "/tmp/vault/Notes/Sub"),
                                             root: root),
                       .intoItself)
    }

    /// Containment is compared as path COMPONENTS, never as a string prefix.
    /// `/tmp/vault/Notes2` has `/tmp/vault/Notes` as a string prefix while
    /// being an unrelated sibling — a string test would refuse this legitimate
    /// move.
    func test_aSiblingWhoseNameSharesAPrefixIsNotADescendant() {
        XCTAssertNil(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/a.md"),
                                           into: URL(fileURLWithPath: "/tmp/vault/Notes2"),
                                           root: root))
    }

    /// The vault root itself is a legal destination — it is where the "move it
    /// back out of a folder" gesture lands.
    func test_theVaultRootIsALegalDestination() {
        XCTAssertNil(SidebarDrop.rejection(moving: URL(fileURLWithPath: "/tmp/vault/Notes/a.md"),
                                           into: root, root: root))
    }

    // MARK: - Resolving a dropped URL

    /// The drop type is `fileURL`, so anything at all can be dragged in. Only
    /// a URL that is already a document in this vault resolves — otherwise a
    /// file dragged from Finder would be treated as a move of a document Lore
    /// has never seen.
    func test_onlyKnownDocumentsResolve() {
        let rows = [row("/tmp/vault/a.md"), row("/tmp/vault/b.md")]
        XCTAssertEqual(SidebarDrop.row(for: URL(fileURLWithPath: "/tmp/vault/a.md"),
                                       in: rows)?.path.lastPathComponent, "a.md")
        XCTAssertNil(SidebarDrop.row(for: URL(fileURLWithPath: "/tmp/vault/stranger.md"),
                                     in: rows))
    }

    /// Every refusal produces a sentence naming what happened — a drop that
    /// silently does nothing is indistinguishable from a broken drag.
    func test_everyRejectionHasASentence() {
        let source = URL(fileURLWithPath: "/tmp/vault/a.md")
        let folder = URL(fileURLWithPath: "/tmp/elsewhere")
        for rejection: SidebarDrop.Rejection in [.noVault, .outsideVault,
                                                 .alreadyThere, .intoItself] {
            let sentence = SidebarDrop.describe(rejection, source: source, folder: folder)
            XCTAssertFalse(sentence.isEmpty, "\(rejection) has no explanation")
        }
    }
}
