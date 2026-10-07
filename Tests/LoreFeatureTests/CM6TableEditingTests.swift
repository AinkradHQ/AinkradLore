import AppKit
import WebKit
import XCTest

@testable import LoreFeature

/// Typing inside a rendered table cell, and the text column's own geometry.
///
/// Both reported by the owner: "when i try to write inside the table cells, it
/// writes one character only and moves the cursor below the table", and "the
/// text is stick to the edge end of the left side of the panel, it should have
/// some padding".
///
/// Editing a cell in place is the single capability this whole milestone exists
/// for — the native renderer cannot put a caret inside a rendered table at all —
/// so a table that accepts exactly one character is worse than no table
/// rendering. And it was covered by a test: `typeInFirstCell` set a cell's
/// textContent wholesale and dispatched ONE input event, which is the one case
/// that worked.
final class CM6TableEditingTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var webView: WKWebView!
    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func boot(_ text: String) throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = webView
        windows.append(window)
        // NOT ordered on screen.
        //
        // This called `makeKeyAndOrderFront` to try to make `drawSelection()`
        // draw a caret that could be measured. It never worked — a web view in
        // this process does not become first responder however the window is
        // configured — and it put three 900x1432 windows over the owner's screen
        // for the length of every run, with no close button, because this style
        // mask has no `.closable`. Every other test in this target hosts its
        // view in a window it never orders front, which is why none of them has
        // ever done this.
        let index = try XCTUnwrap(CM6EditorView.Coordinator.bundledIndexURL)
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        try waitFor("boot") {
            ((try? self.js("typeof window.loreEditor")) as? String) == "object"
        }
        _ = try js("window.loreEditor.init(\(CM6EditorView.Coordinator.jsString(text)))")
        _ = try js("window.loreEditor.focusEnd()")
    }

    /// Put the caret at the end of a body cell, as clicking into it would.
    @MainActor
    private func focusCell(_ index: Int) throws -> Bool {
        (try js(
            """
            (() => {
              const cell = document.querySelectorAll('.cm-lore-table td')[\(index)];
              if (!cell) return false;
              cell.focus();
              const selection = window.getSelection();
              const range = document.createRange();
              range.selectNodeContents(cell);
              range.collapse(false);
              selection.removeAllRanges();
              selection.addRange(range);
              return document.activeElement === cell;
            })()
            """) as? Bool) ?? false
    }

    /// One character, appended and announced — exactly what a keystroke in a
    /// contentEditable produces.
    @MainActor
    private func type(_ character: String) throws {
        _ = try js(
            """
            (() => {
              const cell = document.activeElement;
              if (!cell || cell.dataset.r === undefined) return false;
              cell.textContent = cell.textContent + \(CM6EditorView.Coordinator.jsString(character));
              cell.dispatchEvent(new Event('input', { bubbles: true }));
              return true;
            })()
            """)
        // Let the dispatched transaction and the decoration pass run.
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private func documentText() throws -> String {
        (try js("window.loreEditor.text()") as? String) ?? ""
    }

    // MARK: - typing in a cell

    /// FIVE characters, one keystroke at a time. One character was the bug.
    @MainActor
    func test_severalCharactersCanBeTypedIntoOneCell() throws {
        try boot("Before.\n\n| A | B |\n|---|---|\n| one | two |\n\nAfter.\n")
        XCTAssertEqual(try js("window.loreEditor.tableCount()") as? Int, 1)
        XCTAssertTrue(try focusCell(0))
        for character in ["X", "Y", "Z", "1", "2"] { try type(character) }
        XCTAssertEqual(
            try documentText(),
            "Before.\n\n| A | B |\n|---|---|\n| oneXYZ12 | two |\n\nAfter.\n")
    }

    /// The caret must still be IN the cell afterwards. It jumped below the
    /// table because CodeMirror destroyed the widget on the first change and
    /// the contentEditable holding the caret went with it.
    @MainActor
    func test_theCaretStaysInTheCellItIsTypedIn() throws {
        try boot("| A | B |\n|---|---|\n| one | two |\n\n")
        XCTAssertTrue(try focusCell(0))
        try type("X")
        XCTAssertEqual(
            try js(
                """
                !!(document.activeElement && document.activeElement.dataset
                   && document.activeElement.dataset.r !== undefined)
                """) as? Bool, true, "the caret left the cell")
        // And the table is still one table, not rebuilt or lost.
        XCTAssertEqual(try js("window.loreEditor.tableCount()") as? Int, 1)
    }

    /// A second cell, so the range re-derivation is exercised on a cell that is
    /// not the first — the stale captured ranges were per-cell.
    @MainActor
    func test_typingInASecondCellWritesToThatCell() throws {
        try boot("| A | B |\n|---|---|\n| one | two |\n\n")
        XCTAssertTrue(try focusCell(1))
        for character in ["Q", "R"] { try type(character) }
        XCTAssertEqual(try documentText(), "| A | B |\n|---|---|\n| one | twoQR |\n\n")
    }

    /// Text BEFORE the table shifts every offset in it. The ranges captured
    /// when the widget was built are stale from that moment, which is why they
    /// are re-derived from `posAtDOM` on every keystroke.
    @MainActor
    func test_typingStillLandsAfterTheTextAboveHasGrown() throws {
        try boot("Before.\n\n| A | B |\n|---|---|\n| one | two |\n\n")
        // Grow the first line, so every table offset moves.
        _ = try js("window.loreEditor.selectAt(7)")
        _ = try js(
            """
            (() => {
              const v = window.loreEditor;
              v.__insertAt = null;
              return true;
            })()
            """)
        _ = try js("window.loreEditor.applyCompletion(7, 7, ' and more text')")
        XCTAssertTrue(try documentText().hasPrefix("Before. and more text"))
        XCTAssertTrue(try focusCell(0))
        try type("X")
        XCTAssertEqual(
            try documentText(),
            "Before. and more text\n\n| A | B |\n|---|---|\n| oneX | two |\n\n")
    }

    // MARK: - the text column

    /// The inset was measured at 0px: CodeMirror's base theme sets
    /// `padding: 4px 0` on `.cm-content` and outranked the rule here, so every
    /// line sat flush against the left edge of the pane. `font-family` on the
    /// SAME rule did win, which is why this went unnoticed — one property
    /// applied and another did not.
    @MainActor
    func test_theTextColumnIsInsetFromTheEdgeOfThePane() throws {
        try boot("Some prose.\n")
        let padding =
            try js(
                """
                (() => {
                  const c = getComputedStyle(document.querySelector('.cm-content'));
                  return Math.round(parseFloat(c.paddingLeft));
                })()
                """) as? Int ?? -1
        XCTAssertGreaterThan(padding, 8, "the text column has no left inset")
        // And a line actually starts inside the editor, not at its edge.
        let lineLeft =
            try js(
                """
                (() => {
                  const editor = document.querySelector('.cm-editor').getBoundingClientRect();
                  const line = document.querySelector('.cm-content > .cm-line').getBoundingClientRect();
                  return Math.round(line.left - editor.left);
                })()
                """) as? Int ?? -1
        XCTAssertGreaterThan(lineLeft, 8, "the first line is flush against the pane edge")
    }

    /// Centred, with equal padding on both sides.
    ///
    /// This assertion is the REVERSE of the one it replaces, which pinned
    /// `margin-left: 0px` on the grounds that the native editor deliberately
    /// stopped centring a capped column. The owner then asked for the opposite —
    /// "make it full width, centered, padding from both sides the same" — which
    /// is their call to make about their own editor. Recorded rather than
    /// quietly swapped, because a test whose expectation flips deserves to say
    /// why.
    ///
    /// With the measure defaulting to full width, centring changes nothing; it
    /// is what keeps a Narrow, Standard or Wide column balanced in the pane
    /// rather than jammed left.
    @MainActor
    func test_theColumnIsCentredWithEqualPaddingOnBothSides() throws {
        try boot("Some prose that is long enough to show where the column sits.\n")
        let geometry = try XCTUnwrap(
            try js(
                """
                (() => {
                  const content = document.querySelector('.cm-content');
                  const style = getComputedStyle(content);
                  const editor = document.querySelector('.cm-editor').getBoundingClientRect();
                  const box = content.getBoundingClientRect();
                  return JSON.stringify({
                    marginInline: style.marginLeft + '|' + style.marginRight,
                    padLeft: Math.round(parseFloat(style.paddingLeft)),
                    padRight: Math.round(parseFloat(style.paddingRight)),
                    gapLeft: Math.round(box.left - editor.left),
                    gapRight: Math.round(editor.right - box.right)
                  });
                })()
                """) as? String)
        let values = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(geometry.utf8)) as? [String: Any])
        let padLeft = try XCTUnwrap(values["padLeft"] as? Int)
        let padRight = try XCTUnwrap(values["padRight"] as? Int)
        let gapLeft = try XCTUnwrap(values["gapLeft"] as? Int)
        let gapRight = try XCTUnwrap(values["gapRight"] as? Int)
        XCTAssertEqual(padLeft, padRight, "the inset must match on both sides")
        XCTAssertGreaterThan(padLeft, 8, "there must be an inset at all")
        // Equal outside gaps are what "centred" means in the pane. One pixel of
        // slack for a fractional layout.
        XCTAssertLessThanOrEqual(
            abs(gapLeft - gapRight), 1,
            "the column is not centred: \(geometry)")
        print("COLUMN \(geometry)")
    }

    /// And the measure defaults to filling the width, which is what the owner
    /// asked for. `EditorSettings.default` is the single source: the decoder
    /// falls back to it, so settings written before the key existed follow.
    func test_theMeasureDefaultsToFullWidth() {
        XCTAssertEqual(EditorSettings.default.measure, .full)
        XCTAssertNil(
            EditorSettings.default.maxMeasure,
            "full width means no cap at all")
    }

    // MARK: - plumbing

    @MainActor @discardableResult
    private func js(_ source: String) throws -> Any? {
        var result: Any?
        var failure: Error?
        var done = false
        webView.evaluateJavaScript(source) { v, e in
            result = v
            failure = e
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if let failure { throw failure }
        return result
    }

    @MainActor
    private func waitFor(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
