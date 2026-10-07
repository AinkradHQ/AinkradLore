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
