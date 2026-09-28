import XCTest
import SwiftUI
@testable import LoreFeature
import AinkradAppKit

/// Lore's basic mode: one document, rendered and editable.
@MainActor
final class LoreBasicModeTests: XCTestCase {

    private func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-basic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(at root: URL) throws -> LoreStore {
        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)
        return store
    }

    func test_loreOptsIntoModes() {
        // The host never asks whether an app has a basic mode; it casts. Drop
        // the conformance and Lore silently becomes advanced-only, with the
        // deep links from Hoard and Rune landing in the full vault browser.
        XCTAssertNotNil((LoreApp.self as Any) as? AinkradAppModes.Type)
    }

    func test_basicView_buildsWithNoDocumentOpen() throws {
        // The state a deep link has not arrived in yet. It must offer a way
        // out rather than render an inert blank pane.
        let root = try tempVault()
        _ = LoreBasicView(store: try makeStore(at: root), theme: HostTheme(TestTokens.make()),
                          launcher: StubLauncher()).body
    }

    func test_basicView_showsTheOpenDocument() throws {
        let root = try tempVault()
        try "---\nid: a\ntitle: A\n---\nbody".write(
            to: root.appendingPathComponent("roadmap.md"), atomically: true, encoding: .utf8)
        let store = try makeStore(at: root)
        store.open(url: root.appendingPathComponent("roadmap.md"))

        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "roadmap.md")
        _ = LoreBasicView(store: store, theme: HostTheme(TestTokens.make()),
                          launcher: StubLauncher()).body
    }

    func test_openingByURLNeedsNoIndexQuery() throws {
        // The property E5 depends on, and the reason it survives the index
        // being replaced next milestone: a deep link opens a document by PATH.
        // `store.open(url:)` goes straight to `DocumentSession.open`, so
        // landing on a file never needs the vault to have been indexed.
        let root = try tempVault()
        let file = root.appendingPathComponent("never-indexed.md")
        try "# fresh".write(to: file, atomically: true, encoding: .utf8)

        let store = try makeStore(at: root)
        store.open(url: file)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNil(store.openError)
        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "never-indexed.md")
    }

    func test_openingTheSameFileTwiceReusesOneSession() throws {
        // Clicking the same `.md` twice in Hoard must not produce two sessions
        // on one file, each with its own mtime baseline and its own debounced
        // autosave racing the other.
        let root = try tempVault()
        let file = root.appendingPathComponent("twice.md")
        try "# x".write(to: file, atomically: true, encoding: .utf8)

        let store = try makeStore(at: root)
        store.open(url: file)
        store.open(url: file)

        XCTAssertEqual(store.tabs.count, 1)
    }

    func test_modelessEntryPointStillMeansAdvanced() throws {
        // A generation-10 host calls this one; moving the pin must not change
        // what an un-updated host renders.
        let root = try tempVault()
        _ = LoreRootView(store: try makeStore(at: root), theme: HostTheme(TestTokens.make()))
    }
}

@MainActor
private final class StubLauncher: PluginAppLauncher {
    var pending: String?
    private(set) var takeCount = 0
    func open(appID: String, payload: String?) {}
    func takePendingLaunch() -> String? {
        takeCount += 1
        defer { pending = nil }
        return pending
    }
}

/// Collecting a document handed over by Hoard or Rune.
@MainActor
final class LoreLaunchIntentTests: XCTestCase {

    private func tempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_anOpenDocumentIntentOpensThatFile() throws {
        let root = try tempVault()
        let file = root.appendingPathComponent("handed-over.md")
        try "# from Hoard".write(to: file, atomically: true, encoding: .utf8)

        let store = LoreStore(documents: FakeDocs(),
                              indexPath: root.appendingPathComponent(".idx.sqlite"))
        try store.setVaultRootForTesting(root)

        let intent = AinkradLaunchIntent(path: file.path, mode: .basic)
        let decoded = try XCTUnwrap(AinkradLaunchIntent.decode(intent.json))
        XCTAssertTrue(decoded.isOpenDocument)
        store.open(url: URL(fileURLWithPath: decoded.path))

        XCTAssertEqual(store.selectedTab?.url.lastPathComponent, "handed-over.md")
        XCTAssertNil(store.openError)
    }

    func test_aForeignPayloadIsIgnoredRatherThanTreatedAsAnError() {
        // Leyline sends SSH launches down the same channel. "Not mine" must not
        // become "something went wrong", or one app launch breaks another.
        let ssh = #"{"host":"example.com","port":22,"username":"a","identityFile":"/k"}"#
        XCTAssertNil(AinkradLaunchIntent.decode(ssh))
    }

    func test_noPendingLaunchOpensNothing() {
        // The ordinary case: opening Lore in basic with nothing handed over
        // must not invent a document.
        XCTAssertNil(AinkradLaunchIntent.decode(nil))
    }
}
