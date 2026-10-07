import AppKit
import SwiftUI
import XCTest

@testable import LoreFeature

/// Fix round 2, NEW-2: `VaultIndexCoordinator.cachedResolver` is the entire
/// correctness basis of the Critical-3 fix (one resolver build per vault
/// change instead of one per embed per render), and its invalidation rests
/// on a single `didSet` on `rows`. That `didSet` is correct today only
/// because every index-write path happens to reassign `rows`; nothing
/// enforced it. These tests are that enforcement — each obtains a resolver
/// FIRST (populating the cache), then writes to the index, then asserts the
/// new document resolves. Against a cache that never invalidated, each
/// would fail.
@MainActor
final class ResolverCacheInvalidationTests: XCTestCase {

    private func store() throws -> (URL, LoreStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-resolvercache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LoreStore(
            documents: FakeDocs(),
            indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return (root, store)
    }

    /// The `indexDocument` path — a note saved or created through the store.
    func test_indexingANewDocumentInvalidatesTheCachedResolver() throws {
        let (_, store) = try store()
        // Populate the cache BEFORE the write. Without this the test proves
        // nothing: a cold cache builds a fresh resolver anyway.
        XCTAssertNil(store.resolveLink("Later"), "precondition: nothing named Later yet")

        let note = try store.create(title: "Later")
        XCTAssertEqual(
            store.resolveLink("Later"), note.path,
            "indexDocument must invalidate the cached resolver, "
                + "or every link created this session resolves to nothing")
    }

    /// The `rebuild()` path — a whole-vault rescan, e.g. after an external
    /// change the folder watcher noticed.
    func test_rebuildInvalidatesTheCachedResolver() throws {
        let (root, store) = try store()
        XCTAssertNil(store.resolveLink("Outside"), "precondition: nothing named Outside yet")

        // Written directly to disk, behind the store's back, exactly as an
        // external editor would — so ONLY `rebuild()` can make it known.
        let external = root.appendingPathComponent("outside.md")
        try "---\ntitle: Outside\n---\n\nbody\n".write(
            to: external, atomically: true,
            encoding: .utf8)
        try store.rebuild()

        XCTAssertEqual(
            store.resolveLink("Outside")?.lastPathComponent, "outside.md",
            "rebuild must invalidate the cached resolver")
    }

    /// The cache must still be doing its job — the same resolver instance is
    /// reused across calls when nothing changed. Asserted through behaviour
    /// rather than by reaching into the private property: two consecutive
    /// resolutions with no intervening write must agree.
    func test_theCachedResolverIsStableWhileTheVaultIsUnchanged() throws {
        let (_, store) = try store()
        let note = try store.create(title: "Stable")
        XCTAssertEqual(store.resolveLink("Stable"), note.path)
        XCTAssertEqual(store.resolveLink("Stable"), note.path)
    }
}

/// Fix round 2, I6 and NEW-3: an embed's reveal is a SPAN-level property, and
/// the caret path has to notice it without a block flip.
@MainActor
final class EmbedRevealTests: XCTestCase {

    private func makeEditor(_ text: String, resolve: @escaping @MainActor (String) -> URL?)
        -> (MarkdownEditor.Coordinator, LinkTextView)
    {
        var stored = text
        let binding = Binding<String>(get: { stored }, set: { stored = $0 })
        let coordinator = MarkdownEditor.Coordinator(text: binding, tokens: TestTokens.make())
        coordinator.resolveEmbedTarget = resolve
        let tv = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.delegate = coordinator
        tv.string = text
        coordinator.textView = tv
        coordinator.applyStyles()
        return (coordinator, tv)
    }

    /// NEW-3: a caret parked immediately after `]]`, or immediately before
    /// `!`, must NOT suppress the embed — those are the ordinary resting
    /// positions after typing an embed or before typing in front of one, and
    /// the inclusive-touch rule made the image vanish at exactly the moment
    /// the user was looking at it.
    func test_caretAtEitherBoundaryDoesNotRevealTheEmbed() {
        let embed = NSRange(location: 10, length: 16)  // e.g. "![[diagram.png]]"
        let justBefore = NSRange(location: 10, length: 0)
        let justAfter = NSRange(location: 26, length: 0)
        XCTAssertFalse(MarkdownEditor.Coordinator.isEmbedRevealed(embed, selection: justBefore))
        XCTAssertFalse(MarkdownEditor.Coordinator.isEmbedRevealed(embed, selection: justAfter))
    }

    /// The other half of the same rule: a caret genuinely INSIDE the source
    /// — which is when the user is editing the target — does reveal.
    func test_caretInsideTheEmbedRevealsIt() {
        let embed = NSRange(location: 10, length: 16)
        XCTAssertTrue(
            MarkdownEditor.Coordinator.isEmbedRevealed(
                embed, selection: NSRange(location: 15, length: 0)))
        XCTAssertTrue(
            MarkdownEditor.Coordinator.isEmbedRevealed(
                embed, selection: NSRange(location: 12, length: 4)))
    }

    /// I6, the finding that mattered: moving the caret INTO an embed's range
    /// from elsewhere in the SAME block is not a block flip, so
    /// `revealForSelectionChange`'s block-level early return used to skip it
    /// entirely — the image stayed collapsed and drawn with the caret
    /// invisibly inside it. The embed must un-render on that move alone, with
    /// no keystroke and no debounce.
    func test_movingTheCaretIntoAnEmbedRevealsItWithoutABlockFlip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: imageURL)

        // ONE block: the embed and the caret's starting position share a
        // paragraph, so nothing below can be explained by a block flip.
        let text = "![[diagram.png]]\nTrailing line.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            // Start at offset 0 — the embed's own line, but OUTSIDE its span,
            // which `currentlyRevealedEmbedSpans` tests by strict overlap.
            //
            // The caret used to start at the end of the document, one line
            // down. That was a valid "no block flip" then and is not now: the
            // reveal unit is the LINE, so crossing to another line flips it and
            // the move would go through the ordinary path, leaving I6
            // unexercised. Staying on one line keeps the reveal range fixed
            // while the EMBED's reveal changes, which is exactly the shape this
            // test exists for.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.applyStyles()
            XCTAssertEqual(
                tv.embedImages.count, 1,
                "precondition: the embed renders while the caret is outside it")
            let revealedBefore = coordinator.revealedRange

            // Move INTO the embed's own range. No text change, no keystroke.
            tv.setSelectedRange(NSRange(location: 5, length: 0))
            coordinator.revealForSelectionChange()

            XCTAssertEqual(
                coordinator.revealedRange, revealedBefore,
                "precondition: this move must not flip the revealed range, "
                    + "or the test is not exercising I6")
            XCTAssertTrue(
                tv.embedImages.isEmpty,
                "an embed whose range the caret entered must un-render "
                    + "immediately, not wait for a keystroke or the debounce")
        }
    }

    /// And back out again: leaving the embed's range re-renders it, likewise
    /// with no block flip and no keystroke.
    func test_movingTheCaretOutOfAnEmbedRerendersIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("diagram.png")
        try EmbedOffsetSafetyTests.onePixelPNG().write(to: imageURL)

        let text = "![[diagram.png]]\nTrailing line.\n"
        let (coordinator, tv) = makeEditor(text) { _ in imageURL }
        withExtendedLifetime(coordinator) {
            tv.setSelectedRange(NSRange(location: 5, length: 0))
            coordinator.applyStyles()
            XCTAssertTrue(tv.embedImages.isEmpty, "precondition: revealed while inside")

            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.revealForSelectionChange()
            XCTAssertEqual(
                tv.embedImages.count, 1,
                "leaving the embed's range must restore its rendering")
        }
    }
}
