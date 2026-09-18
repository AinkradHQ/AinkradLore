import Foundation
import AppKit
import Observation

/// What the import surface is currently showing.
///
/// `.needsAutomation` arrives with `AppleNotesScriptSource`, the source that can
/// produce it. `.needsFullDiskAccess` is still deliberately absent: the SQLite
/// fast path is not wired to any call site, so nothing can reach that state and
/// a state no code path reaches is a state no test can prove works.
public enum ImportEntryState {
    case choosingSource
    case scanning
    case previewing(ImportSelection)
    case finished(ImportReport)
    /// Distinct from `.failed` because it is FIXABLE by the user, and the fix is
    /// one button away. A denial rendered as a generic error sentence leaves
    /// them reading about a switch with no way to reach it.
    case needsAutomation(String)
    case failed(String)
}

/// Drives one import from "pick a folder" to "here is what landed".
///
/// A plain observable object rather than view state, for the reason the rest of
/// this codebase already gives (`SidebarOperations`): SwiftUI is only
/// smoke-testable here, and the behaviour worth asserting — that a scan
/// produces a selection seeded with the ids the vault already holds, that a
/// vault cannot be imported into itself — is not layout.
@MainActor
@Observable
public final class ImportCoordinator: Identifiable {
    public private(set) var state: ImportEntryState = .choosingSource
    private let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot
    }

    /// Asks for an Obsidian vault and scans it.
    ///
    /// The panel is here and the work is in `scan(_:)` so tests exercise the
    /// whole pipeline without a modal — the M3 lesson about logic that is only
    /// reachable through a view being logic nothing tests.
    public func chooseObsidianVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the Obsidian vault to import into Lore."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await scan(ObsidianSource(vaultURL: folder), sourceRoot: folder) }
    }

    /// Imports Apple Notes through `AppleNotesScriptSource` — the AppleScript
    /// route, not the SQLite one.
    ///
    /// The fast path reads `NoteStore.sqlite`, which needs Full Disk Access;
    /// that grant could not be obtained on this machine, and the note body in
    /// that store is an undocumented gzipped protobuf whose layout is still
    /// unverified. This route asks Notes.app itself: slower on a large library,
    /// blind to locked notes, and supported.
    public func importAppleNotes() {
        Task { await scan(AppleNotesScriptSource(), sourceRoot: nil) }
    }

    /// Opens the Automation pane directly. Telling the user where the switch is
    /// and making them find it are different products.
    public func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Scans `source` and moves to the preview.
    ///
    /// `sourceRoot` is separate from the source object because the nesting
    /// check below is about DIRECTORIES, and not every `ImportSource` has one
    /// (Apple Notes does not). Pass nil when the source is not a folder.
    public func scan(_ source: some ImportSource, sourceRoot: URL?) async {
        if let sourceRoot, let reason = Self.nestingRefusal(source: sourceRoot,
                                                            target: vaultRoot) {
            state = .failed(reason)
            return
        }
        state = .scanning
        do {
            let items = try await source.scan()
            guard !items.isEmpty else {
                state = .failed(sourceRoot == nil
                    ? "There were no notes to import."
                    : "There was nothing to import in that folder.")
                return
            }
            // The reader runs HERE, once, against the live vault — not at
            // apply time. Seeding the selection with it is what makes the
            // preview honest about what a re-run will actually skip, instead
            // of offering the user a checkbox for work that is already done.
            let existing = ImportIDReader.read(vaultRoot: vaultRoot)
            state = .previewing(ImportSelection(items: items, vaultRoot: vaultRoot,
                                                existingImportIDs: existing))
        } catch let error as ImportSourceError {
            // Only Apple Notes maps a denial to the Automation state. An
            // unreadable Obsidian folder is also `.permissionDenied`, and
            // pointing THAT at the Automation pane would send the user to flip
            // a switch that has nothing to do with their problem.
            if case .permissionDenied(let detail) = error,
               type(of: source).identifier == AppleNotesScriptSource.identifier {
                state = .needsAutomation(detail)
            } else {
                state = .failed(Self.describe(error))
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Writes the plan the user approved — `plan` as handed to this call, never
    /// a freshly recomputed one. Recomputing here would break the dry-run
    /// promise in the least visible way possible: the preview would be a
    /// description of a different run.
    public func apply(_ plan: ImportPlan) async {
        state = .finished(await ImportApplier(vaultRoot: vaultRoot).apply(plan))
    }

    public func reset() { state = .choosingSource }

    /// Importing a vault into itself, or into its own parent, would have the
    /// scan walk into what the apply step is writing — at best duplicating
    /// every file, at worst never terminating. Refused before anything is read.
    static func nestingRefusal(source: URL, target: URL) -> String? {
        let s = URL(fileURLWithPath: source.resolvingSymlinksInPath().path)
            .standardizedFileURL.pathComponents
        let t = URL(fileURLWithPath: target.resolvingSymlinksInPath().path)
            .standardizedFileURL.pathComponents
        if s == t {
            return "That folder is this vault. Choose a different folder to import from."
        }
        if s.count > t.count, Array(s.prefix(t.count)) == t {
            return "That folder is already inside this vault, so there is nothing to import."
        }
        if t.count > s.count, Array(t.prefix(s.count)) == s {
            return "This vault is inside that folder. Importing it would copy the vault "
                + "into itself. Choose a folder that does not contain the vault."
        }
        return nil
    }

    static func describe(_ error: ImportSourceError) -> String {
        switch error {
        case .permissionDenied(let detail):
            "Lore is not allowed to read that source. \(detail)"
        case .unsupportedSchema(let detail):
            "That source is in a format Lore does not recognise (\(detail))."
        case .sourceUnavailable(let detail):
            "That source could not be opened: \(detail)"
        }
    }
}
