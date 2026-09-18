import SwiftUI
import AinkradAppKit

public struct LoreApp: AinkradApp {
    public static let id = "lore"
    public static let displayName = "Lore"
    public static let icon = "book.closed"

    /// Keyed by the HOST-MINTED instance id, not by `ObjectIdentifier(host)`.
    ///
    /// The old key was the address of a box around a non-class-bound
    /// existential: reusable after free, so a new host could be handed the
    /// previous host's store — and this store owns an open SQLite connection
    /// and its file descriptor. Nothing was ever evicted either, so every store
    /// ever created lived for the process. `PluginInstanceStorage` fixes both:
    /// value keys that are never recycled, plus eviction in `teardown`.
    @MainActor private static let stores = PluginInstanceStorage<LoreStore>()

    /// The instance key for `host`.
    ///
    /// A generation-8 host mints one. A generation-7 host does not implement
    /// `PluginInstanceIdentity`, so fall back to the OLD per-host object
    /// identity rather than to one shared id — collapsing every legacy host
    /// onto a single key would make two hosts share a store, which is a
    /// regression rather than a fallback. The address-reuse hazard stays only
    /// on the legacy path, exactly as before, and is gone on generation 8.
    @MainActor private static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    @MainActor private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    @MainActor private static func store(for host: HostServices) -> LoreStore {
        stores.value(for: instance(of: host)) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.ainkrad.plugin.lore", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return LoreStore(documents: host.documents, indexPath: dir.appendingPathComponent("index.sqlite"))
        }
    }

    /// The per-host MCP server, created once and cached — the same shape as
    /// `stores`, keyed by the same instance id, because the server MUST drive
    /// the store the window is showing. Building a fresh store per call would
    /// hand the assistant a detached second SQLite connection with its own
    /// external-change bookkeeping, and nothing it wrote would appear in the UI.
    @MainActor private static let mcpServers = PluginInstanceStorage<MCPAppServer>()

    @MainActor static func mcpServer(for host: HostServices) -> MCPAppServer {
        mcpServers.value(for: instance(of: host)) {
            let operations = LoreNoteOperations(store: store(for: host))
            let (server, failures) = LoreMCPServer.make(
                appID: id,
                perform: { json in await operations.run(json) },
                vaultSummary: { operations.vaultSummary() })
            // A dropped tool is a silently missing capability — say so rather
            // than let the assistant just never see it.
            if !failures.isEmpty {
                host.log.error("Lore MCP: tools rejected — \(failures.joined(separator: ", "))")
            }
            return server
        }
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(LoreRootView(store: store(for: host), theme: host.theme))
    }
    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(LoreSettingsView(store: store(for: host), theme: host.theme))
    }
    public static func chromeFill(host: HostServices) -> Color? { host.theme.tokens.background }
}

/// Publishes Lore's note operations to the host assistant as MCP tools.
/// Cached per host by `mcpServer(for:)`, so the assistant and the UI share one
/// store — and therefore one index, one vault watcher, and one view of which
/// notes have changed on disk.
extension LoreApp: AinkradAppMCP {
    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        mcpServer(for: host)
    }
}

/// Generation 8: release this instance's resources when the host closes it.
/// Lore holds the heaviest of any plugin — an open SQLite database, its file
/// descriptor, and an FSEvents vault watcher — all of which used to outlive the
/// app for the rest of the process.
extension LoreApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        stores.remove(instance)?.shutdown()
        // The MCP server captures the store (and so its SQLite handle) in every
        // tool closure — leaving it registered would keep a shut-down store
        // alive for the rest of the process and let the assistant keep calling
        // into a vault-less instance.
        mcpServers.remove(instance)
    }
}
