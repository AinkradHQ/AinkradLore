import Foundation

/// A math expression as a tree, ready to be laid out.
///
/// The parser is deliberately SMALL and deliberately refuses a lot. Everything
/// it cannot represent exactly returns `nil`, which feeds the all-or-nothing
/// rule in `MarkdownMath`: an expression renders only if every part of it can,
/// because half-rendered mathematics costs the reader the ability to tell
/// notation from content.
indirect enum MathNode: Equatable {
    /// A run of glyphs drawn as-is. `isVariable` selects the italic face TeX
    /// uses for identifiers, against the upright one for digits and operators.
    case symbol(String, isVariable: Bool)
    case row([MathNode])
    case fraction(numerator: MathNode, denominator: MathNode)
    case squareRoot(MathNode)
    /// A base with either or both scripts. Both `nil` never occurs — the
    /// parser emits the bare base instead.
    case script(base: MathNode, superscript: MathNode?, subscript_: MathNode?)
}

/// Turns `$…$` content into a `MathNode`, or refuses.
enum MathParser {

    /// The commands this can draw. A command NOT here makes the whole
    /// expression fall back to source, which is the safe direction: showing
    /// what the author typed is never wrong, showing something else is.
    ///
    /// Greek and the operator set are plain Unicode substitutions — the glyph
    /// is DRAWN, never written into the document, so the text keeps every
    /// offset the index and the link graph measure against it.
    static let symbols: [String: String] = [
        // Lower-case Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω",
        // Upper-case Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω",
        // Operators and relations
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "propto": "∝", "sim": "∼",
        "infty": "∞", "partial": "∂", "nabla": "∇",
        "sum": "∑", "prod": "∏", "int": "∫",
        "in": "∈", "notin": "∉", "subset": "⊂", "supset": "⊃",
        "cup": "∪", "cap": "∩", "emptyset": "∅",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "leftrightarrow": "↔", "forall": "∀", "exists": "∃", "neg": "¬",
        "ldots": "…", "cdots": "⋯", "angle": "∠", "perp": "⊥",
        "circ": "∘", "star": "⋆", "bullet": "∙", "oplus": "⊕", "otimes": "⊗",
    ]

    /// Multi-letter function names, drawn upright as TeX does: `sin x`, not
    /// `s·i·n·x` in italic.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "log", "ln", "exp", "min", "max", "lim",
        "det", "dim", "gcd", "sup", "inf", "arg", "deg",
    ]

    static func parse(_ source: String) -> MathNode? {
        var scanner = Scanner(source: Array(source))
        guard let node = scanner.parseRow(stopAtCloseBrace: false),
              scanner.isAtEnd else { return nil }
        return node
    }

    private struct Scanner {
        let source: [Character]
        var index = 0

        init(source: [Character]) { self.source = source }

        var isAtEnd: Bool { index >= source.count }
        private func peek(_ offset: Int = 0) -> Character? {
            let at = index + offset
            return at < source.count ? source[at] : nil
        }

        /// A sequence of atoms, each of which may carry scripts.
        mutating func parseRow(stopAtCloseBrace: Bool) -> MathNode? {
            var items: [MathNode] = []
            while let character = peek() {
                if character == "}" {
                    guard stopAtCloseBrace else { return nil }
                    break
                }
                guard var atom = parseAtom() else { return nil }
                // Scripts bind to the atom just read, and may appear in either
                // order — `x^2_i` and `x_i^2` are the same thing.
                var superscript: MathNode?
                var subscript_: MathNode?
                while let next = peek(), next == "^" || next == "_" {
                    index += 1
                    guard let script = parseAtom() else { return nil }
                    if next == "^" {
                        guard superscript == nil else { return nil }
                        superscript = script
                    } else {
                        guard subscript_ == nil else { return nil }
                        subscript_ = script
                    }
                }
                if superscript != nil || subscript_ != nil {
                    atom = .script(base: atom, superscript: superscript,
                                   subscript_: subscript_)
                }
                items.append(atom)
            }
            guard !items.isEmpty else { return nil }
            return items.count == 1 ? items[0] : .row(items)
        }

        /// One indivisible unit: a group, a command, or a single character.
        mutating func parseAtom() -> MathNode? {
            guard let character = peek() else { return nil }
            switch character {
            case "{":
                index += 1
                guard let inner = parseRow(stopAtCloseBrace: true),
                      peek() == "}" else { return nil }
                index += 1
                return inner
            case "\\":
                return parseCommand()
            case "}", "^", "_":
                return nil
            case " ", "\t":
                // Spacing in the SOURCE is not spacing in the output: TeX
                // decides gaps from what sits either side. Skipping here is
                // what makes `x + y` and `x+y` render identically, which is
                // what a reader expects and what they wrote either way.
                index += 1
                return parseAtom()
            default:
                index += 1
                return .symbol(String(character), isVariable: character.isLetter)
            }
        }

        mutating func parseCommand() -> MathNode? {
            index += 1                                    // the backslash
            var name = ""
            while let character = peek(), character.isLetter {
                name.append(character)
                index += 1
            }
            guard !name.isEmpty else { return nil }

            switch name {
            case "frac":
                guard let numerator = parseBracedGroup(),
                      let denominator = parseBracedGroup() else { return nil }
                return .fraction(numerator: numerator, denominator: denominator)
            case "sqrt":
                guard let inner = parseBracedGroup() else { return nil }
                return .squareRoot(inner)
            default:
                if let glyph = MathParser.symbols[name] {
                    return .symbol(glyph, isVariable: false)
                }
                if MathParser.functions.contains(name) {
                    return .symbol(name, isVariable: false)
                }
                return nil
            }
        }

        /// A `{…}` argument. Required — `\frac a b` is legal TeX and is
        /// refused here, because supporting it means deciding how much of what
        /// follows belongs to the argument, and getting that wrong silently
        /// renders something the author did not write.
        mutating func parseBracedGroup() -> MathNode? {
            while let character = peek(), character == " " { index += 1 }
            guard peek() == "{" else { return nil }
            index += 1
            guard let inner = parseRow(stopAtCloseBrace: true), peek() == "}"
            else { return nil }
            index += 1
            return inner
        }
    }
}
