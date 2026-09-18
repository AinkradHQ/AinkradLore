import Foundation
import AinkradAppKit
import LoreFeature

@objc(LoreEntryPoint)
final class LoreEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { LoreApp.self }
}
