import AinkradAppKit
import Foundation
import Testing

@testable import LoreFeature

@MainActor
@Suite("Lore's notification vocabulary")
struct LoreSignalReporterTests {
    private final class RecordingEmitter: PluginSignalEmitter {
        struct Call {
            let kind: String
            let severity: SignalSeverity
            let title: String
            let body: String?
            let importance: SignalImportance
            let dedupeKey: String?
        }
        var calls: [Call] = []

        func emit(
            kind: String, severity: SignalSeverity, title: String, body: String?,
            importance: SignalImportance, deepLink: SignalDeepLink?,
            actions: [SignalAction], dedupeKey: String?
        ) {
            calls.append(
                Call(
                    kind: kind, severity: severity, title: title, body: body,
                    importance: importance, dedupeKey: dedupeKey))
        }
        func own(limit: Int) -> [SignalEvent] { [] }
        func handleAction(
            _ actionID: String,
            _ handler: @escaping @MainActor () async -> Void
        ) -> AgentActionToken {
            AgentActionToken()
        }
        func removeActionHandler(_ token: AgentActionToken) {}
    }

    private func reporter() -> (LoreSignalReporter, RecordingEmitter) {
        let emitter = RecordingEmitter()
        return (LoreSignalReporter(signals: emitter), emitter)
    }

    @Test("a clean import reports success with its counts")
    func cleanImport() {
        let (reporter, emitter) = self.reporter()
        reporter.importFinished(imported: 412, skipped: 0, failed: 0)
        #expect(emitter.calls.count == 1)
        #expect(emitter.calls[0].kind == "import.finished")
        #expect(emitter.calls[0].severity == .success)
        #expect(emitter.calls[0].body?.contains("412 files imported") == true)
    }

    @Test("an import with failures is NOT reported as a success")
    func importWithFailures() {
        // 400 written and 3 failed is not a success, and calling it one hides
        // the three the user would want to look at.
        let (reporter, emitter) = self.reporter()
        reporter.importFinished(imported: 400, skipped: 2, failed: 3)
        #expect(emitter.calls[0].severity == .warning)
        #expect(emitter.calls[0].kind == "import.finished-with-errors")
        #expect(emitter.calls[0].body?.contains("3 failed") == true)
        #expect(emitter.calls[0].body?.contains("2 skipped") == true)
    }

    @Test("one imported file reads as singular")
    func singularCount() {
        let (reporter, emitter) = self.reporter()
        reporter.importFinished(imported: 1, skipped: 0, failed: 0)
        #expect(emitter.calls[0].body?.contains("1 file imported") == true)
    }

    @Test("a missing automation permission is the one urgent kind")
    func needsPermissionIsUrgent() {
        // The import is halted and waiting, and the fix is a switch the user
        // can flip right now — the same shape as an agent blocked on input.
        let (reporter, emitter) = self.reporter()
        reporter.importNeedsAutomation(detail: "Allow Ainkrad to control Notes.")
        #expect(emitter.calls[0].importance == .urgent)
        #expect(emitter.calls[0].kind == "import.needs-permission")
    }

    @Test("an outright import failure is a failure, and not urgent")
    func importFailure() {
        let (reporter, emitter) = self.reporter()
        reporter.importFailed(reason: "The folder is not an Obsidian vault.")
        #expect(emitter.calls[0].severity == .failure)
        #expect(emitter.calls[0].importance == .normal)
    }

    @Test("a rescan failure coalesces per reason, and says what it costs")
    func rescanFailure() {
        // A rescan that fails once usually fails every time; without a dedupe
        // key a vanished watched folder would file a row per filesystem event.
        let (reporter, emitter) = self.reporter()
        reporter.vaultRescanFailed(reason: "The vault folder is missing.")
        #expect(emitter.calls[0].severity == .warning)
        #expect(emitter.calls[0].importance == .normal)
        #expect(emitter.calls[0].dedupeKey == "lore.rescan:The vault folder is missing.")
        #expect(emitter.calls[0].body?.contains("out of date") == true)
    }

    @Test("every kind Lore emits is one the host will accept")
    func kindsAreValid() {
        // SignalKind.isValid is the host's gate: a camelCase or spaced kind is
        // rejected at ingest and the notification silently never appears.
        let (reporter, emitter) = self.reporter()
        reporter.importFinished(imported: 1, skipped: 0, failed: 0)
        reporter.importFinished(imported: 1, skipped: 0, failed: 1)
        reporter.importFailed(reason: "x")
        reporter.importNeedsAutomation(detail: "x")
        reporter.vaultRescanFailed(reason: "x")
        #expect(emitter.calls.count == 5)
        for call in emitter.calls {
            #expect(SignalKind.isValid(call.kind), "\(call.kind) would be rejected at ingest")
        }
    }
}
