import Foundation

/// What Lore indexes, and the one walk that finds it.
///
/// Lore is a notes tool, not a code indexer. A vault that contains code
/// projects used to index every file of every dependency tree under it —
/// 464,513 rows and 5.9 GB, 87.6% of it `node_modules`/`build`/`dist`/`vendor`
/// (`Docs/Audits/2026-09-18-app-cold-open.md`). The rules, in order:
///
/// 1. A dot-prefixed folder, a folder in `ignoredFolderNames`, or a path a
///    `.gitignore` excludes is PRUNED — the walk never enters it, so nothing
///    under it costs anything.
/// 2. A document (`documentExtensions`) is indexed with its content.
/// 3. A media file (`embeddableExtensions`) keeps a name-only row, so
///    `![[photo.png]]` embeds still resolve.
/// 4. Everything else is not part of the vault.
enum VaultWalk {
    static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "txt", "text", "pdf", "doc", "docx", "rtf", "rtfd", "odt",
    ]

    static let embeddableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "tif", "tiff", "bmp", "avif",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "mp4", "mov", "m4v", "webm", "excalidraw",
    ]

    static let ignoredFolderNames: Set<String> = [
        "node_modules", "bower_components", "vendor", "Pods", "Carthage", "build", "dist",
        "target", "DerivedData", "__pycache__", "venv",
    ]

    /// Folders a rule matches by relative path rather than by name.
    static let ignoredFolderPaths: [String] = ["storage/framework", "bootstrap/cache"]

    static func isIndexable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return documentExtensions.contains(ext) || embeddableExtensions.contains(ext)
    }

    struct Result {
        var files: [URL] = []
        /// Vault-relative, `/`-joined.
        var directories: [String] = []
    }

    /// Depth-first over `root`. `root` must already be canonical: every URL
    /// yielded is built by appending to it, so it inherits the spelling.
    static func walk(_ root: URL) -> Result {
        var result = Result()
        visit(root, relative: [], rules: [], into: &result)
        return result
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

    private static func visit(
        _ dir: URL, relative: [String], rules: [GitignoreRules],
        into result: inout Result
    ) {
        var rules = rules
        if let own = GitignoreRules(directory: dir, relative: relative) { rules.append(own) }
        // Names, then appended to `dir`: every URL keeps the root's canonical
        // spelling (`contentsOfDirectory(at:)` re-spells `/var` as `/private/var`).
        // `try?`: a probe — an unlistable folder contributes no files.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        for name in names {
            if name.hasPrefix(".") { continue }
            let url = dir.appendingPathComponent(name)
            let path = relative + [name]
            // `try?`: a probe — an entry that cannot be stat'ed is walked as a plain file.
            let values = try? url.resourceValues(forKeys: keys)
            let isPackage = values?.isPackage == true
            let isDirectory = values?.isDirectory == true && !isPackage
            if GitignoreRules.ignores(path, isDirectory: isDirectory, rules: rules) { continue }
            if isDirectory {
                if ignoredFolderNames.contains(name) { continue }
                let joined = path.joined(separator: "/")
                if ignoredFolderPaths.contains(where: { joined == $0 || joined.hasSuffix("/" + $0) }) {
                    continue
                }
                result.directories.append(joined)
                visit(url, relative: path, rules: rules, into: &result)
            } else if isIndexable(url) {
                result.files.append(url)
            }
        }
    }
}

/// One `.gitignore` file, the common subset of its syntax: comments, blank
/// lines, `!` negation, trailing `/` (directories only), leading or inner `/`
/// (anchored to the file's folder), `*`/`?`/`[…]` globs, and `**/` / `/**`.
/// `ponytail:` a glob per rule via fnmatch, not git's matcher — an inner
/// `a/**/b` matches `*` across `/` too, which over-ignores slightly. Shell out
/// to `git check-ignore` if a real vault proves this wrong.
struct GitignoreRules {
    struct Rule {
        var pattern: String
        var negated: Bool
        var directoryOnly: Bool
        var anchored: Bool
    }

    /// Path components of the folder holding this `.gitignore`, vault-relative.
    let base: [String]
    let rules: [Rule]

    init?(directory: URL, relative: [String]) {
        let file = directory.appendingPathComponent(".gitignore")
        // `try?`: a probe — no readable `.gitignore` means no rules here.
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        self.init(text: text, base: relative)
    }

    init(text: String, base: [String]) {
        self.base = base
        rules = text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw)
            while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { return nil }
            var rule = Rule(pattern: line, negated: false, directoryOnly: false, anchored: false)
            if rule.pattern.hasPrefix("!") {
                rule.negated = true
                rule.pattern.removeFirst()
            }
            if rule.pattern.hasPrefix("\\") { rule.pattern.removeFirst() }
            if rule.pattern.hasSuffix("/**") {
                rule.pattern.removeLast(3)
                rule.directoryOnly = true
            }
            if rule.pattern.hasSuffix("/") {
                rule.pattern.removeLast()
                rule.directoryOnly = true
            }
            if rule.pattern.hasPrefix("**/") {
                rule.pattern.removeFirst(3)
            } else if rule.pattern.contains("/") {
                rule.anchored = true
            }
            if rule.pattern.hasPrefix("/") { rule.pattern.removeFirst() }
            return rule.pattern.isEmpty ? nil : rule
        }
    }

    /// Last matching rule wins, across every `.gitignore` from the vault root
    /// down — git's precedence. `path` is vault-relative.
    static func ignores(_ path: [String], isDirectory: Bool, rules: [GitignoreRules]) -> Bool {
        var ignored = false
        for file in rules {
            guard path.count > file.base.count, Array(path.prefix(file.base.count)) == file.base
            else { continue }
            let local = path.dropFirst(file.base.count).joined(separator: "/")
            let name = path.last ?? ""
            for rule in file.rules where !(rule.directoryOnly && !isDirectory) {
                let matched =
                    rule.anchored
                    ? fnmatch(rule.pattern, local, FNM_PATHNAME) == 0
                        || (rule.pattern.contains("**")
                            && fnmatch(
                                rule.pattern.replacingOccurrences(of: "**/", with: "*"),
                                local, 0) == 0)
                    : fnmatch(rule.pattern, name, 0) == 0
                if matched { ignored = !rule.negated }
            }
        }
        return ignored
    }
}
