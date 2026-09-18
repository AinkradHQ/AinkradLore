import Foundation
import Compression

/// Unwraps an Apple Notes body blob: `ZICNOTEDATA.ZDATA` is gzip-wrapped
/// protobuf.
///
/// THE TWO HALVES OF THIS FILE HAVE VERY DIFFERENT STANDING, and conflating
/// them would be the mistake:
///
///  - **`inflate`** implements gzip (RFC 1952), a documented standard. It is
///    verified against real `gzip(1)` output checked into `Tests/Fixtures/gzip`
///    and is as trustworthy as any other decoder here.
///  - **`extractText`** walks the protobuf WIRE format, also documented
///    (and tested against blobs the tests encode themselves) — but WHICH FIELD
///    carries the note text is Apple's private schema, undocumented and free
///    to change. The "longest UTF-8 field wins" heuristic below is a
///    STANDING ASSUMPTION THAT HAS NOT BEEN VERIFIED AGAINST A REAL BLOB,
///    because doing so needs Full Disk Access that has not been granted.
///
/// That is why `decode` is not yet wired into any source. Verifying the
/// heuristic against captured fixtures is Task 5's remaining step; a synthetic
/// fixture cannot do it, since it would only prove the decoder agrees with the
/// guess it was written from.
public enum NotesBodyDecoder {
    public struct Decoded: Sendable, Equatable {
        public let text: String
        public let warnings: [FidelityWarning]
    }

    public enum DecodeError: Error, Equatable {
        case notGzip
        case inflateFailed
        case noTextField
    }

    /// gzip (RFC 1952) around raw DEFLATE.
    ///
    /// Apple's `Compression` framework speaks DEFLATE, not gzip, so the header
    /// has to come off by hand — including the OPTIONAL fields the flag byte
    /// declares. `gzip(1)` sets FNAME by default when compressing a file, so
    /// skipping a fixed ten bytes would land mid-filename and fail on the most
    /// ordinary input there is.
    static func inflate(_ data: Data) throws -> Data {
        // 10-byte header + 8-byte trailer, so anything at or under 18 bytes
        // cannot contain a payload.
        guard data.count > 18, data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b, data[data.startIndex + 2] == 0x08
        else { throw DecodeError.notGzip }

        let flags = data[data.startIndex + 3]
        var offset = data.startIndex + 10

        func skipNulTerminated() throws {
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            guard offset < data.endIndex else { throw DecodeError.notGzip }
            offset += 1                                   // the NUL itself
        }

        if flags & 0x04 != 0 {                            // FEXTRA: length-prefixed
            guard offset + 2 <= data.endIndex else { throw DecodeError.notGzip }
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + length
        }
        if flags & 0x08 != 0 { try skipNulTerminated() }  // FNAME
        if flags & 0x10 != 0 { try skipNulTerminated() }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }              // FHCRC

        guard offset < data.endIndex - 8 else { throw DecodeError.notGzip }
        let deflated = data.subdata(in: offset..<(data.endIndex - 8))

        // The trailer's ISIZE is the uncompressed size mod 2^32 — the right
        // first guess at the buffer, rather than a blind multiple of the
        // compressed size. It is only a hint: it is untrusted input and is
        // modular, so the loop still grows on failure instead of believing it.
        let isize = data.suffix(4).reversed().reduce(0) { ($0 << 8) | Int($1) }
        var capacity = max(isize + 1, max(deflated.count * 8, 64 * 1024))

        for _ in 0..<6 {
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { out.deallocate() }
            let written = deflated.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out, capacity, base, deflated.count,
                                                 nil, COMPRESSION_ZLIB)
            }
            // `compression_decode_buffer` cannot distinguish "filled the
            // buffer exactly" from "ran out of room", so a full buffer is
            // treated as a possible truncation and retried larger.
            if written > 0, written < capacity { return Data(bytes: out, count: written) }
            capacity *= 4
        }
        throw DecodeError.inflateFailed
    }

    /// Walks the protobuf wire format for the longest length-delimited field
    /// that decodes as UTF-8.
    ///
    /// Deliberately NOT a model of Apple's message schema. That schema is
    /// undocumented and changes between OS releases, so a full model would be
    /// a permanent liability; this reads only the structure the wire format
    /// itself guarantees.
    ///
    /// THE UNVERIFIED PART: "the note body is the longest UTF-8 field" is an
    /// assumption. It is plausible — attribute runs and identifiers are short,
    /// the body is not — but it has never been checked against a blob Apple
    /// produced. Until it is, treat a `decode` result as unproven.
    static func extractText(_ proto: Data) throws -> String {
        var index = proto.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < proto.endIndex {
                let byte = proto[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        var best: String?
        while index < proto.endIndex {
            guard let key = varint() else { break }
            switch key & 0x07 {
            case 0:
                guard varint() != nil else { return best ?? "" }
            case 1:
                guard let next = proto.index(index, offsetBy: 8, limitedBy: proto.endIndex)
                else { return best ?? "" }
                index = next
            case 5:
                guard let next = proto.index(index, offsetBy: 4, limitedBy: proto.endIndex)
                else { return best ?? "" }
                index = next
            case 2:
                guard let length = varint(),
                      let end = proto.index(index, offsetBy: Int(length),
                                            limitedBy: proto.endIndex)
                else { return best ?? "" }
                let slice = Data(proto[index..<end])
                index = end
                // A nested message is also length-delimited and may well
                // decode as UTF-8 garbage; requiring it to round-trip filters
                // most of that out without pretending to know the schema.
                if let text = String(data: slice, encoding: .utf8),
                   Data(text.utf8) == slice,
                   text.count > (best?.count ?? 0) {
                    best = text
                }
            default:
                // Groups (3, 4) and anything undefined: the wire format gives
                // no way to know the length, so continuing would be guessing
                // at byte offsets. Stop with what was found.
                return best ?? ""
            }
        }
        guard let text = best else { throw DecodeError.noTextField }
        return text
    }

    /// UNVERIFIED against a real `ZDATA` blob — see the type doc. Nothing
    /// calls this yet, and nothing should until Task 5's fixtures are
    /// captured.
    public static func decode(_ data: Data) throws -> Decoded {
        Decoded(text: try extractText(try inflate(data)), warnings: [])
    }
}
