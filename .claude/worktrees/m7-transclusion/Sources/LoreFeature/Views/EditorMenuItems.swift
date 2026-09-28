import AppKit
import AinkradAppKit

/// Everything the editor's context menu can do, injected so the builder stays
/// pure and the tests need no text view.
public struct EditorMenuActions {
    var cut: () -> Void = {}
    var copy: () -> Void = {}
    var paste: () -> Void = {}
    var selectAll: () -> Void = {}
    var link: () -> Void = {}
    var code: () -> Void = {}
    var heading: () -> Void = {}
    var replace: (String) -> Void = { _ in }
    var ignoreSpelling: () -> Void = {}
    var learnSpelling: () -> Void = {}

    init(cut: @escaping () -> Void = {}, copy: @escaping () -> Void = {},
        paste: @escaping () -> Void = {}, selectAll: @escaping () -> Void = {},
        link: @escaping () -> Void = {}, code: @escaping () -> Void = {},
        heading: @escaping () -> Void = {}, replace: @escaping (String) -> Void = { _ in },
        ignoreSpelling: @escaping () -> Void = {}, learnSpelling: @escaping () -> Void = {}) {
        self.cut = cut; self.copy = copy; self.paste = paste; self.selectAll = selectAll
        self.link = link; self.code = code; self.heading = heading; self.replace = replace
        self.ignoreSpelling = ignoreSpelling; self.learnSpelling = learnSpelling
    }

    static var noop: EditorMenuActions { EditorMenuActions() }
}

/// Builds the editor's context menu.
///
/// This REPLACES `NSTextView`'s own menu. Ask Siri, Font, Substitutions,
/// Speech and AutoFill are deliberately dropped: none of them are things a
/// markdown editor's own menu should be teaching, and each one kept is a
/// submenu to rebuild and maintain by hand. They remain reachable through the
/// app's main menu bar, where the system provides them for free. Spelling is
/// the exception — it is the one system feature people use mid-writing, so its
/// suggestions are rebuilt here.
enum EditorMenuItems {

    static func build(selection: NSRange, suggestions: [String],
                      actions: EditorMenuActions) -> [AinkradMenuItem] {
        var items: [AinkradMenuItem] = []

        // Suggestions lead, because when they are present they are why the
        // menu was opened.
        for suggestion in suggestions.prefix(5) {
            items.append(AinkradMenuItem(title: suggestion) { actions.replace(suggestion) })
        }
        if !suggestions.isEmpty {
            items.append(AinkradMenuItem(title: "Ignore Spelling",
                                         action: actions.ignoreSpelling))
            items.append(AinkradMenuItem(title: "Learn Spelling",
                                         action: actions.learnSpelling))
        }

        // Cut and Copy are ABSENT without a selection rather than present and
        // dead — a menu that offers what it cannot do teaches the wrong thing.
        if selection.length > 0 {
            items.append(AinkradMenuItem(title: "Cut", systemName: "scissors",
                                         shortcut: "\u{2318}X", action: actions.cut))
            items.append(AinkradMenuItem(title: "Copy", systemName: "doc.on.doc",
                                         shortcut: "\u{2318}C", action: actions.copy))
        }
        items.append(AinkradMenuItem(title: "Paste", systemName: "doc.on.clipboard",
                                     shortcut: "\u{2318}V", action: actions.paste))
        items.append(AinkradMenuItem(title: "Select All",
                                     shortcut: "\u{2318}A", action: actions.selectAll))

        items.append(AinkradMenuItem(title: "Link", systemName: "link",
                                     action: actions.link))
        items.append(AinkradMenuItem(title: "Code", systemName: "chevron.left.forwardslash.chevron.right",
                                     action: actions.code))
        items.append(AinkradMenuItem(title: "Heading", systemName: "textformat.size",
                                     action: actions.heading))
        return items
    }
}
