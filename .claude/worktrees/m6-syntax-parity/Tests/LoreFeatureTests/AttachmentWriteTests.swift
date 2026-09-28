import XCTest
@testable import LoreFeature
import AinkradAppKit

/// `LoreStore.forTesting(vaultRoot:)` named in the Task 9 brief does not
/// exist. `LoreStoreTests.makeStore` is the real seam every other store test
/// already uses — `LoreStore(documents:indexPath:)` plus
/// `setVaultRootForTesting`, which bypasses the security-scoped bookmark a
/// real vault switch needs. Mirrored here rather than exported as a second
/// test constructor, per the brief's own instruction not to add one.
@MainActor
final class AttachmentWriteTests: XCTestCase {
    private func vault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-attach-\(UUID())")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        return dir
    }

    private func store(_ root: URL) throws -> LoreStore {
        let s = LoreStore(documents: FakeDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
        try s.setVaultRootForTesting(root)
        return s
    }

    func test_writesBesideTheNote() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("png-bytes".utf8), preferredName: "shot.png", besideNote: note)
        XCTAssertEqual(written.deletingLastPathComponent().lastPathComponent, "Notes")
        XCTAssertEqual(written.lastPathComponent, "shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func test_deduplicatesOnCollision() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let first = try s.writeAttachment(
            data: Data("a".utf8), preferredName: "shot.png", besideNote: note)
        let second = try s.writeAttachment(
            data: Data("b".utf8), preferredName: "shot.png", besideNote: note)
        XCTAssertEqual(first.lastPathComponent, "shot.png")
        XCTAssertEqual(second.lastPathComponent, "shot 2.png")
        // The first file must be untouched — never overwritten.
        XCTAssertEqual(try Data(contentsOf: first), Data("a".utf8))
    }

    func test_embedSyntaxUsesTheFilenameWithExtension() throws {
        let root = try vault()
        let s = try store(root)
        let url = root.appendingPathComponent("Notes/shot.png")
        XCTAssertEqual(s.embedSyntax(for: url), "![[shot.png]]")
    }

    func test_refusesToWriteOutsideTheVault() throws {
        let root = try vault()
        let s = try store(root)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("elsewhere/n.md")
        XCTAssertThrowsError(try s.writeAttachment(
            data: Data("x".utf8), preferredName: "shot.png", besideNote: outside))
    }

    /// A pasteboard/Finder-supplied name with traversal segments must not be
    /// able to climb out of the note's directory. Once `/` is stripped there
    /// is nothing left to traverse with — the whole string becomes one
    /// path component — so this must land INSIDE `Notes/`, not at
    /// `<root>/etc/passwd` or anywhere outside the vault.
    func test_sanitizesPathTraversalInPreferredName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "../../etc/passwd", besideNote: note)
        XCTAssertEqual(written.deletingLastPathComponent().standardizedFileURL.path,
                       note.deletingLastPathComponent().standardizedFileURL.path)
        XCTAssertFalse(written.path.contains("etc/passwd"))
    }

    /// A name that is nothing but dots must not become `.` or `..` — a real,
    /// dangerous path component — nor a hidden dotfile. `sanitized` falls
    /// back to a fixed placeholder name instead.
    func test_sanitizesDotsOnlyName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "....", besideNote: note)
        XCTAssertEqual(written.lastPathComponent, "attachment")
        XCTAssertEqual(written.deletingLastPathComponent().standardizedFileURL.path,
                       note.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// A dedupe test, not a guard test — renamed from an earlier version
    /// that claimed to test the overwrite guard while actually only
    /// exercising `nonCollidingURL`'s own scan (which had already moved the
    /// destination to `shot 2.png` before any write was attempted, so this
    /// passes identically with `.withoutOverwriting` removed). Kept because
    /// it is still a real, useful assertion about `writeAttachment`'s
    /// end-to-end behaviour; `test_writeGuardRefusesToOverwriteAnExisting
    /// File` below is what actually exercises the guard.
    func test_writeAttachmentDedupesRatherThanOverwriting() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let existing = root.appendingPathComponent("Notes/shot.png")
        try Data("original".utf8).write(to: existing)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("new".utf8), preferredName: "shot.png", besideNote: note)
        XCTAssertNotEqual(written.path, existing.path)
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
    }

    /// The actual overwrite guard, tested directly: `writeExactly` is the
    /// exact `Data.write(options: .withoutOverwriting)` call
    /// `writeAttachment` makes AFTER `nonCollidingURL` has already picked a
    /// destination — this is what has to fail loudly if that destination
    /// turns out to be occupied anyway (a write landing there in the window
    /// between the scan and the write). Calling it directly, past the dedup
    /// scan, is the only way to exercise the guard itself rather than the
    /// scan that USUALLY makes the guard unnecessary.
    func test_writeGuardRefusesToOverwriteAnExistingFile() throws {
        let root = try vault()
        let existing = root.appendingPathComponent("Notes/shot.png")
        try Data("original".utf8).write(to: existing)
        XCTAssertThrowsError(try LoreStore.writeExactly(Data("new".utf8), to: existing))
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
    }

    /// `]]` inside a pasted/dropped name must not be able to close the
    /// `![[…]]` embed early and leave trailing garbage in the document body.
    func test_sanitizesDoubleClosingBracketInPreferredName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "a]]b.png", besideNote: note)
        XCTAssertFalse(written.lastPathComponent.contains("]]"))
        XCTAssertFalse(s.embedSyntax(for: written).dropFirst(2).dropLast(2).contains("]]"))
    }

    /// `|` is `LinkResolver`'s alias syntax — unsanitized, `a|b.png` would
    /// make the embed resolve to an alias, not the file just written.
    func test_sanitizesPipeInPreferredName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "a|b.png", besideNote: note)
        XCTAssertFalse(written.lastPathComponent.contains("|"))
    }

    /// `#` is `LinkResolver`'s fragment syntax — unsanitized, `a#b.png`
    /// would make the embed resolve to a fragment, not the file just
    /// written.
    func test_sanitizesHashInPreferredName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "a#b.png", besideNote: note)
        XCTAssertFalse(written.lastPathComponent.contains("#"))
    }

    /// An INTERIOR newline (not just leading/trailing whitespace) must not
    /// survive into the filename: it would split the `![[…]]` token the
    /// embed becomes across two lines and break the markdown parse.
    func test_sanitizesInteriorNewlineInPreferredName() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: "a\nb.png", besideNote: note)
        XCTAssertFalse(written.lastPathComponent.contains("\n"))
    }

    /// Re-dropping a file that already sits beside this exact note (its own
    /// attachment, dragged again) must return the SAME file, not duplicate
    /// it as "shot 2.png".
    func test_copyingAFileAlreadyBesideTheNoteReturnsItUnchanged() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let existing = root.appendingPathComponent("Notes/shot.png")
        try Data("bytes".utf8).write(to: existing)
        let s = try store(root)
        let result = try s.writeAttachment(copying: existing, besideNote: note)
        XCTAssertEqual(result.path, existing.path)
        // No duplicate was created.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Notes/shot 2.png").path))
    }

    /// Fix round 2 / Important B: the same-file dedup early return above
    /// must NOT be a second path back into the Important-4 corruption it
    /// closed. A pre-existing in-vault file with an unsafe name (`]]`) —
    /// predating this feature, or dropped there by some other tool — must
    /// still produce a well-formed embed when re-dragged, never
    /// `![[a]]b.png]]`.
    func test_copyingAnInVaultFileWithUnsafeCharactersProducesAWellFormedEmbed() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let existing = root.appendingPathComponent("Notes/a]]b.png")
        try Data("bytes".utf8).write(to: existing)
        let s = try store(root)
        let result = try s.writeAttachment(copying: existing, besideNote: note)
        let embed = s.embedSyntax(for: result)
        // Well-formed: opens with `![[`, closes with exactly one `]]`, and
        // nothing in between contains a stray `]]` that would close the
        // token early.
        XCTAssertTrue(embed.hasPrefix("![["))
        XCTAssertTrue(embed.hasSuffix("]]"))
        let interior = embed.dropFirst(3).dropLast(2)
        XCTAssertFalse(interior.contains("]]"))
    }

    /// Whole-branch review Important 3: dropping a FOLDER must be rejected,
    /// not recursively copied. `FileManager.copyItem`'s "streams at the
    /// filesystem level" justification only holds for a single regular
    /// file — a directory has no size bound and `performDragOperation` runs
    /// synchronously on the main actor, so a brushed-in Finder folder would
    /// otherwise beachball the app for as long as the whole subtree takes to
    /// copy, and leave a permanently-unresolved `![[Folder]]` behind
    /// (directories are never indexed).
    func test_copyingADirectoryIsRejected() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let droppedFolder = root.appendingPathComponent("DroppedFolder")
        try FileManager.default.createDirectory(
            at: droppedFolder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(
            to: droppedFolder.appendingPathComponent("inside.txt"))
        let s = try store(root)

        XCTAssertThrowsError(
            try s.writeAttachment(copying: droppedFolder, besideNote: note)
        ) { error in
            guard case LoreError.notARegularFile(let url) = error else {
                return XCTFail("expected .notARegularFile, got \(error)")
            }
            XCTAssertEqual(url.path, droppedFolder.path)
        }
        // Nothing was copied into the vault beside the note.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Notes/DroppedFolder").path))
    }

    /// Round 3 / Important 4: the test above proves the STORE throws
    /// `.notARegularFile` — which already passed before round 2's
    /// `DocumentPane` change, so it never covered the actual round-2 fix.
    /// The round-2 fix was entirely in the VIEW layer: `DocumentPane` used
    /// to swallow this exact error in `try? … else { return nil }`, so a
    /// dropped folder did nothing with no explanation. `attemptAttachmentWrite`
    /// (`DocumentPane.swift`) is the pulled-out, SwiftUI-free seam that view
    /// layer now runs through — this calls it directly, the same way
    /// `writeDroppedFile` does, and asserts the failure actually surfaces as
    /// a message rather than being dropped. Also guards Important 3: the
    /// message must be human-readable, not
    /// `LoreFeature.LoreError error 8`.
    func test_droppingAFolderOnANoteSurfacesAReadableFailureNotSilence() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let droppedFolder = root.appendingPathComponent("DroppedFolder")
        try FileManager.default.createDirectory(
            at: droppedFolder, withIntermediateDirectories: true)
        let s = try store(root)

        let result = attemptAttachmentWrite(write: {
            try s.writeAttachment(copying: droppedFolder, besideNote: note)
        }, embedSyntax: { s.embedSyntax(for: $0) })

        XCTAssertNil(result.embedSyntax, "a rejected drop must insert nothing")
        let message = try XCTUnwrap(result.failureMessage, "the failure must surface a message")
        XCTAssertFalse(message.contains("LoreError"),
                       "the message must be human-readable, not the raw enum: \(message)")
        XCTAssertFalse(message.contains("couldn't be completed"),
                       "must not be the generic Foundation fallback: \(message)")
        XCTAssertTrue(message.contains("folder"),
                      "must actually explain WHY it was refused: \(message)")
    }

    /// Fix round 2 / Minor A: the length cap must be a BYTE budget, not a
    /// code-point budget — a 400-character CJK name still fits in 200 code
    /// points but, at 3 bytes/scalar, blows well past the 255-byte
    /// `NAME_MAX` a code-point cap left uncaught. Asserts the write
    /// actually succeeds (the regression was `ENAMETOOLONG`), not just that
    /// `sanitized` returns something.
    func test_sanitizedCapsANonASCIINameToAByteBudgetNotACodePointBudget() throws {
        let root = try vault()
        let note = root.appendingPathComponent("Notes/n.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let s = try store(root)
        let longCJKName = String(repeating: "日", count: 400) + ".png"
        let written = try s.writeAttachment(
            data: Data("x".utf8), preferredName: longCJKName, besideNote: note)
        XCTAssertLessThanOrEqual(written.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }
}
