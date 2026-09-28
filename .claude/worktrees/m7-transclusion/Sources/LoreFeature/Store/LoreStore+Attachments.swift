import Foundation

/// Writing attachments dropped or pasted into a note. Task 9: an embed is
/// only as easy to create as the file behind it is easy to place, so this
/// exists to make "drag a PNG in" and "⌘V a screenshot" both just work.
public extension LoreStore {
    /// Writes an attachment BESIDE `noteURL` and returns where it landed.
    ///
    /// Beside the note, not in a vault-wide `_attachments/`: a folder subtree
    /// then moves, copies and backs up as a self-contained unit, and a note's
    /// images never outlive the note in a shared bucket nobody prunes.
    ///
    /// Never overwrites. A colliding name gets ` 2`, ` 3`, … before the
    /// extension — the same shape Finder uses, and the only safe behaviour when
    /// the incoming bytes are a paste the user cannot re-do.
    ///
    /// `preferredName` is UNTRUSTED — it can come straight off a pasteboard or
    /// a dropped file's name — so it is sanitized before it ever touches a
    /// path, and containment is checked on the resolved destination
    /// DIRECTORY (symlink-aware, same guard `create(title:in:)` uses), not
    /// merely on the string. A name like `../../etc/passwd` or a name that is
    /// only dots must never be able to escape `noteURL`'s directory.
    func writeAttachment(data: Data, preferredName: String,
                         besideNote noteURL: URL) throws -> URL {
        let directory = noteURL.deletingLastPathComponent()
        guard let root = vaultRoot, Self.isContained(directory, in: root) else {
            throw LoreError.outsideVault(noteURL)
        }
        let destination = Self.nonCollidingURL(
            in: directory, preferredName: Self.sanitized(preferredName))
        try Self.writeExactly(data, to: destination)
        return destination
    }

    /// The one place raw bytes actually hit disk for an attachment write —
    /// split out from `writeAttachment(data:preferredName:besideNote:)` so
    /// the overwrite guard itself is directly testable, independent of
    /// `nonCollidingURL`'s own dedup scan. `.withoutOverwriting` is a
    /// second, filesystem-level guarantee on TOP of that scan: it is what
    /// actually makes a TOCTOU race (another write landing on the chosen
    /// name between the scan and this call) fail loudly instead of silently
    /// clobbering the other file.
    ///
    /// `internal`, not `public`: this only needs to be visible to
    /// `AttachmentWriteTests` via `@testable import`, which sees `internal`
    /// exactly as well as `public` would. `public` would have widened the
    /// module's real API surface for a seam that exists purely for testing.
    internal static func writeExactly(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .withoutOverwriting)
    }

    /// Copies an existing file into the vault beside `noteURL`. A dropped
    /// file is always COPIED, never referenced in place: a link to a file
    /// outside the vault breaks the moment the vault is moved or synced to
    /// another machine, and the vault stops being a complete record of
    /// itself.
    ///
    /// Uses `FileManager.copyItem`, NOT `Data(contentsOf:)` +
    /// `writeExactly`: a dropped video or PDF can be hundreds of MB, and the
    /// drop handler runs synchronously on the main actor — loading the
    /// whole file into an in-memory `Data` there would beachball the app for
    /// as long as the read takes. `copyItem` streams at the filesystem
    /// level and also preserves extended attributes (Finder tags,
    /// quarantine flags) a byte-copy would silently drop. That streaming
    /// argument only holds for a single regular file: a DIRECTORY dropped
    /// here has no bound on its own — `copyItem` recurses the whole
    /// subtree synchronously on the main actor regardless of size, which is
    /// exactly the beachball this function exists to avoid, and the result
    /// is a permanently-unresolved `![[SomeFolder]]` embed besides
    /// (directories are never indexed, so the link can never resolve). Only
    /// a regular file — or a symlink that ultimately resolves to one — is
    /// accepted; anything else is rejected before any bytes move.
    func writeAttachment(copying sourceURL: URL, besideNote noteURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw LoreError.notARegularFile(sourceURL) }
        let directory = noteURL.deletingLastPathComponent()
        guard let root = vaultRoot, Self.isContained(directory, in: root) else {
            throw LoreError.outsideVault(noteURL)
        }
        // Re-dragging a file that is ALREADY the note's own attachment (it
        // already sits beside this exact note) must not duplicate it as
        // "name 2.ext" — same directory, same name IS the existing copy.
        //
        // Gated ALSO on the name already being safe — `sanitized(name) ==
        // name` — not merely on "it already exists here". Without that
        // second condition this early return hands back a URL whose
        // filename never went through `sanitized`, and `embedSyntax` (see
        // its doc comment) assumes every URL it is ever called with did.
        // An in-vault file that predates this feature, or was created by
        // some other tool, CAN already carry a name like `a]]b.png` — this
        // fast path must not be how that corrupts the note body via the
        // exact Important 4 escape it was supposed to have closed. A file
        // whose existing name is unsafe instead falls through to the normal
        // copy-with-sanitized-destination path below, same as any other
        // source.
        if sourceURL.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path,
           FileManager.default.fileExists(atPath: sourceURL.path),
           Self.sanitized(sourceURL.lastPathComponent) == sourceURL.lastPathComponent {
            return sourceURL
        }
        let destination = Self.nonCollidingURL(
            in: directory, preferredName: Self.sanitized(sourceURL.lastPathComponent))
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// The text to insert for an attachment: the filename WITH its
    /// extension, which is the key `LinkResolver` registers for a
    /// non-markdown file. Safe by construction, not by escaping here: every
    /// filename this is ever called with already went through `sanitized`,
    /// which strips the characters (`]`, `|`, `#`, newlines) that would
    /// otherwise let a crafted name corrupt the `![[…]]` it is embedded in
    /// or retarget the link via `LinkResolver`'s own alias/fragment syntax —
    /// see `sanitized`'s doc comment. The file on disk and the link that
    /// names it must always agree, which is only true if both come from the
    /// SAME sanitized string.
    func embedSyntax(for attachmentURL: URL) -> String {
        "![[\(attachmentURL.lastPathComponent)]]"
    }

    /// Strips everything that could either escape the target directory or
    /// corrupt the `![[name]]` embed this name is later interpolated into
    /// unescaped — the file and the link must always agree, so the filename
    /// itself is sanitized once, rather than escaped twice at two call
    /// sites that could drift apart.
    ///
    /// - `/` and `:` are the path-escape vectors on macOS (there is no
    ///   meaningful `\` separator here).
    /// - `]`, `|`, `#` are markdown-embed-escape vectors: unescaped, `]]`
    ///   inside a name closes the embed early and leaves trailing text in
    ///   the document body (`a]]b.png` → `![[a]]b.png]]`); `|` and `#` are
    ///   `LinkResolver` syntax for an alias and a fragment, so a name like
    ///   `a|b.png` or `a#b.png` would silently resolve the embed to a
    ///   DIFFERENT target than the file just written.
    /// - Newlines (anywhere in the string, not just the trimmed ends) would
    ///   split the `![[…]]` token across two lines and break the markdown
    ///   parse.
    /// - `NUL` cannot appear in a valid path component at all, but a
    ///   pasteboard string can still contain one; stripped for the same
    ///   reason as the rest — this text lands verbatim in the document body.
    ///
    /// A name that is nothing BUT dots after all of the above — `...`, or
    /// `../../etc/passwd` once its slashes are gone — would otherwise become
    /// `.` or `..`, a real, dangerous path component; `withoutLeadingDots.isEmpty`
    /// catches both and falls back to a fixed placeholder.
    ///
    /// Finally capped to a conservative BYTE budget: an uncapped pasteboard
    /// name can exceed `NAME_MAX` (255 bytes on APFS — a byte limit, not a
    /// character-count limit), which would otherwise make the write fail
    /// with `ENAMETOOLONG` for a reason the user has no way to see. Earlier
    /// this cut at 200 CODE POINTS, which is only safe for ASCII names — a
    /// 400-character CJK name still caps to 200 UTF-16/Swift `Character`s
    /// but well over 255 UTF-8 BYTES (3 bytes/character for most CJK
    /// scalars), so it still hit `ENAMETOOLONG`. `maxBaseNameBytes` fixes
    /// that by budgeting BYTES and walking back to a scalar boundary —
    /// the exact technique `VaultIndexCoordinator.capped` already uses for
    /// the same reason, copied rather than reinvented.
    nonisolated static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:]|#\u{0}").union(.newlines)
        var cleaned = String(String.UnicodeScalarView(
            name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = cleaned.drop(while: { $0 == "." })
        guard !withoutLeadingDots.isEmpty else { return "attachment" }
        let base = (String(withoutLeadingDots) as NSString).deletingPathExtension
        let ext = (String(withoutLeadingDots) as NSString).pathExtension
        let cappedBase = Self.cappedToBytes(base, maxBytes: maxBaseNameBytes)
        return ext.isEmpty ? cappedBase : "\(cappedBase).\(ext)"
    }

    /// Conservative headroom under `NAME_MAX` (255 bytes on APFS) for the
    /// base name alone: the extension, the ` NN` collision suffix
    /// `nonCollidingURL` may still append, and the `.` separators all still
    /// need to fit inside the same 255-byte limit.
    private nonisolated static let maxBaseNameBytes = 200

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes WITHOUT splitting
    /// a multi-byte scalar in half — the same walk-back-to-a-lead-byte
    /// technique `VaultIndexCoordinator.capped` uses for indexed plaintext,
    /// copied here because the problem (cut a UTF-8 string to a byte budget
    /// without producing invalid UTF-8) is identical.
    private nonisolated static func cappedToBytes(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxBytes))
        // Walk back to the last lead byte (anything that is not a 10xxxxxx
        // continuation). If the sequence it starts would run past the cut,
        // the scalar is incomplete — drop it whole.
        var i = bytes.count - 1
        while i >= 0, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        if i >= 0 {
            let lead = bytes[i]
            let width = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4))
            if i + width > bytes.count { bytes.removeSubrange(i...) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Finds the first name in `directory` that does not already exist,
    /// starting at `preferredName` and then trying ` 2`, ` 3`, … before the
    /// extension — Finder's own collision shape, so it reads as familiar
    /// rather than invented.
    static func nonCollidingURL(in directory: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
