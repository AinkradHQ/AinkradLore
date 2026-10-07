import AinkradAppKit
import os

/// This repo's `os.Logger` categories, all under the shared Ainkrad
/// subsystem (`com.ainkrad.app`) so a user's whole install filters as one
/// stream in Console.app. Categories are `lore.<area>`.
enum Log {
    static let store = AinkradLog.logger(app: "lore", area: "store")
    static let editor = AinkradLog.logger(app: "lore", area: "editor")
    static let import_ = AinkradLog.logger(app: "lore", area: "import")
    static let search = AinkradLog.logger(app: "lore", area: "search")
    static let watcher = AinkradLog.logger(app: "lore", area: "watcher")
}

extension Logger {
    /// `try?` that leaves a trace: the same `nil` on a throw, plus one `.error`
    /// line naming `what` and the error. A `nil` the body returns WITHOUT
    /// throwing (no index open, "never recorded") passes through unlogged.
    @discardableResult
    func orNil<T>(_ what: String, _ body: () throws -> T?) -> T? {
        do {
            return try body()
        } catch {
            self.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
