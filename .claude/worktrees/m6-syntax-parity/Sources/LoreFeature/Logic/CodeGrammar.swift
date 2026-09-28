import Foundation

/// What one language's syntax looks like, as data.
///
/// Deliberately a TABLE rather than a parser per language. Highlighting a
/// fenced block does not need to understand the code — it needs to find the
/// four things a reader's eye uses to navigate it: what is a comment, what is a
/// string, what is a number, and which words are the language's own. Everything
/// past that (semantic types, scope resolution) is a compiler's job and would
/// bring a compiler's cost and a compiler's bugs.
///
/// No dependency. The Swift-only highlighters cover one language of the
/// thirteen here, and the general-purpose ones carry a JavaScript runtime —
/// neither is a trade worth making in a plugin that must pin the host's SDK
/// revision exactly and survive `dlopen`.
struct CodeGrammar: Sendable {
    struct BlockComment: Sendable {
        let open: String
        let close: String
    }

    /// Comment markers that run to the end of the line, longest FIRST — a
    /// scanner testing `-` before `--` would split every SQL comment in two.
    let lineComments: [String]
    let blockComment: BlockComment?
    /// String delimiters, longest FIRST for the same reason: `"""` must be
    /// tried before `"`, or a Swift multi-line string opens and closes on its
    /// own first two quotes.
    let stringDelimiters: [String]
    /// Whether a backslash escapes the next character inside a string. False
    /// for the languages where it does not (none here yet, but YAML and TOML
    /// have their own rules and this is the flag they would use).
    let hasBackslashEscapes: Bool
    let keywords: Set<String>
    /// Words that name a type. Kept apart from keywords because they read
    /// differently — a type is a noun in the code, and colouring it like `if`
    /// makes a signature harder to scan, not easier.
    let types: Set<String>
    /// Whether `-` is part of a word rather than an operator.
    ///
    /// True for CSS and HTML, where `font-face` and `data-id` are single
    /// names. FALSE everywhere else, and that default matters: treating `-` as
    /// a word character in Swift makes `count-1` scan as one identifier, which
    /// silently stops any keyword to the right of a subtraction from being
    /// recognised.
    let identifiersMayContainHyphen: Bool

    // The delimiters again as UTF-16 units, precomputed.
    //
    // The scanner tests every marker at every character position, so building
    // `Array(needle.utf16)` inside the comparison allocated once per marker per
    // CHARACTER. Not a micro-optimisation: it is the difference between a scan
    // costing a fence and one costing a fence times the size of this table.
    let lineCommentUnits: [[UInt16]]
    let stringDelimiterUnits: [[UInt16]]
    let blockOpenUnits: [UInt16]
    let blockCloseUnits: [UInt16]

    init(lineComments: [String] = [], blockComment: BlockComment? = nil,
         stringDelimiters: [String] = ["\"", "'"], hasBackslashEscapes: Bool = true,
         keywords: Set<String> = [], types: Set<String> = [],
         identifiersMayContainHyphen: Bool = false) {
        // Sorted here rather than trusted from the call site: the "longest
        // first" rule is load-bearing for correctness and a table this long is
        // exactly where one entry gets written in the wrong order.
        self.lineComments = lineComments.sorted { $0.count > $1.count }
        self.blockComment = blockComment
        self.stringDelimiters = stringDelimiters.sorted { $0.count > $1.count }
        self.hasBackslashEscapes = hasBackslashEscapes
        self.keywords = keywords
        self.types = types
        self.identifiersMayContainHyphen = identifiersMayContainHyphen
        self.lineCommentUnits = self.lineComments.map { Array($0.utf16) }
        self.stringDelimiterUnits = self.stringDelimiters.map { Array($0.utf16) }
        self.blockOpenUnits = blockComment.map { Array($0.open.utf16) } ?? []
        self.blockCloseUnits = blockComment.map { Array($0.close.utf16) } ?? []
    }

    /// The grammar for a fence's language label, or `nil` for a language with
    /// no entry.
    ///
    /// `nil` means NO HIGHLIGHTING, deliberately. Applying C-like rules to an
    /// unknown language is worse than leaving it plain: it would paint `#` as a
    /// comment in a language where it is an operator, and a reader cannot tell
    /// a wrong highlight from a right one without already knowing the answer.
    static func named(_ raw: String) -> CodeGrammar? {
        switch raw.lowercased() {
        case "swift": return .swift
        case "javascript", "js", "jsx", "mjs": return .javascript
        case "typescript", "ts", "tsx": return .typescript
        case "python", "py": return .python
        case "rust", "rs": return .rust
        case "go", "golang": return .go
        case "ruby", "rb": return .ruby
        case "java": return .java
        case "kotlin", "kt": return .kotlin
        case "c", "h": return .c
        case "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m": return .cpp
        case "shell", "sh", "bash", "zsh", "fish": return .shell
        case "sql": return .sql
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "css", "scss", "less": return .css
        case "html", "xml", "svg": return .html
        default: return nil
        }
    }

    // MARK: - The table

    private static let cStyle = BlockComment(open: "/*", close: "*/")

    static let swift = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        stringDelimiters: ["\"\"\"", "\""],
        keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                   "func", "import", "init", "inout", "internal", "let", "open", "operator",
                   "private", "protocol", "public", "static", "struct", "subscript",
                   "typealias", "var", "break", "case", "continue", "default", "defer",
                   "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
                   "return", "switch", "where", "while", "as", "catch", "false", "is",
                   "nil", "rethrows", "super", "self", "throw", "throws", "true", "try",
                   "async", "await", "actor", "some", "any", "final", "lazy", "weak",
                   "unowned", "mutating", "nonmutating", "override", "required",
                   "convenience", "indirect", "@escaping", "@MainActor"],
        types: ["Int", "Double", "Float", "String", "Bool", "Character", "Array", "Set",
                "Dictionary", "Optional", "Result", "Error", "Void", "Any", "AnyObject",
                "Data", "Date", "URL", "UUID", "Range", "Task", "Sendable", "Equatable",
                "Hashable", "Codable", "Comparable", "Identifiable"])

    static let javascript = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        stringDelimiters: ["\"", "'", "`"],
        keywords: ["var", "let", "const", "function", "return", "if", "else", "for",
                   "while", "do", "break", "continue", "switch", "case", "default",
                   "throw", "try", "catch", "finally", "new", "delete", "typeof",
                   "instanceof", "in", "of", "this", "class", "extends", "super",
                   "import", "export", "from", "as", "async", "await", "yield",
                   "true", "false", "null", "undefined", "void", "static", "get", "set"],
        types: ["Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set",
                "Symbol", "Date", "RegExp", "Error", "JSON", "Math", "console"])

    static let typescript = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        stringDelimiters: ["\"", "'", "`"],
        keywords: javascript.keywords.union(["interface", "type", "enum", "implements",
                                             "declare", "namespace", "abstract", "public",
                                             "private", "protected", "readonly", "keyof",
                                             "satisfies", "infer", "is"]),
        types: javascript.types.union(["string", "number", "boolean", "any", "unknown",
                                       "never", "void", "Record", "Partial", "Readonly"]))

    static let python = CodeGrammar(
        lineComments: ["#"], blockComment: nil,
        stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while",
                   "break", "continue", "pass", "import", "from", "as", "try", "except",
                   "finally", "raise", "with", "lambda", "global", "nonlocal", "yield",
                   "assert", "del", "in", "is", "not", "and", "or", "None", "True",
                   "False", "async", "await", "match", "case"],
        types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes",
                "object", "type", "Any", "Optional", "List", "Dict", "Callable"])

    static let rust = CodeGrammar(
        lineComments: ["///", "//!", "//"], blockComment: cStyle,
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait",
                   "impl", "for", "while", "loop", "if", "else", "match", "return",
                   "break", "continue", "use", "mod", "pub", "crate", "super", "self",
                   "Self", "where", "as", "dyn", "ref", "move", "async", "await",
                   "unsafe", "extern", "type", "true", "false"],
        types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
                "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec",
                "Option", "Result", "Box", "Rc", "Arc", "HashMap", "HashSet"])

    static let go = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        stringDelimiters: ["\"", "`", "'"],
        keywords: ["func", "var", "const", "type", "struct", "interface", "map", "chan",
                   "package", "import", "return", "if", "else", "for", "range", "switch",
                   "case", "default", "break", "continue", "fallthrough", "go", "defer",
                   "select", "goto", "nil", "true", "false"],
        types: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                "uint32", "uint64", "float32", "float64", "string", "bool", "byte",
                "rune", "error", "any"])

    static let ruby = CodeGrammar(
        lineComments: ["#"], blockComment: nil,
        keywords: ["def", "class", "module", "end", "if", "elsif", "else", "unless",
                   "while", "until", "for", "in", "do", "begin", "rescue", "ensure",
                   "raise", "return", "yield", "require", "require_relative", "attr_accessor",
                   "attr_reader", "attr_writer", "self", "nil", "true", "false", "and",
                   "or", "not", "then", "case", "when", "next", "break", "lambda", "proc"],
        types: ["String", "Integer", "Float", "Array", "Hash", "Symbol", "Range",
                "Struct", "Proc", "Exception"])

    static let java = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        keywords: ["public", "private", "protected", "static", "final", "abstract",
                   "class", "interface", "enum", "extends", "implements", "new", "return",
                   "if", "else", "for", "while", "do", "switch", "case", "default",
                   "break", "continue", "try", "catch", "finally", "throw", "throws",
                   "import", "package", "this", "super", "synchronized", "volatile",
                   "transient", "native", "instanceof", "null", "true", "false", "var",
                   "record", "sealed", "yield"],
        types: ["int", "long", "short", "byte", "char", "float", "double", "boolean",
                "void", "String", "Object", "List", "Map", "Set", "Integer", "Long",
                "Double", "Boolean", "Optional", "Stream"])

    static let kotlin = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        stringDelimiters: ["\"\"\"", "\"", "'"],
        keywords: ["fun", "val", "var", "class", "object", "interface", "data", "sealed",
                   "enum", "companion", "init", "constructor", "override", "open",
                   "abstract", "private", "protected", "public", "internal", "return",
                   "if", "else", "when", "for", "while", "do", "break", "continue",
                   "try", "catch", "finally", "throw", "import", "package", "is", "as",
                   "in", "by", "suspend", "null", "true", "false", "this", "super"],
        types: ["Int", "Long", "Short", "Byte", "Char", "Float", "Double", "Boolean",
                "String", "Any", "Unit", "Nothing", "List", "Map", "Set", "Array"])

    static let c = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else",
                   "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
                   "return", "sizeof", "static", "struct", "switch", "typedef", "union",
                   "volatile", "while", "#include", "#define", "#ifdef", "#ifndef",
                   "#endif", "#pragma", "NULL"],
        types: ["int", "char", "short", "long", "float", "double", "void", "signed",
                "unsigned", "size_t", "bool", "FILE", "uint8_t", "uint32_t", "int32_t"])

    static let cpp = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        keywords: c.keywords.union(["class", "namespace", "template", "typename", "public",
                                    "private", "protected", "virtual", "override", "final",
                                    "new", "delete", "this", "using", "friend", "operator",
                                    "explicit", "constexpr", "noexcept", "nullptr", "true",
                                    "false", "try", "catch", "throw", "@interface",
                                    "@implementation", "@end", "@property"]),
        types: c.types.union(["string", "vector", "map", "set", "pair", "shared_ptr",
                              "unique_ptr", "auto", "wchar_t", "NSString", "NSArray",
                              "NSDictionary", "id", "BOOL"]))

    static let shell = CodeGrammar(
        lineComments: ["#"], blockComment: nil,
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                   "done", "case", "esac", "function", "return", "exit", "export",
                   "local", "readonly", "declare", "source", "alias", "unset", "shift",
                   "trap", "echo", "cd", "set", "in"],
        types: ["true", "false"])

    static let sql = CodeGrammar(
        lineComments: ["--"], blockComment: cStyle,
        stringDelimiters: ["'", "\""],
        keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                   "DELETE", "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "ADD",
                   "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "ON", "AS", "AND",
                   "OR", "NOT", "NULL", "IS", "IN", "BETWEEN", "LIKE", "ORDER", "BY",
                   "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
                   "COUNT", "SUM", "AVG", "MIN", "MAX", "PRIMARY", "KEY", "FOREIGN",
                   "REFERENCES", "UNIQUE", "DEFAULT", "CASCADE", "BEGIN", "COMMIT",
                   "ROLLBACK", "TRANSACTION", "WITH", "CASE", "WHEN", "THEN", "END",
                   "select", "from", "where", "insert", "into", "values", "update",
                   "set", "delete", "create", "table", "join", "on", "as", "and", "or",
                   "not", "null", "order", "by", "group", "limit"],
        types: ["INTEGER", "TEXT", "REAL", "BLOB", "VARCHAR", "CHAR", "DATE", "TIMESTAMP",
                "BOOLEAN", "DECIMAL", "SERIAL", "UUID"])

    /// JSON has no keywords beyond its three literals, and no comments. The
    /// value is almost entirely in colouring strings and numbers apart.
    static let json = CodeGrammar(
        lineComments: [], blockComment: nil, stringDelimiters: ["\""],
        keywords: ["true", "false", "null"], types: [])

    static let yaml = CodeGrammar(
        lineComments: ["#"], blockComment: nil,
        keywords: ["true", "false", "null", "yes", "no", "on", "off"], types: [])

    static let css = CodeGrammar(
        lineComments: ["//"], blockComment: cStyle,
        keywords: ["important", "media", "import", "keyframes", "font-face", "supports",
                   "charset", "namespace", "from", "to", "and", "not", "only"],
        types: ["px", "em", "rem", "vh", "vw", "fr", "deg", "ms", "auto", "none",
                "inherit", "initial", "unset", "flex", "grid", "block", "inline"],
        identifiersMayContainHyphen: true)

    /// HTML has no line comments and a comment syntax nothing else shares.
    static let html = CodeGrammar(
        lineComments: [], blockComment: BlockComment(open: "<!--", close: "-->"),
        stringDelimiters: ["\"", "'"],
        keywords: ["html", "head", "body", "div", "span", "a", "p", "ul", "ol", "li",
                   "table", "tr", "td", "th", "img", "script", "style", "link", "meta",
                   "input", "button", "form", "label", "select", "option", "header",
                   "footer", "nav", "section", "article", "main", "aside", "h1", "h2",
                   "h3", "h4", "h5", "h6", "svg", "path", "g", "rect", "circle"],
        types: ["class", "id", "href", "src", "type", "name", "value", "alt", "title",
                "width", "height", "style", "rel", "target", "placeholder"],
        identifiersMayContainHyphen: true)
}
