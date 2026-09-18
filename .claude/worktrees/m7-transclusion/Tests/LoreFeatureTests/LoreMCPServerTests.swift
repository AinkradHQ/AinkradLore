import Testing
import Foundation
import AinkradAppKit
@testable import LoreFeature

// MARK: - harness

/// Records every payload the MCP tools forward, and answers with a fixed result
/// so the guard tests never touch a store at all.
@MainActor
private final class RecordingSink {
    private(set) var payloads: [String] = []

    func perform(_ json: String) async -> AgentActionResult {
        payloads.append(json)
        return AgentActionResult(text: "ok", isError: false)
    }

    var lastObject: [String: Any]? {
        guard let json = payloads.last, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

@MainActor
private func listedTools(_ server: MCPAppServer) async -> [[String: Any]] {
    let reply = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    guard let data = reply.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let result = root["result"] as? [String: Any],
          let tools = result["tools"] as? [[String: Any]] else { return [] }
    return tools
}

@MainActor
private func call(_ server: MCPAppServer, _ name: String,
                  _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
    let request: [String: Any] = [
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try! JSONSerialization.data(withJSONObject: request)
    let reply = await server.handle(String(decoding: data, as: UTF8.self))
    guard let replyData = reply.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any],
          let result = root["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]] else {
        return ("<no result>", true)
    }
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
}

private func destructiveHint(_ tool: [String: Any]) -> Bool {
    (tool["annotations"] as? [String: Any])?["destructiveHint"] as? Bool ?? false
}

/// A `PluginDocumentStore` that keeps nothing — the MCP tests never exercise
/// the bookmark path, they activate a temp vault through the test seam.
private final class MemoryDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

/// A temp vault. **Never the user's real vault** — every store-backed test in
/// this file builds one of these and works only inside it.
@MainActor
private func makeVault() async throws -> (URL, LoreStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lore-mcp-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = LoreStore(documents: MemoryDocs(),
                          indexPath: root.appendingPathComponent(".index.sqlite"))
    try store.setVaultRootForTesting(root)
    await store.settleForTesting()
    return (root, store)
}

/// Spellings of `overwritingExternalChanges` a caller could try in place of the
/// literal `true` the `save_note` guard rejects. (`1` is covered separately: it
/// bridges to `NSNumber`, so `as? Bool` accepts it at BOTH ends and the guard
/// must catch it.)
struct OverwriteEvasion: Sendable, CustomStringConvertible {
    let label: String
    let value: @Sendable () -> Any
    init(_ label: String, _ value: @escaping @Sendable () -> Any) {
        self.label = label
        self.value = value
    }
    var description: String { label }
}

let overwriteEvasions: [OverwriteEvasion] = [
    OverwriteEvasion("string \"true\"") { "true" },
    OverwriteEvasion("string \"TRUE\"") { "TRUE" },
    OverwriteEvasion("string \"yes\"") { "yes" },
    OverwriteEvasion("array wrapping true") { [true] },
    OverwriteEvasion("object wrapping true") { ["overwritingExternalChanges": true] },
]

// MARK: - tests

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoreMCPServerTests {
    private func makeServer(_ sink: RecordingSink) -> (MCPAppServer, [String]) {
        LoreMCPServer.make(appID: "lore",
                           perform: { await sink.perform($0) },
                           vaultSummary: { "summary" })
    }

    // MARK: publication

    @Test func everyToolRegistersSuccessfully() async {
        let (_, failures) = makeServer(RecordingSink())
        #expect(failures.isEmpty, "addTool/addResource rejected: \(failures)")
    }

    @Test func publishesTheWholeTable() async {
        let (server, _) = makeServer(RecordingSink())
        let listed = Set(await listedTools(server).compactMap { $0["name"] as? String })
        #expect(listed == Set(LoreMCPServer.tools.map(\.name)))
    }

    @Test func destructiveAndReadOnlyHintsReachTheWire() async {
        let (server, _) = makeServer(RecordingSink())
        let listed = await listedTools(server)
        for tool in LoreMCPServer.tools {
            guard let entry = listed.first(where: { $0["name"] as? String == tool.name }) else {
                Issue.record("tool \(tool.name) was not listed"); continue
            }
            #expect(destructiveHint(entry) == tool.destructive, "wrong destructiveHint for \(tool.name)")
            #expect((entry["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == tool.readOnly,
                    "wrong readOnlyHint for \(tool.name)")
        }
    }

    @Test func readOnlyToolsAreNeverDestructive() {
        for tool in LoreMCPServer.tools where tool.readOnly {
            #expect(tool.destructive == false, "\(tool.name) is readOnly AND destructive")
        }
    }

    // MARK: the two name-free invariants of the split-tool pattern

    /// Invariant 1, over the WHOLE table rather than by naming pairs: a tool
    /// that injects a dangerous argument itself must carry `destructive: true`,
    /// because that flag is the only thing routing the call to the host's
    /// approval gate. A future pair added without it would be a silent, ungated
    /// irreversible tool — this fails instead.
    @Test func everyInjectingToolIsDestructive() {
        for tool in LoreMCPServer.tools {
            for rule in tool.injects {
                let reason = "\(tool.name) injects \(rule.key) = \(rule.value.described) "
                    + "but is not destructive: true — it would be ungated"
                #expect(tool.destructive, Comment(rawValue: reason))
            }
        }
    }

    /// Invariant 2, also table-driven: every key a tool refuses must remain
    /// reachable through SOME published twin for the same operation that
    /// injects it. Without that, the safe half deletes a capability instead of
    /// gating it. Matched per key and structurally (operation, key, value), so
    /// a future pair is covered without being named here.
    @Test func everyRejectedArgumentHasAPublishedInjectingTwin() async {
        let (server, _) = makeServer(RecordingSink())
        let listed = Set(await listedTools(server).compactMap { $0["name"] as? String })
        for tool in LoreMCPServer.tools {
            for rule in tool.rejects {
                let twin = LoreMCPServer.tools.first { candidate in
                    guard candidate.name != tool.name, candidate.operation == tool.operation else { return false }
                    return candidate.injects.contains { injected in
                        injected.key == rule.key && rule.value.matches(injected.value.foundation)
                    }
                }
                guard let twin else {
                    Issue.record(Comment(rawValue:
                        "\(tool.name) refuses \(rule.key) = \(rule.value.described) but no tool "
                        + "injects it — the capability is gone, not gated"))
                    continue
                }
                #expect(listed.contains(twin.name), Comment(rawValue:
                    "\(twin.name) is the twin for \(tool.name)'s \(rule.key) but was not published"))
            }
        }
    }

    // MARK: forwarding and the gate

    @Test func callForwardsOperationAndArguments() async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)
        let outcome = await call(server, "save_note", ["note": "abc", "body": "hello"])
        #expect(outcome.isError == false)
        #expect(sink.lastObject?["operation"] as? String == "save")
        #expect(sink.lastObject?["note"] as? String == "abc")
        #expect(sink.lastObject?["body"] as? String == "hello")
    }

    @Test func saveNoteRejectsTheOverwriteFlag() async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)
        let outcome = await call(server, "save_note",
                                 ["note": "abc", "body": "x", "overwritingExternalChanges": true])
        #expect(outcome.isError)
        #expect(outcome.text.contains("save_note refuses"))
        #expect(sink.payloads.isEmpty, "a rejected call must never reach the store")
    }

    @Test func saveNoteAllowsTheFlagSetToFalse() async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)
        let outcome = await call(server, "save_note",
                                 ["note": "abc", "overwritingExternalChanges": false])
        #expect(outcome.isError == false)
        #expect(sink.lastObject?["overwritingExternalChanges"] as? Bool == false)
    }

    @Test func saveNoteOverwritingInjectsTheFlag() async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)
        _ = await call(server, "save_note_overwriting", ["note": "abc", "body": "x"])
        #expect(sink.lastObject?["operation"] as? String == "save")
        #expect(sink.lastObject?["overwritingExternalChanges"] as? Bool == true)
    }

    // MARK: evasion of the ungated tool's guard
    //
    // The property is NOT "the call errored" — it is "an overwrite of external
    // changes never happens through the ungated tool". So each case asserts on
    // the payload actually forwarded, resolved through the SINK'S OWN coercion
    // expression (`resolvedOverwrite`).

    /// The exact expression `LoreNoteOperations.saveNote` uses:
    /// `(object["overwritingExternalChanges"] as? Bool) ?? false`.
    private func resolvedOverwrite(_ payload: [String: Any]?) -> Bool {
        guard let payload else { return false }   // nothing forwarded → nothing ran
        return (payload["overwritingExternalChanges"] as? Bool) ?? false
    }

    @Test(arguments: overwriteEvasions)
    func saveNoteNeverOverwritesHoweverTheFlagIsSpelled(evasion: OverwriteEvasion) async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)
        _ = await call(server, "save_note",
                       ["note": "abc", "overwritingExternalChanges": evasion.value()])
        #expect(resolvedOverwrite(sink.lastObject) == false,
                "save_note reached an overwrite via \(evasion.label)")
    }

    @Test func saveNoteRejectsNumericTrueAndIgnoresNearMissKeys() async {
        let sink = RecordingSink()
        let (server, _) = makeServer(sink)

        // `1` bridges to NSNumber, which `as? Bool` accepts — so BOTH the guard
        // and the sink read it as true. The guard must reject it outright.
        let numeric = await call(server, "save_note",
                                 ["note": "abc", "overwritingExternalChanges": 1])
        #expect(numeric.isError)
        #expect(sink.payloads.isEmpty, "overwritingExternalChanges: 1 was forwarded, not rejected")

        // A differently-cased key: missed by the guard, and equally missed by
        // the sink, so no overwrite happens.
        _ = await call(server, "save_note",
                       ["note": "abc", "OverwritingExternalChanges": true])
        #expect(resolvedOverwrite(sink.lastObject) == false, "a mis-cased key reached the sink")
    }

    // MARK: pinning the guard to the real sink
    //
    // Lore exposes no pure classifier for this flag — it is a plain `Bool`
    // parameter on `LoreStore.save`, so there is nothing to DELEGATE to the way
    // `pr_review` delegates to `PrOpActionHandler.reviewEvent`. The guard is
    // therefore a MIRROR, and a mirror needs a test that fails when the thing
    // it mirrors moves.

    /// Drives the REAL `LoreStore`, not a copy of its logic: only an actual
    /// boolean `true` may bypass the external-change refusal.
    ///
    /// If `save` is ever made tolerant — a string-to-bool coercion, a "yes"
    /// alias, anything that makes a non-`Bool` value overwrite — this fails
    /// first, and `LoreMCPServer`'s
    /// `GuardRule("overwritingExternalChanges", .bool(true))` must be widened
    /// in the same commit, or `save_note` becomes an ungated destroyer of edits
    /// made outside Ainkrad.
    @Test func theSaveSinkOnlyOverwritesOnAnActualBooleanTrue() async throws {
        let (root, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        var note = try store.create(title: "Pinned")
        note.body = "mine"
        try store.save(note)

        // Someone edits the file outside Ainkrad.
        try externallyEdit(note.path, to: "theirs")

        // The default refuses.
        #expect(throws: LoreError.externalChange(note.path)) {
            try store.save(note)
        }
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("theirs"))

        // And ONLY the flag lets it through — which is exactly the argument the
        // ungated tool refuses and the destructive twin injects.
        try store.save(note, overwritingExternalChanges: true)
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("mine"))
    }

    /// The other half of the mirror: the operations layer's coercion. A string
    /// `"true"` must NOT become an overwrite, because the guard lets that value
    /// past on the assumption that the sink reads it as false.
    @Test func aStringTrueDoesNotOverwriteThroughTheOperationsLayer() async throws {
        let (root, store) = try await makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = LoreNoteOperations(store: store)

        var note = try store.create(title: "Stringy")
        note.body = "mine"
        try store.save(note)
        try externallyEdit(note.path, to: "theirs")

        let outcome = await operations.run(payload([
            "operation": "save", "note": note.id, "body": "mine again",
            "overwritingExternalChanges": "true",
        ]))
        #expect(outcome.isError, "a string \"true\" was coerced into an overwrite")
        #expect(outcome.text.contains("save_note_overwriting"),
                "the conflict must name the tool that can resolve it")
        #expect(try String(contentsOf: note.path, encoding: .utf8).contains("theirs"))
    }

    // MARK: - multi-guard capability (array shape)
    //
    // No Lore operation needs two guarded arguments today, so this drives a
    // test-only fixture pair through the REAL gate/inject logic rather than
    // fabricating an operation in the live table.

    private static let fixtureSafe = LoreMCPServer.Tool(
        "fixture_multi_safe", "fixtureMulti", "test-only two-guard fixture",
        schemaJSON: #"{"type":"object"}"#,
        rejects: [LoreMCPServer.GuardRule("overwritingExternalChanges", .bool(true)),
                  LoreMCPServer.GuardRule("mode", .string("purge"))])

    private static let fixtureDestructive = LoreMCPServer.Tool(
        "fixture_multi_destructive", "fixtureMulti", "test-only two-guard fixture twin",
        destructive: true, schemaJSON: #"{"type":"object"}"#,
        injects: [LoreMCPServer.GuardRule("overwritingExternalChanges", .bool(true)),
                  LoreMCPServer.GuardRule("mode", .string("purge"))])

    private func invokeFixture(_ tool: LoreMCPServer.Tool, _ arguments: [String: Any],
                               sink: RecordingSink) async -> (text: String, isError: Bool) {
        let result = await LoreMCPServer.invoke(tool, arguments: payload(arguments),
                                                perform: { await sink.perform($0) })
        return (result.text, result.isError)
    }

    @Test func fixtureSafeToolRefusesEitherGuardedArgumentAlone() async {
        let sink = RecordingSink()
        let byFlag = await invokeFixture(Self.fixtureSafe,
                                         ["overwritingExternalChanges": true], sink: sink)
        #expect(byFlag.isError)
        #expect(sink.payloads.isEmpty)

        let byMode = await invokeFixture(Self.fixtureSafe, ["mode": "purge"], sink: sink)
        #expect(byMode.isError)
        #expect(sink.payloads.isEmpty)
    }

    @Test func fixtureSafeToolRefusesBothGuardedArgumentsTogether() async {
        let sink = RecordingSink()
        let outcome = await invokeFixture(
            Self.fixtureSafe, ["overwritingExternalChanges": true, "mode": "purge"], sink: sink)
        #expect(outcome.isError)
        #expect(sink.payloads.isEmpty)
    }

    @Test func fixtureSafeToolAllowsNeitherGuardedArgument() async {
        let sink = RecordingSink()
        let outcome = await invokeFixture(Self.fixtureSafe, ["mode": "gentle"], sink: sink)
        #expect(outcome.isError == false)
        #expect(sink.lastObject?["mode"] as? String == "gentle")
    }

    @Test func fixtureDestructiveTwinInjectsBothGuardedArguments() async {
        let sink = RecordingSink()
        _ = await invokeFixture(Self.fixtureDestructive, [:], sink: sink)
        #expect(sink.lastObject?["overwritingExternalChanges"] as? Bool == true)
        #expect(sink.lastObject?["mode"] as? String == "purge")
    }

    @Test func malformedArgumentsAreAnErrorNotAForwardedCall() async {
        let sink = RecordingSink()
        let result = await LoreMCPServer.invoke(Self.fixtureSafe, arguments: "not json",
                                                perform: { await sink.perform($0) })
        #expect(result.isError)
        #expect(sink.payloads.isEmpty)
    }
}

// MARK: - shared helpers

/// Encodes a tool call's arguments the way `MCPAppServer` hands them to a handler.
@MainActor
private func payload(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// Rewrites a note's file behind the store's back and forces its mtime forward,
/// simulating an edit in Obsidian or by a sync client.
///
/// The bump is explicit because `LoreStore.externalChangeDetected` compares
/// modification dates: two writes inside the filesystem's timestamp granularity
/// would leave the test asserting on a race rather than on the guard.
private func externallyEdit(_ url: URL, to body: String) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let head = text.components(separatedBy: "---").prefix(3).joined(separator: "---")
    try (head + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
}
