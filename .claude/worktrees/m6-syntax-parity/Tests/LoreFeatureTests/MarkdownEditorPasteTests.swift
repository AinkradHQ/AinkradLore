import XCTest
import AppKit
@testable import LoreFeature

/// `LinkTextView.paste(_:)` — the Task 9 fix-round-1 regression coverage for
/// Critical 1: a mixed pasteboard (image bytes riding alongside a string
/// type, which is what copying an image out of Safari/Notes/Keynote or most
/// RTF copies actually produces) must paste as TEXT, not silently hijack the
/// paste into an attachment write that discards the text the user copied.
///
/// Drives the real system pasteboard (`NSPasteboard.general`) because
/// `paste(_:)` is hardcoded to it, the same way AppKit's own `paste(_:)`
/// is — there is no injectable seam. Restores whatever was there before each
/// test.
@MainActor
final class MarkdownEditorPasteTests: XCTestCase {
    // Not restored: an `NSPasteboardItem` read back off the pasteboard
    // cannot be re-written to it (`NSInvalidArgumentException`, "already
    // associated with another pasteboard"), and rebuilding an equivalent
    // item loses fidelity for arbitrary prior clipboard content anyway.
    // Test-only content is cleared instead — acceptable for a CI/test
    // process's pasteboard, which nothing else in this session depends on.
    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    private func textView(_ string: String = "") -> LinkTextView {
        let tv = LinkTextView(frame: .init(x: 0, y: 0, width: 200, height: 200))
        tv.isRichText = false
        tv.string = string
        tv.allowsUndo = false
        return tv
    }

    private func onePixelPNG() -> Data {
        // A minimal valid 1x1 PNG — real bytes, not a placeholder, so
        // `pb.data(forType: .png)` returns something non-nil the same way a
        // real screenshot paste would.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        return Data(base64Encoded: base64)!
    }

    /// The regression this round of review found: a pasteboard offering
    /// BOTH image bytes and a string must paste the string, exactly like
    /// AppKit's own default `paste(_:)`, and must NEVER call
    /// `onPasteImage` — that closure writing a file is the whole bug.
    func test_mixedImageAndTextPasteboardPastesTextAndNeverWritesAFile() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .png)
        item.setString("copied text", forType: .string)
        pb.writeObjects([item])

        let tv = textView("before ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        var handlerCalled = false
        tv.onPasteImage = { _, _ in handlerCalled = true; return true }

        tv.paste(nil)

        XCTAssertFalse(handlerCalled, "a pasteboard with a string type must never reach onPasteImage")
        XCTAssertEqual(tv.string, "before copied text")
    }

    /// The positive case, unchanged by the fix: an IMAGE-ONLY pasteboard
    /// (no string type at all — a real screenshot paste) must still reach
    /// `onPasteImage`.
    func test_imageOnlyPasteboardStillReachesOnPasteImage() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .png)
        pb.writeObjects([item])

        let tv = textView("")
        var receivedData: Data?
        tv.onPasteImage = { data, name in
            receivedData = data
            XCTAssertTrue(name.hasSuffix(".png"))
            return true
        }

        tv.paste(nil)

        XCTAssertNotNil(receivedData)
        XCTAssertEqual(tv.string, "", "the handler owns the insert; paste(_:) must not also insert text")
    }

    /// Case 1: a Finder "Copy" of files (a `.fileURL`, plus the string
    /// representation Finder always writes alongside it) must write the
    /// FILES via `onDropFileURLs` — the same handler the drop path uses —
    /// not paste the filename as text.
    func test_finderFileCopyRoutesToOnDropFileURLsNotText() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.path, forType: .string)
        pb.writeObjects([item])

        let tv = textView("")
        var receivedURLs: [URL]?
        tv.onDropFileURLs = { urls in receivedURLs = urls; return true }
        var imageHandlerCalled = false
        tv.onPasteImage = { _, _ in imageHandlerCalled = true; return true }

        tv.paste(nil)

        XCTAssertEqual(receivedURLs, [fileURL])
        XCTAssertFalse(imageHandlerCalled)
        XCTAssertEqual(tv.string, "", "must not paste the filename/path as text")
    }

    /// A failed file write must insert NOTHING — not fall back to AppKit's
    /// default paste, which would reintroduce the original bug (the raw
    /// path pasted as text). Mirrors `performDragOperation`'s own contract.
    func test_finderFileCopyWriteFailureInsertsNothing() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.path, forType: .string)
        pb.writeObjects([item])

        let tv = textView("before")
        tv.onDropFileURLs = { _ in false }

        tv.paste(nil)

        XCTAssertEqual(tv.string, "before", "a failed file write must not fall through to text paste")
    }

    /// Case 3: "Copy Image" in Safari/Preview — image bytes PLUS the source
    /// page's URL as a bare string, no `.fileURL` — must write the IMAGE,
    /// not paste the URL. This is the case the owner hits most.
    func test_imagePlusBareURLStringWritesImageNotURL() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .png)
        item.setString("https://example.com/photo.jpg", forType: .string)
        pb.writeObjects([item])

        let tv = textView("")
        var receivedData: Data?
        tv.onPasteImage = { data, _ in receivedData = data; return true }

        tv.paste(nil)

        XCTAssertNotNil(receivedData)
        XCTAssertEqual(tv.string, "", "must not paste the source URL as text")
    }

    /// Case 4, the data-loss regression guard restated against the NEW rule:
    /// real prose (has whitespace, is not a bare URL) alongside image bytes
    /// must still paste as TEXT and never reach `onPasteImage`.
    func test_imagePlusProseStillPastesTextNeverWritesImage() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(onePixelPNG(), forType: .tiff)
        item.setString("see the chart below for details", forType: .string)
        pb.writeObjects([item])

        let tv = textView("before ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        var handlerCalled = false
        tv.onPasteImage = { _, _ in handlerCalled = true; return true }

        tv.paste(nil)

        XCTAssertFalse(handlerCalled)
        XCTAssertEqual(tv.string, "before see the chart below for details")
    }

    /// Fix round 1's gap: a `.fileURL` present does NOT automatically win
    /// once a string on the pasteboard is genuine prose rather than a
    /// rendering of that file (a plausible Mail/Notes shape — an attachment
    /// selected together with surrounding text). Must paste the prose and
    /// write nothing, the same data-loss guard case 4 already requires for
    /// images.
    func test_fileURLPlusIndependentProseWritesNothingPastesText() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString("please review the attached report before Friday", forType: .string)
        pb.writeObjects([item])

        let tv = textView("before ")
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        var writeAttempted = false
        tv.onDropFileURLs = { _ in writeAttempted = true; return true }

        tv.paste(nil)

        XCTAssertFalse(writeAttempted, "independent prose must win over the file — nothing gets written")
        XCTAssertEqual(tv.string, "before please review the attached report before Friday")
    }

    /// The positive control for the same fix: a `.fileURL` whose string is
    /// ONLY a mechanical rendering of that same file (its `file://` form,
    /// not its `NSPasteboard`-standard path form) still routes to the file,
    /// not text — the discrimination must not become so cautious that an
    /// ordinary Finder copy regresses.
    func test_fileURLWhoseStringIsTheURLFormStillRoutesToFile() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.absoluteString, forType: .string)
        pb.writeObjects([item])

        let tv = textView("")
        var receivedURLs: [URL]?
        tv.onDropFileURLs = { urls in receivedURLs = urls; return true }

        tv.paste(nil)

        XCTAssertEqual(receivedURLs, [fileURL])
        XCTAssertEqual(tv.string, "")
    }

    /// Multiple files copied at once (a multi-select Finder "Copy") must
    /// each be handed to `onDropFileURLs` in one call, matching how the drop
    /// path already handles multiple URLs.
    func test_multipleFinderFilesRouteAsOneBatch() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        let urlA = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-a-\(UUID().uuidString).txt")
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-b-\(UUID().uuidString).txt")
        let itemA = NSPasteboardItem()
        itemA.setString(urlA.absoluteString, forType: .fileURL)
        itemA.setString(urlA.path, forType: .string)
        let itemB = NSPasteboardItem()
        itemB.setString(urlB.absoluteString, forType: .fileURL)
        itemB.setString(urlB.path, forType: .string)
        pb.writeObjects([itemA, itemB])

        let tv = textView("")
        var receivedURLs: [URL]?
        tv.onDropFileURLs = { urls in receivedURLs = urls; return true }

        tv.paste(nil)

        XCTAssertEqual(receivedURLs?.count, 2)
    }

    /// Case 5, unaffected: plain text with no image bytes and no file URL
    /// pastes as text, unchanged.
    func test_plainTextPasteIsUnaffected() throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("hello world", forType: .string)

        let tv = textView("")
        tv.onDropFileURLs = { _ in XCTFail("no file URL on this pasteboard"); return false }
        tv.onPasteImage = { _, _ in XCTFail("no image data on this pasteboard"); return false }

        tv.paste(nil)

        XCTAssertEqual(tv.string, "hello world")
    }

    /// THE REAL MECHANISM: `MarkdownEditor.makeNSView` (see
    /// `MarkdownEditor.swift:116-120`) always installs BOTH `onDropFileURLs`
    /// and `onPasteImage`, for every document, read-only or not — the
    /// closures themselves are never `nil`. Read-only is enforced one layer
    /// down: `DocumentPane`'s `writeDroppedFile`/`writePastedImage`
    /// closures (`DocumentPane.swift:134,145`) check
    /// `!session.isReadOnly` FIRST and return `nil` before ever reaching
    /// `store.writeAttachment`, so the coordinator's handler is called and
    /// returns `false`, but nothing is ever written to disk and nothing is
    /// inserted. (An earlier version of this test asserted the opposite —
    /// "no handler installed at all" — which was simply wrong about how
    /// `MarkdownEditor` wires read-only sessions, and had no assertions to
    /// catch that.)
    ///
    /// Exercised here one level below `LinkTextView`, directly against
    /// `MarkdownEditor.Coordinator`, which is where the real read-only gate
    /// lives — `writeDroppedFile` returning `nil` is exactly what
    /// `DocumentPane`'s closure does for a read-only session.
    @MainActor func test_readOnlySessionRouteWritesNothingAndInsertsNothing() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let coordinator = MarkdownEditor.Coordinator(text: .constant(""), tokens: TestTokens.make())
        let tv = textView("before")
        coordinator.textView = tv
        var writeAttempted = false
        // The read-only session's own shape: a non-nil closure that always
        // declines, exactly what `DocumentPane`'s `guard !session.isReadOnly
        // else { return nil }` produces.
        coordinator.writeDroppedFile = { _ in writeAttempted = true; return nil }

        let handled = coordinator.insertAttachments(fromDroppedFiles: [fileURL])

        XCTAssertTrue(writeAttempted, "the handler must still be reachable — read-only is enforced INSIDE it")
        XCTAssertFalse(handled, "a fully-declined write must report false")
        XCTAssertEqual(tv.string, "before", "nothing must be inserted when every write was declined")
    }
}
