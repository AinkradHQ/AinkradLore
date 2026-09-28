import XCTest
@testable import LoreFeature

final class SourceOffsetMapTests: XCTestCase {

    func test_firstCharacterOfFirstLine() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
    }

    func test_secondLineStartsAfterTheNewline() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)
    }

    func test_bodyOffsetShiftsEverything() {
        // The editor holds frontmatter + body; the parser only saw the body.
        let map = SourceOffsetMap(body: "abc\n", bodyUTF16Offset: 20)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 20)
    }

    func test_crlfLineEndingsAdvanceByTwoUTF16Units() {
        // "\r\n" is ONE Character but TWO UTF-16 code units. Getting this wrong
        // silently misplaces every span in a Windows-authored note.
        let map = SourceOffsetMap(body: "abc\r\ndef\r\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 5)
    }

    func test_crOnlyLineEndings() {
        let map = SourceOffsetMap(body: "abc\rdef\r", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)
    }

    func test_mixedLineEndings() {
        let map = SourceOffsetMap(body: "a\nb\r\nc\rd", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 2)
        XCTAssertEqual(map.utf16Offset(line: 3, column: 1), 5)
        XCTAssertEqual(map.utf16Offset(line: 4, column: 1), 7)
    }

    func test_multiByteScalarShiftsColumnsOnItsLine() {
        // "é" is 2 UTF-8 bytes but 1 UTF-16 unit. cmark columns count bytes.
        let map = SourceOffsetMap(body: "é x\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)   // é
        XCTAssertEqual(map.utf16Offset(line: 1, column: 3), 1)   // space (byte 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 2)   // x
    }

    func test_emojiIsTwoUTF16Units() {
        // "👍" is 4 UTF-8 bytes and 2 UTF-16 units.
        let map = SourceOffsetMap(body: "👍x\n", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 5), 2)   // x
    }

    func test_emptyBody() {
        let map = SourceOffsetMap(body: "", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertNil(map.utf16Offset(line: 2, column: 1))
    }

    func test_finalLineWithoutTerminator() {
        let map = SourceOffsetMap(body: "abc\ndef", bodyUTF16Offset: 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 4), 7)
    }

    func test_outOfRangePositionsReturnNil() {
        let map = SourceOffsetMap(body: "abc\n", bodyUTF16Offset: 0)
        XCTAssertNil(map.utf16Offset(line: 0, column: 1))
        XCTAssertNil(map.utf16Offset(line: 99, column: 1))
        XCTAssertNil(map.utf16Offset(line: 1, column: 99))
    }

    func test_rangeSpansTwoLines() {
        let map = SourceOffsetMap(body: "abc\ndef\n", bodyUTF16Offset: 0)
        let r = map.utf16Range(fromLine: 1, fromColumn: 1, toLine: 2, toColumn: 4)
        XCTAssertEqual(r, NSRange(location: 0, length: 7))
    }
}
