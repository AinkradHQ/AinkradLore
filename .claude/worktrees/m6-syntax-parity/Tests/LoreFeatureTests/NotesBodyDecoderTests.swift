import XCTest
@testable import LoreFeature

/// Task 5's HALF that can be verified today.
///
/// gzip is RFC 1952 and protobuf's wire format is documented, so both can be
/// tested against real artifacts: the `.gz` fixtures are actual `gzip(1)`
/// output, and the protobuf blobs are encoded here by hand from the spec.
///
/// What is NOT tested here, and cannot be until Full Disk Access is granted:
/// whether the longest-UTF-8-field heuristic picks the right field out of a
/// blob APPLE produced. A fixture invented here would only prove the decoder
/// agrees with the guess it was written from — the "benchmark fixture with no
/// embeds" failure from M3, which must not repeat.
final class NotesBodyDecoderTests: XCTestCase {
    private let expected = """
    The quick brown fox jumps over the lazy dog.
    Second line with UTF-8: café — naïve.

    """

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "gz"),
            "fixture \(name).gz missing from the test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: - gzip, against real gzip(1) output

    /// `gzip(1)` sets FNAME by default when compressing a FILE, storing the
    /// original name in the header. A decoder that skipped a fixed ten bytes
    /// would land in the middle of that name — and fail on the most ordinary
    /// input there is.
    func testInflatesAGzipStreamCarryingAStoredFilename() throws {
        let data = try fixture("withname")
        XCTAssertEqual(data[3] & 0x08, 0x08, "this fixture must have FNAME set")
        XCTAssertEqual(String(data: try NotesBodyDecoder.inflate(data), encoding: .utf8),
                       expected)
    }

    func testInflatesAGzipStreamWithNoOptionalHeaderFields() throws {
        let data = try fixture("noname")
        XCTAssertEqual(data[3], 0, "this fixture must have no header flags set")
        XCTAssertEqual(String(data: try NotesBodyDecoder.inflate(data), encoding: .utf8),
                       expected)
    }

    func testRejectsDataThatIsNotGzip() {
        XCTAssertThrowsError(try NotesBodyDecoder.inflate(Data("not gzip at all, really".utf8))) {
            XCTAssertEqual($0 as? NotesBodyDecoder.DecodeError, .notGzip)
        }
    }

    func testRejectsAStreamTruncatedToItsHeader() throws {
        XCTAssertThrowsError(try NotesBodyDecoder.inflate(try fixture("noname").prefix(12)))
    }

    /// A header claiming FNAME with no NUL to end it must not run off the end
    /// of the buffer looking for one.
    func testRejectsAHeaderWhoseFilenameIsNeverTerminated() {
        var data = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 3])
        data.append(Data(repeating: 0x41, count: 40))   // 'A's, no NUL, no trailer
        XCTAssertThrowsError(try NotesBodyDecoder.inflate(data))
    }

    /// The output buffer is sized from the trailer's ISIZE, which is untrusted
    /// input. A lie about it must grow the buffer, not truncate the result.
    func testInflatesCorrectlyEvenWhenTheTrailerSizeIsWrong() throws {
        var data = try fixture("noname")
        data.replaceSubrange((data.count - 4)..., with: [0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(String(data: try NotesBodyDecoder.inflate(data), encoding: .utf8),
                       expected)
    }

    // MARK: - protobuf wire walk, against blobs encoded from the spec

    /// Field 2, wire type 2 (length-delimited): `0x12 <len> <bytes>`.
    private func lengthDelimited(field: UInt8, _ text: String) -> Data {
        var data = Data([field << 3 | 2])
        let bytes = Data(text.utf8)
        var length = bytes.count
        // Varint length, so a body over 127 bytes encodes correctly too.
        repeat {
            var byte = UInt8(length & 0x7f)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            data.append(byte)
        } while length > 0
        return data + bytes
    }

    func testFindsTheOnlyStringField() throws {
        XCTAssertEqual(try NotesBodyDecoder.extractText(lengthDelimited(field: 2, "hello")),
                       "hello")
    }

    func testPrefersTheLongestStringField() throws {
        let proto = lengthDelimited(field: 1, "short")
            + lengthDelimited(field: 2, "a much longer run of body text")
            + lengthDelimited(field: 3, "tiny")
        XCTAssertEqual(try NotesBodyDecoder.extractText(proto),
                       "a much longer run of body text")
    }

    /// A body longer than 127 bytes needs a multi-byte varint length. Getting
    /// this wrong would truncate every note of any substance while every short
    /// test note passed.
    func testReadsAFieldWhoseLengthNeedsAMultiByteVarint() throws {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(try NotesBodyDecoder.extractText(lengthDelimited(field: 2, long)), long)
    }

    /// Varint (0), 64-bit (1) and 32-bit (5) fields must be skipped by their
    /// own rules, or every field after one of them is read at the wrong offset.
    func testSkipsNonStringFieldsWithoutLosingAlignment() throws {
        var proto = Data([1 << 3 | 0, 0x96, 0x01])            // varint field 1 = 150
        proto += Data([3 << 3 | 5, 0, 0, 0, 0])               // 32-bit field 3
        proto += Data([4 << 3 | 1, 0, 0, 0, 0, 0, 0, 0, 0])   // 64-bit field 4
        proto += lengthDelimited(field: 5, "the body")
        XCTAssertEqual(try NotesBodyDecoder.extractText(proto), "the body")
    }

    func testKeepsWhatItFoundWhenTheBlobIsTruncatedMidField() throws {
        let proto = lengthDelimited(field: 2, "found this first")
            + Data([3 << 3 | 2, 0x40])                        // claims 64 bytes, has none
        XCTAssertEqual(try NotesBodyDecoder.extractText(proto), "found this first")
    }

    func testThrowsRatherThanReturningEmptyWhenThereIsNoTextAtAll() {
        XCTAssertThrowsError(try NotesBodyDecoder.extractText(Data([1 << 3 | 0, 0x01]))) {
            XCTAssertEqual($0 as? NotesBodyDecoder.DecodeError, .noTextField)
        }
    }

    /// Bytes that are not valid UTF-8 must not be dressed up as text.
    func testIgnoresALengthDelimitedFieldThatIsNotUTF8() throws {
        var proto = Data([2 << 3 | 2, 4])
        proto += Data([0xff, 0xfe, 0xfd, 0xfc])
        proto += lengthDelimited(field: 3, "ok")
        XCTAssertEqual(try NotesBodyDecoder.extractText(proto), "ok")
    }
}
