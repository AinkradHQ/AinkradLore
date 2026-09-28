import Foundation

/// Reads back which source items this vault already holds.
///
/// This is the missing half of `lore_import_id`. `ImportApplier` has written
/// that key into every imported note since the applier existed, and
/// `ImportPlanner` has always accepted an `existingImportIDs` set — but nothing
/// produced that set, so every caller passed `[]` and a retried import would
/// have duplicated the entire library. Idempotency is not optional here: a
/// partial import is the EXPECTED outcome (a locked note, a missing
/// attachment, a cancelled scan), which makes "run it again" normal operation
/// rather than an edge case.
///
/// Two records, because one record cannot cover both shapes of item:
///
///  - **Notes** carry their own ID in frontmatter. Self-describing, survives
///    the vault being moved or the ledger being deleted, and — importantly —
///    disappears when the user deletes the note, so deleting an imported note
///    and re-importing brings it back rather than silently skipping it.
///  - **Attachment-only items** (every image, PDF and binary in an Obsidian
///    vault) have no note to carry frontmatter. A PNG cannot hold a YAML
///    header. Those go in `ImportLedger`, which stores the landed path
///    alongside the ID so the same "deleted means not imported" rule applies:
///    an entry whose file is gone is not reported as imported.
public enum ImportIDReader {
    /// Every source item this vault can prove it already contains.
    ///
    /// Failures are absorbed, deliberately: an unreadable note yields no ID,
    /// which at worst offers the user a duplicate they can see and deselect in
    /// the preview. Throwing here would instead block the whole import on one
    /// bad file.
    public static func read(vaultRoot: URL) -> Set<String> {
        var ids = ImportLedger.liveIDs(vaultRoot: vaultRoot)
        let root = URL(fileURLWithPath: vaultRoot.resolvingSymlinksInPath().path)
        let rootDepth = root.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return ids }

        for case let url as URL in walker {
            // Only components BELOW the root are ours to judge — a vault living
            // under any dot-prefixed ancestor (`~/.local/share/notes`, a
            // sandbox container) must not read as entirely hidden. Same rule
            // `VaultIndexCoordinator.scanVault` applies, for the same reason.
            let components = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if components.contains(where: { $0.hasPrefix(".") }) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let id = importID(in: text) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Pulls `lore_import_id` out of a note's frontmatter.
    ///
    /// Goes through `Frontmatter`'s own scanner rather than a regex so it reads
    /// exactly what `ImportApplier.frontmatterBody` wrote, quoting included —
    /// `sourceID` is built from a user filesystem path, so it legally contains
    /// characters that force quoting, and a reader that missed those would
    /// match nothing precisely for the notes most at risk of duplication.
    static func importID(in text: String) -> String? {
        let layout = Frontmatter.splitLines(text)
        guard let close = Frontmatter.closingFenceIndex(layout) else { return nil }
        let header = Array(layout.lines[1..<close])
        guard let entry = Frontmatter.scan(header).first(where: { $0.key == "lore_import_id" })
        else { return nil }
        let value = Frontmatter.unquoted(entry.inlineValue)
        return value.isEmpty ? nil : value
    }
}

/// The import record for items that cannot carry frontmatter.
///
/// A plain tab-separated file under `.lore/`, which both `ObsidianSource` and
/// `VaultIndexCoordinator.scanVault` already skip as a dot-directory, so it
/// never shows up as a document or gets re-imported as one.
///
/// It records `landed-relative-path <TAB> source-id`, not just the id. Storing
/// the path is what keeps the ledger from going stale in the one direction
/// that matters: if the user deletes an imported image, the entry stops
/// counting and a re-import restores it. An id-only ledger would make deletion
/// permanent, which is a worse failure than the duplication it prevents.
///
/// This is provenance, not content. Files remain truth for what a vault HOLDS;
/// the ledger only remembers where a binary came from, which is a fact no byte
/// of the file itself records.
public enum ImportLedger {
    static let directoryName = ".lore"
    static let fileName = "import-ledger.tsv"

    static func url(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(directoryName).appendingPathComponent(fileName)
    }

    /// Appends one entry. `landedAt` must be inside `vaultRoot`; an entry that
    /// cannot be made relative to the vault is refused rather than written as
    /// an absolute path the vault could never resolve after being moved.
    static func record(id: String, landedAt: URL, vaultRoot: URL) throws {
        guard let relative = relativePath(of: landedAt, in: vaultRoot) else {
            throw LedgerError.outsideVault(landedAt.path)
        }
        let directory = url(vaultRoot: vaultRoot).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let line = Data((escape(relative) + "\t" + escape(id) + "\n").utf8)
        let file = url(vaultRoot: vaultRoot)
        // Append, never rewrite: the ledger accumulates across runs, and a
        // read-modify-write would lose every earlier entry if this write failed
        // halfway.
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }

    /// Recorded ids whose landed file still exists. See the type doc for why
    /// liveness is checked rather than trusted.
    static func liveIDs(vaultRoot: URL) -> Set<String> {
        var ids: Set<String> = []
        for entry in entries(vaultRoot: vaultRoot) {
            let landed = vaultRoot.appendingPathComponent(entry.relativePath)
            if FileManager.default.fileExists(atPath: landed.path) { ids.insert(entry.id) }
        }
        return ids
    }

    static func entries(vaultRoot: URL) -> [(relativePath: String, id: String)] {
        guard let text = try? String(contentsOf: url(vaultRoot: vaultRoot), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return (unescape(String(fields[0])), unescape(String(fields[1])))
        }
    }

    /// Both fields are user-derived — an Obsidian `sourceID` is a filesystem
    /// path, and a tab or a newline is legal in an APFS filename. Unescaped,
    /// either would split one entry into two unreadable ones, and the id would
    /// stop matching on the next run: silent duplication of exactly the file
    /// with the awkward name.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for ch in value {
            guard escaped else {
                if ch == "\\" { escaped = true } else { out.append(ch) }
                continue
            }
            switch ch {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            default: out.append(ch)
            }
            escaped = false
        }
        return out
    }

    /// Component-count arithmetic, not string prefixes: a vault root that went
    /// through `resolvingSymlinksInPath()` (`/var` -> `/private/var`, i.e. every
    /// test vault and every iCloud one) does not share a prefix with the URLs
    /// built beside it.
    static func relativePath(of url: URL, in vaultRoot: URL) -> String? {
        let root = URL(fileURLWithPath: vaultRoot.resolvingSymlinksInPath().path)
            .standardizedFileURL.pathComponents
        let target = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
            .standardizedFileURL.pathComponents
        guard target.count > root.count, Array(target.prefix(root.count)) == root else {
            return nil
        }
        return target.dropFirst(root.count).joined(separator: "/")
    }

    enum LedgerError: Error, LocalizedError, Equatable {
        case outsideVault(String)
        var errorDescription: String? {
            switch self {
            case .outsideVault(let path): "\(path) is not inside the vault"
            }
        }
    }
}
