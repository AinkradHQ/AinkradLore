import Foundation
import AinkradAppKit

/// Publishes Lore's note operations to the host assistant as MCP tools.
///
/// The shape follows Git Mage's `GitMageMCPServer` — a declarative tool table,
/// `[GuardRule]` arrays for `rejects`/`injects`, and a `make` that accumulates
/// `addTool` failures — because the split-tool safety pattern it encodes is not
/// Git-specific. Two things deliberately differ, and both are consequences of
/// Lore not being Git Mage:
///
/// 1. **There is no `repoPath`.** Git Mage is multi-repo, so every tool had to
///    be told which repository to act on. Lore has exactly one vault per
///    instance, held by the `LoreStore` this server was built around, so the
///    equivalent scoping argument does not exist. What replaces it is the
///    *vault-not-configured* check in `LoreNoteOperations.run` — see there.
/// 2. **Arguments are FLAT, not nested under `args`.** Git Mage nests because
///    its sink was a pre-existing `{operation, repoPath, args}` action seam it
///    had to keep speaking. Lore has no such seam, so nesting would be pure
///    ceremony that the model has to get right for no benefit. The guard
///    machinery is unchanged apart from reading the rule's key off the
///    top-level arguments object instead of a nested one.
///
/// ## Destructive classification
///
/// `destructive` is what the host's Full-auto guard gates on, so the question
/// is "can this be undone", not "is this visible".
///
/// - `search_notes`, `read_note`, `list_tags`, `list_folders` — `readOnly`,
///   plainly not destructive; they never touch the filesystem for writing.
/// - `create_note` — **false.** Purely additive: it writes a brand-new file at
///   a path `LoreStore.uniqueURL` guarantees is unused, so it overwrites
///   nothing, and a wrong note is fully remediable with `delete_note`. Same
///   reasoning that leaves `pr_create` ungated in Git Mage.
/// - `save_note` — **false**, per the classification this work was specified
///   against. It is the weakest member of that group and the report filed with
///   this change argues the point: a save replaces a user's file contents with
///   no undo and no version history. Two things reduce the blast radius enough
///   to live with the flag: the tool patches (a field the caller omits is left
///   exactly as it was on disk, so it cannot blank a body it never sent), and
///   it refuses to write over changes made outside Ainkrad — see below.
/// - `delete_note` — **true**, still. It now goes through `LoreStore.trash`, so
///   the file is in the user's Trash rather than unlinked, and is restorable
///   from Finder. That is a real reduction in blast radius but not an undo:
///   nothing in Ainkrad can put the note back, the index entry is gone, and
///   every inbound link to it is left deliberately unresolved. `destructive`
///   asks "can this be undone", and the answer is still no.
/// - `save_note_overwriting` — **true**, and it is the interesting one.
///
/// ## The split pair
///
/// `LoreStore.save(_:overwritingExternalChanges:)` refuses to write when the
/// file changed on disk since Lore last saw it, *unless* that flag is set. The
/// flag therefore turns an ordinary, guarded save into one that silently
/// destroys somebody else's edit — an edit made in Obsidian, by a sync client,
/// or by the agent's own `edit_file`. That is irreversibility decided by an
/// ARGUMENT, which MCP's static `destructiveHint` cannot express. So, exactly
/// as with `reset`/`reset_hard` and `pr_review`/`pr_approve`, the operation is
/// split: `save_note` REJECTS the flag and `save_note_overwriting` is the
/// `destructive: true` twin that injects it itself.
///
/// The rejection is the load-bearing half. Without it the flag would still be
/// reachable through the tool the host does not gate.
@MainActor
enum LoreMCPServer {
    /// One published tool.
    struct Tool {
        /// The MCP tool name (snake_case, MCP convention).
        let name: String
        /// The operation token forwarded to `LoreNoteOperations`.
        let operation: String
        let summary: String
        /// Surfaced as `destructiveHint`; the host gates irreversible calls on it.
        let destructive: Bool
        let readOnly: Bool
        /// The tool's JSON Schema, as a literal JSON string. Held as a string
        /// rather than a `[String: Any]` because the table is a `static let`
        /// and `Any` is not `Sendable`; `MCPToolSpec` wants a string anyway.
        let schemaJSON: String

        /// Argument keys this tool must refuse — the caller has to use the
        /// destructive twin instead. Refusing
        /// `("overwritingExternalChanges", .bool(true))` means that flag never
        /// reaches `LoreStore.save` through the ungated tool.
        ///
        /// **An ARRAY, not a single rule**, so one operation can guard more
        /// than one argument. The call is refused if **ANY** rule matches —
        /// the safe direction, since adding a rule only ever narrows what the
        /// ungated tool accepts.
        ///
        /// **Each rule is an EXACT match, and that is safe only because it
        /// uses the same coercion as its sink.** Lore exposes no pure
        /// classifier to delegate to — `save`'s flag is a plain `Bool`
        /// parameter, not a parsed token like `ReviewEvent`, so there is
        /// nothing to call in the way `pr_review` calls
        /// `PrOpActionHandler.reviewEvent`. The rule is therefore a MIRROR of
        /// the sink, and the sink is
        /// `(object["overwritingExternalChanges"] as? Bool) ?? false` in
        /// `LoreNoteOperations.saveNote`, feeding straight into `save`'s
        /// `overwritingExternalChanges:`. `as? Bool` at both ends means:
        /// `"true"`, `"yes"` and `["true"]` are false at the SINK, so they are
        /// harmless when the guard lets them past; `1` bridges to `NSNumber`,
        /// which `as? Bool` accepts at BOTH ends, so the guard catches it.
        ///
        /// **If that coercion is ever loosened** — a string-to-bool step, an
        /// `"yes"` alias, a case-insensitive parse — this rule MUST be widened
        /// in the same commit, or `save_note` becomes an ungated overwrite of
        /// other people's edits. `LoreMCPServerTests` pins the coupling through
        /// the REAL `LoreStore`
        /// (`theSaveSinkOnlyOverwritesOnAnActualBooleanTrue`), so loosening it
        /// fails there first.
        var rejects: [GuardRule] = []

        /// Argument keys this tool sets itself, ignoring whatever was passed.
        /// **ALL** listed values are injected — the destructive twin owns every
        /// argument its safe counterpart refuses.
        ///
        /// Two invariants hold across the whole table and are checked
        /// structurally, without naming any pair, in `LoreMCPServerTests`:
        /// `everyInjectingToolIsDestructive`, and
        /// `everyRejectedArgumentHasAPublishedInjectingTwin`. A future pair is
        /// covered without touching those tests.
        var injects: [GuardRule] = []

        init(_ name: String, _ operation: String, _ summary: String,
             destructive: Bool = false, readOnly: Bool = false,
             schemaJSON: String,
             rejects: [GuardRule] = [],
             injects: [GuardRule] = []) {
            self.name = name
            self.operation = operation
            self.summary = summary
            self.destructive = destructive
            self.readOnly = readOnly
            self.schemaJSON = schemaJSON
            self.rejects = rejects
            self.injects = injects
        }
    }

    /// One guarded argument key/value pair.
    struct GuardRule {
        let key: String
        let value: ArgumentValue
        init(_ key: String, _ value: ArgumentValue) {
            self.key = key
            self.value = value
        }
    }

    /// The argument shapes the reject/inject rules need. Exact matches, safe
    /// only because their sinks are exact too (see `Tool.rejects`).
    enum ArgumentValue {
        case string(String)
        case bool(Bool)

        /// Whether a value decoded from the call's arguments equals this one.
        func matches(_ any: Any) -> Bool {
            switch self {
            case .string(let s): return (any as? String) == s
            case .bool(let b):   return (any as? Bool) == b
            }
        }

        var foundation: Any {
            switch self {
            case .string(let s): return s
            case .bool(let b):   return b
            }
        }

        var described: String {
            switch self {
            case .string(let s): return "\"\(s)\""
            case .bool(let b):   return "\(b)"
            }
        }
    }

    // MARK: - the table

    static let tools: [Tool] = [
        Tool("search_notes", "search",
             "Search the Lore vault's notes by full text. Returns each match's id, title, "
             + "tags and vault-relative path. Omit the query to list the most recently "
             + "updated notes instead.",
             readOnly: true,
             schemaJSON: schema(
                properties: [
                    ("query", "string", "Full-text query. Omit or leave empty to list recent notes."),
                    ("limit", "integer", "Maximum results (default 25)."),
                ], required: [])),

        Tool("read_note", "read",
             "Read one note's title, tags and full body.",
             readOnly: true,
             schemaJSON: schema(
                properties: [noteIdentifier], required: ["note"])),

        Tool("list_tags", "listTags",
             "List every tag used across the vault.",
             readOnly: true,
             schemaJSON: schema(properties: [], required: [])),

        Tool("list_folders", "listFolders",
             "List the vault root's immediate subfolders.",
             readOnly: true,
             schemaJSON: schema(properties: [], required: [])),

        Tool("create_note", "create",
             "Create a new note in the vault. The file is always written to a fresh path, "
             + "so this never overwrites an existing note.",
             schemaJSON: schema(
                properties: [
                    ("title", "string", "The note's title. Also seeds its filename."),
                    ("body", "string", "Optional markdown body."),
                    ("tags", "array", "Optional list of tag strings."),
                ], required: ["title"])),

        Tool("save_note", "save",
             "Update an existing note. Only the fields you send are changed; anything you "
             + "omit is left exactly as it is on disk. Refuses to write if the file was "
             + "edited outside Ainkrad since Lore last read it — use save_note_overwriting "
             + "to discard those outside edits deliberately.",
             schemaJSON: schema(
                properties: [
                    noteIdentifier,
                    ("title", "string", "Optional new title."),
                    ("body", "string", "Optional new markdown body. Replaces the whole body."),
                    ("tags", "array", "Optional replacement list of tag strings."),
                ], required: ["note"],
                trailer: "\"overwritingExternalChanges\" is refused here — call "
                    + "save_note_overwriting to discard edits made outside Ainkrad."),
             rejects: [GuardRule("overwritingExternalChanges", .bool(true))]),

        Tool("save_note_overwriting", "save",
             "Update an existing note, DISCARDING any edits made to its file outside "
             + "Ainkrad since Lore last read it. Those edits are not recoverable. Prefer "
             + "save_note, and use this only after read_note has shown you the current "
             + "on-disk contents.",
             destructive: true,
             schemaJSON: schema(
                properties: [
                    noteIdentifier,
                    ("title", "string", "Optional new title."),
                    ("body", "string", "Optional new markdown body. Replaces the whole body."),
                    ("tags", "array", "Optional replacement list of tag strings."),
                ], required: ["note"],
                trailer: "overwritingExternalChanges is always true."),
             injects: [GuardRule("overwritingExternalChanges", .bool(true))]),

        Tool("delete_note", "delete",
             "Delete a note. The file is moved to the macOS Trash, so it can be restored "
             + "from Finder, but nothing in Ainkrad can undo this: the note leaves the "
             + "vault index and every link to it becomes unresolved. Refuses if the note "
             + "is open in Lore with unsaved edits that cannot be saved.",
             destructive: true,
             schemaJSON: schema(properties: [noteIdentifier], required: ["note"])),
    ]

    /// Every write tool identifies its target the same way, so the description
    /// is written once. Ids come from `search_notes`; a path is accepted too
    /// because the assistant often already has one from the filesystem tools.
    private static let noteIdentifier: (String, String, String) = (
        "note", "string",
        "The note's id (as returned by search_notes) or its absolute file path."
    )

    /// The single published resource's URI.
    static let vaultResourceURI = "lore://vault"

    // MARK: - assembly

    /// Builds the server. `perform` receives a JSON object string of the shape
    /// `{"operation": ..., <the call's arguments>}` — in production
    /// `LoreNoteOperations.run`.
    ///
    /// Returns the names of any tools `addTool` refused alongside the server: a
    /// dropped tool is a silently missing capability, so the caller must not be
    /// able to ignore it by accident.
    /// `vaultSummary` backs the one published resource, `lore://vault`. It is a
    /// resource rather than a tool because it is ambient, cheap and answers the
    /// question the model asks first — "is there a vault, and where" — without
    /// spending a tool call. Note that it deliberately does NOT expose the
    /// currently-open note: which note is on screen lives in the root view's
    /// selection state, which this layer has no clean handle on, and reaching
    /// for it would mean a second observable seam for one string.
    static func make(appID: String,
                     perform: @escaping @MainActor @Sendable (String) async -> AgentActionResult,
                     vaultSummary: (@MainActor @Sendable () async -> String)? = nil)
        -> (server: MCPAppServer, failures: [String]) {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []
        if let vaultSummary {
            let added = server.addResource(MCPResourceSpec(
                uri: vaultResourceURI,
                title: "Lore vault",
                provider: vaultSummary))
            if !added { failures.append(vaultResourceURI) }
        }
        for tool in tools {
            let added = server.addTool(MCPToolSpec(
                name: tool.name,
                description: tool.summary,
                schemaJSON: tool.schemaJSON,
                destructive: tool.destructive,
                readOnly: tool.readOnly,
                handler: { arguments in await invoke(tool, arguments: arguments, perform: perform) }
            ))
            if !added { failures.append(tool.name) }
        }
        return (server, failures)
    }

    // MARK: - call handling

    /// Internal rather than `private` so the tests can drive a test-only
    /// two-guard `Tool` fixture through the real gate/inject logic without
    /// bending the live `tools` table.
    static func invoke(_ tool: Tool, arguments: String,
                       perform: @MainActor @Sendable (String) async -> AgentActionResult)
        async -> AgentActionResult {
        guard let data = arguments.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AgentActionResult(text: "\(tool.name): malformed arguments", isError: true)
        }

        // The gate: the irreversible behaviour must not be reachable through a
        // tool the host does not treat as destructive. ANY matching rule
        // refuses the call — more rules only ever narrow what gets through.
        for rule in tool.rejects {
            guard let passed = object[rule.key], rule.value.matches(passed) else { continue }
            return AgentActionResult(
                text: "\(tool.name) refuses \(rule.key) = \(rule.value.described) — "
                    + "it is irreversible and needs approval. Use the dedicated tool instead.",
                isError: true)
        }
        // ALL injected values are applied — the destructive twin owns every
        // argument its safe counterpart refuses.
        for rule in tool.injects { object[rule.key] = rule.value.foundation }

        object["operation"] = tool.operation
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            return AgentActionResult(text: "\(tool.name): could not encode the request", isError: true)
        }
        return await perform(String(decoding: payload, as: UTF8.self))
    }

    // MARK: - schema

    /// Builds a tool's JSON Schema string from a flat property list. Returns a
    /// string so the tool table stays a `Sendable` `static let`.
    private static func schema(properties: [(String, String, String)],
                               required: [String],
                               trailer: String? = nil) -> String {
        var props: [String: Any] = [:]
        for (name, type, description) in properties {
            var entry: [String: Any] = ["type": type, "description": description]
            // JSON Schema requires `items` on an array; every array argument
            // Lore takes today is a list of tag strings.
            if type == "array" { entry["items"] = ["type": "string"] }
            props[name] = entry
        }
        var schema: [String: Any] = ["type": "object", "properties": props, "required": required]
        if let trailer { schema["description"] = trailer }
        guard let data = try? JSONSerialization.data(withJSONObject: schema) else {
            return #"{"type":"object"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
