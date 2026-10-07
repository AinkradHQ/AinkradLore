import AinkradAppKit
import AppKit

/// The skin, flattened into the CSS custom properties the CM6 page reads.
///
/// Two families, and nothing else reaches the stylesheet:
///
/// - `--ak-*` is the skin's own `Codable` encoding, key path by key path
///   (`text.muted` → `--ak-text-muted`, `size.s1_5` → `--ak-size-s1-5`). There
///   is no mapping table: a token added to the skin reaches CSS by existing.
///   The one exception is the `components` group, which the page never reads.
///   Colours are emitted RESOLVED — `palette.*` against the host's tokens, as
///   `MarkdownTheme.color` resolves them for the native editor — and the
///   length ladders (`spacing`, `radius`, `size`, `type.sizes`) carry `px`.
/// - `--lore-*` is what only the editor has: the settings-resolved body size,
///   line height, measure and inset (R2: skin defaults, user values win), the
///   heading ramp shared with the native editor, the callout hue table, the
///   font stacks, and the token gaps listed below.
///
/// `index.html` declares every one of these in `:root` with the default
/// skin's values, so a first paint before the push still looks right;
/// `CM6ThemeBridgeTests` holds the two in step.
enum CM6ThemeBridge {

    /// Top-level skin groups whose numbers are lengths.
    private static let lengthGroups: Set<String> = ["spacing", "radius", "size"]

    static func cssVariables(skin: AinkradSkin, theme: MarkdownTheme) -> [String: String] {
        var out: [String: String] = [:]
        do {
            let data = try JSONEncoder().encode(skin)
            let object = try JSONSerialization.jsonObject(with: data)
            let palette = (object as? [String: Any])?["palette"] as? [String: Any] ?? [:]
            let paletteKeys = Set(palette.keys)
            flatten(object, path: [], paletteKeys: paletteKeys, theme: theme, into: &out)
        } catch {
            Log.editor.error("CM6 theme bridge: \(String(describing: error), privacy: .public)")
        }
        out.merge(loreVariables(skin: skin, theme: theme)) { _, lore in lore }
        return out
    }

    /// One batched `setProperty` pass. The values travel as JSON, never
    /// interpolated: a font family holding a `'` must not end the string.
    static func pushScript(_ variables: [String: String]) -> String {
        let json =
            // `try?`: a `[String: String]` always encodes; `{}` pushes nothing.
            (try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "(() => { const s = document.documentElement.style; "
            + "for (const [k, v] of Object.entries(\(json))) s.setProperty(k, v); })()"
    }

    // MARK: - --lore-*

    private static func loreVariables(skin: AinkradSkin, theme: MarkdownTheme) -> [String: String] {
        var lore: [String: String] = [
            "--lore-body-size": "\(number(theme.bodyFont.pointSize))px",
            "--lore-line-height": number(theme.lineHeightMultiple),
            // `nil` is "fill the width", which in CSS is `none`.
            "--lore-measure": theme.maxMeasure.map { "\(number($0))px" } ?? "none",
            "--lore-content-inset": "\(number(theme.contentInset))px",
            "--lore-mono-scale": number(MarkdownTheme.monoRatio),
            "--lore-font-text": "-apple-system, \"SF Pro Text\", system-ui, sans-serif",
            "--lore-font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
            // Token gaps: no skin token holds these yet (6.4 handoff).
            // `meta` is the CM6 syntax-marker colour, foreground at o40.
            "--lore-meta": css(theme.color(.palette("foreground", skin.opacity.o40))),
            "--lore-opacity-o26": "0.26",
            "--lore-opacity-o38": "0.38",
            "--lore-radius-pill": "999px",
            "--lore-callout-saturation": "65%",
            "--lore-callout-lightness": "58%",
        ]
        for level in 1...6 {
            lore["--lore-heading-\(level)-scale"] = number(MarkdownTheme.headingRatios[level - 1])
            lore["--lore-heading-\(level)-weight"] = theme.headingWeight(level) == .bold ? "700" : "600"
        }
        for kind in MarkdownCallout.Kind.allCases where !kind.isNeutral {
            lore["--lore-callout-\(kind.rawValue)-hue"] = number(kind.hue)
        }
        return lore
    }

    // MARK: - --ak-*

    private static func flatten(
        _ value: Any, path: [String], paletteKeys: Set<String>, theme: MarkdownTheme,
        into out: inout [String: String]
    ) {
        switch value {
        case let dictionary as [String: Any]:
            // `components` is the kit's per-component styling; no CM6 rule reads it.
            for (key, child) in dictionary where !(path.isEmpty && key == "components") {
                flatten(child, path: path + [key], paletteKeys: paletteKeys, theme: theme, into: &out)
            }
        case let array as [Any]:
            for (index, child) in array.enumerated() {
                flatten(child, path: path + ["\(index)"], paletteKeys: paletteKeys, theme: theme, into: &out)
            }
        case let string as String:
            out[name(path)] = cssValue(string, path: path, paletteKeys: paletteKeys, theme: theme)
        case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID():
            out[name(path)] = flag.boolValue ? "true" : "false"
        case let numeric as NSNumber:
            let isLength =
                lengthGroups.contains(path.first ?? "")
                || path.starts(with: ["type", "sizes"])
            out[name(path)] = number(numeric.doubleValue) + (isLength ? "px" : "")
        default:
            break
        }
    }

    /// A string leaf: a colour token resolved to `rgb()`/`rgba()`, anything
    /// else passed through. A palette entry resolves BY ITS KEY, so the
    /// host's colour wins exactly where it does in `MarkdownTheme.color`.
    private static func cssValue(
        _ string: String, path: [String], paletteKeys: Set<String>, theme: MarkdownTheme
    ) -> String {
        if path.count == 2, path[0] == "palette" {
            return css(theme.color(.palette(path[1], 1)))
        }
        let base = String(string.split(separator: "@").first ?? "")
        let isColour =
            string == "clear" || string.hasPrefix("#") || string.hasPrefix("tint")
            || paletteKeys.contains(base)
        guard isColour,
            // `try?`: probes — a value that is not a colour token passes through as CSS.
            let data = try? JSONEncoder().encode(string),
            let token = try? JSONDecoder().decode(AinkradColorToken.self, from: data)
        else { return string }
        return cssMix(theme.color(token))
    }

    /// `colors.text.secondary` → `--ak-colors-text-secondary`.
    private static func name(_ path: [String]) -> String {
        "--ak-" + path.map(kebab).joined(separator: "-")
    }

    private static func kebab(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else {
                result.append(character == "_" ? "-" : character)
            }
        }
        return result
    }

    static func number(_ value: CGFloat) -> String { number(Double(value)) }

    /// `8`, not `8.0`; `0.45`, not `0.45000000000000001`.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
    }

    static func css(_ color: NSColor) -> String {
        let ns = color.usingColorSpace(.sRGB) ?? .textColor
        return ns.alphaComponent >= 1
            ? "rgb(\(rgb(ns)))" : "rgba(\(rgb(ns)), \(ns.alphaComponent))"
    }

    /// A translucent skin colour as the `color-mix` the stylesheet itself
    /// wrote before the bridge (`color-mix(in srgb, <fg> 45%, transparent)`).
    /// Measured, not assumed: WebKit rounds `rgba(…, 0.45)` one or two levels
    /// away from the mix, which moved the S16 shots by a few pixels.
    static func cssMix(_ color: NSColor) -> String {
        let ns = color.usingColorSpace(.sRGB) ?? .textColor
        guard ns.alphaComponent < 1 else { return css(ns) }
        let percent = (ns.alphaComponent * 100 * 1e6).rounded() / 1e6
        return "color-mix(in srgb, rgb(\(rgb(ns))) \(number(percent))%, transparent)"
    }

    private static func rgb(_ ns: NSColor) -> String {
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return "\(r), \(g), \(b)"
    }
}
