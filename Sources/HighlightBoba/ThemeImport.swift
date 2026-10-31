import Foundation

/// Why a theme file couldn't be read.
public enum ThemeImportError: Error, Equatable, Sendable {
    /// Larger than `HighlightTheme.maximumImportSize`.
    case tooLarge(bytes: Int)
    /// Not JSON (with comments) or a property list, or not the shape of a theme.
    case unreadable(String)
}

/// The theme formats `HighlightTheme(importing:)` reads.
public enum ThemeFormat: String, CaseIterable, Sendable {
    /// A VS Code colour theme: JSON, comments and trailing commas allowed.
    case vsCode
    /// A TextMate `.tmTheme` property list (Sublime Text uses it too).
    case textMate
    /// An Xcode `.xccolortheme` property list.
    case xcode

    /// The format a file name's extension names, if any.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "json", "jsonc": self = .vsCode
        case "tmtheme": self = .textMate
        case "xccolortheme", "dvtcolortheme": self = .xcode
        default: return nil
        }
    }
}

extension HighlightTheme {
    /// Theme files are a few KB; anything this big isn't one.
    public static let maximumImportSize = 1_000_000

    /// A theme read from another editor's theme file, its colours mapped onto
    /// the scopes in ``Scopes/vocabulary``.
    ///
    /// Each format names its token kinds its own way. Every vocabulary scope
    /// tries a short list of the names themes commonly use for it, most
    /// specific first (`keyword` also tries `storage.type`, where many themes
    /// colour `func` and `let`), and takes the style of the first name the
    /// theme styles. Colours with alpha are laid over the background. The
    /// result isn't contrast-solved; call ``readable(ratio:)`` for that.
    ///
    /// - Parameters:
    ///   - format: what `data` is; `nil` tries each in turn.
    ///   - name: the theme's name when the file has none.
    public init(importing data: Data, format: ThemeFormat? = nil, name: String = "Imported Theme") throws {
        guard data.count <= Self.maximumImportSize else { throw ThemeImportError.tooLarge(bytes: data.count) }
        var failures: [String] = []
        for candidate in format.map({ [$0] }) ?? ThemeFormat.allCases {
            do {
                let parsed = try ParsedTheme(data: data, format: candidate)
                self = parsed.theme(fallbackName: name)
                return
            } catch let ThemeImportError.unreadable(reason) {
                failures.append("\(candidate.rawValue): \(reason)")
            }
        }
        throw ThemeImportError.unreadable(failures.joined(separator: "; "))
    }
}

// MARK: - A parsed file

/// What every format comes down to: an appearance, a background and text
/// colour, and styles by the format's own scope names.
struct ParsedTheme {
    var name: String?
    var appearance: HighlightTheme.Appearance
    var background: HighlightColor
    var text: HighlightColor
    /// In file order: later rules win ties, as in TextMate.
    var rules: [(selector: String, style: HighlightStyle)]

    init(data: Data, format: ThemeFormat) throws {
        switch format {
        case .vsCode: try self.init(vsCode: data)
        case .textMate: try self.init(textMate: data)
        case .xcode: try self.init(xcode: data)
        }
    }

    func theme(fallbackName: String) -> HighlightTheme {
        var styles: [String: HighlightStyle] = [:]
        for scope in Scopes.vocabulary {
            for candidate in ScopeAliases.candidates(for: scope) {
                if let style = style(for: candidate) {
                    styles[scope] = style
                    break
                }
            }
        }
        let name = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let id = "imported." + name.lowercased().filter { $0.isLetter || $0.isNumber }
        return HighlightTheme(id: id, name: name, appearance: appearance, background: background, text: text, styles: styles)
    }

    /// The style TextMate would give `scope`: the longest selector that is the
    /// scope or a dotted prefix of it, the later rule among equals.
    func style(for scope: String) -> HighlightStyle? {
        var best: (length: Int, style: HighlightStyle)?
        for rule in rules where HighlightTheme.selector(rule.selector, matches: scope) {
            let length = rule.selector.utf8.count
            if length >= best?.length ?? -1 { best = (length, rule.style) }
        }
        return best?.style
    }

    /// One rule per plain selector in a TextMate scope list: `"a, b"` is two.
    /// A descendant selector (`source.python keyword`) is taken by its last
    /// part, and an exclusion (`string - string.regexp`) is dropped rather
    /// than half-applied.
    static func selectors(in scopeList: String) -> [String] {
        scopeList.split(separator: ",").compactMap { part in
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, !part.contains(" -"), !part.hasPrefix("-") else { return nil }
            return part.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
    }

    /// `bold`, `italic` and `underline` in any order; underline isn't drawn.
    static func style(color: HighlightColor?, fontStyle: String?) -> HighlightStyle {
        let words = Set((fontStyle ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        return HighlightStyle(color: color, bold: words.contains("bold"), italic: words.contains("italic"))
    }
}

// MARK: - Colours

extension HighlightColor {
    /// `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, the alpha laid over
    /// `background`; `nil` for anything else.
    static func parse(_ value: String, over background: HighlightColor?) -> HighlightColor? {
        var digits = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard digits.hasPrefix("#") else { return nil }
        digits = digits.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII) else { return nil }
        if digits.count == 3 || digits.count == 4 { digits = Substring(digits.map { "\($0)\($0)" }.joined()) }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let color = HighlightColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
        guard hasAlpha, let background else { return color }
        return background.mixed(toward: color, by: Double(value & 0xFF) / 255)
    }
}

// MARK: - VS Code

extension ParsedTheme {
    init(vsCode data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else { throw ThemeImportError.unreadable("not UTF-8") }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(JSONC.strip(source).utf8))
        } catch {
            throw ThemeImportError.unreadable("not JSON")
        }
        guard let root = json as? [String: Any] else { throw ThemeImportError.unreadable("not a JSON object") }
        let colors = root["colors"] as? [String: Any] ?? [:]
        let tokenColors = root["tokenColors"] as? [[String: Any]]
        guard tokenColors != nil || !colors.isEmpty else { throw ThemeImportError.unreadable("no colors or tokenColors") }

        let type = (root["type"] as? String)?.lowercased() ?? "dark"
        let dark = !(type == "light" || type == "hclight")
        // VS Code's own defaults, for a theme that leaves them out.
        let background = (colors["editor.background"] as? String).flatMap { HighlightColor.parse($0, over: dark ? .black : .white) }
            ?? HighlightColor(hex: dark ? "#1E1E1E" : "#FFFFFF")!
        let text = (colors["editor.foreground"] as? String).flatMap { HighlightColor.parse($0, over: background) }
            ?? HighlightColor(hex: dark ? "#D4D4D4" : "#000000")!

        var parsed: [(selector: String, style: HighlightStyle)] = []
        for entry in tokenColors ?? [] {
            guard let settings = entry["settings"] as? [String: Any] else { continue }
            let color = (settings["foreground"] as? String).flatMap { HighlightColor.parse($0, over: background) }
            let style = Self.style(color: color, fontStyle: settings["fontStyle"] as? String)
            let scopes: [String]
            switch entry["scope"] {
            case let list as String: scopes = Self.selectors(in: list)
            case let array as [String]: scopes = array.flatMap(Self.selectors(in:))
            default: continue // a rule with no scope sets the defaults, which `colors` already did
            }
            parsed += scopes.map { ($0, style) }
        }
        self.name = root["name"] as? String
        self.appearance = dark ? .dark : .light
        self.background = background
        self.text = text
        self.rules = parsed
    }
}

/// JSON with comments, as VS Code writes its themes.
enum JSONC {
    /// `text` with `//` and `/* */` comments removed and trailing commas
    /// dropped, leaving strings alone, so plain JSON parsers can read it.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if inString {
                out.append(scalar)
                if scalar == "\\", let next {
                    out.append(next)
                    index += 2
                    continue
                }
                if scalar == "\"" { inString = false }
                index += 1
            } else if scalar == "\"" {
                inString = true
                out.append(scalar)
                index += 1
            } else if scalar == "/", next == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else if scalar == "/", next == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") { index += 1 }
                index += 2
            } else if scalar == "," {
                // A comma whose next non-space is a closing bracket is trailing.
                var look = index + 1
                while look < scalars.count, scalars[look].properties.isWhitespace { look += 1 }
                if look < scalars.count, scalars[look] == "}" || scalars[look] == "]" {
                    index += 1
                } else {
                    out.append(scalar)
                    index += 1
                }
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }
}

// MARK: - TextMate

extension ParsedTheme {
    init(textMate data: Data) throws {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let settings = root["settings"] as? [[String: Any]] else {
            throw ThemeImportError.unreadable("not a .tmTheme property list")
        }
        // The first entry without a scope holds the editor's own colours.
        let global = settings.first { $0["scope"] == nil }?["settings"] as? [String: Any] ?? [:]
        let parsedBackground = (global["background"] as? String).flatMap { HighlightColor.parse($0, over: .white) }
        let background = parsedBackground ?? .white
        // Light or dark by the background, as TextMate themes rarely say.
        let light = background.relativeLuminance > 0.4
        let text = (global["foreground"] as? String).flatMap { HighlightColor.parse($0, over: background) }
            ?? (light ? .black : .white)

        var parsed: [(selector: String, style: HighlightStyle)] = []
        for entry in settings {
            guard let list = entry["scope"] as? String, let style = entry["settings"] as? [String: Any] else { continue }
            let color = (style["foreground"] as? String).flatMap { HighlightColor.parse($0, over: background) }
            let ruleStyle = Self.style(color: color, fontStyle: style["fontStyle"] as? String)
            parsed += Self.selectors(in: list).map { ($0, ruleStyle) }
        }
        guard parsedBackground != nil || !parsed.isEmpty else { throw ThemeImportError.unreadable("no colours in the .tmTheme") }
        self.name = root["name"] as? String
        self.appearance = light ? .light : .dark
        self.background = background
        self.text = text
        self.rules = parsed
    }
}

// MARK: - Xcode

extension ParsedTheme {
    /// Xcode's own token names, and the vocabulary scope each one colours.
    static let xcodeScopes: [String: [String]] = [
        "xcode.syntax.keyword": ["keyword"],
        "xcode.syntax.comment": ["comment"],
        "xcode.syntax.string": ["string"],
        "xcode.syntax.character": ["constant.character.escape"],
        "xcode.syntax.number": ["constant.numeric"],
        "xcode.syntax.preprocessor": ["meta.preprocessor"],
        "xcode.syntax.attribute": ["entity.other.attribute"],
        "xcode.syntax.url": ["markup.link"],
        "xcode.syntax.markup.code": ["markup.raw"],
        "xcode.syntax.declaration.type": ["entity.name.type"],
        "xcode.syntax.identifier.type": ["entity.name.type"],
        "xcode.syntax.identifier.class": ["entity.name.type"],
        "xcode.syntax.declaration.other": ["entity.name.function"],
        "xcode.syntax.identifier.function": ["support.function"],
        "xcode.syntax.identifier.constant": ["constant.language"],
        "xcode.syntax.identifier.variable": ["variable.parameter"]
    ]

    init(xcode data: Data) throws {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let syntax = root["DVTSourceTextSyntaxColors"] as? [String: String] else {
            throw ThemeImportError.unreadable("not an .xccolortheme property list")
        }
        func color(_ value: String?, over base: HighlightColor?) -> HighlightColor? {
            // "r g b a", each 0...1.
            guard let parts = value?.split(whereSeparator: \.isWhitespace).compactMap({ Double($0) }), parts.count >= 3 else { return nil }
            let color = HighlightColor(red: parts[0], green: parts[1], blue: parts[2])
            guard parts.count >= 4, let base else { return color }
            return base.mixed(toward: color, by: min(max(parts[3], 0), 1))
        }
        let background = color(root["DVTSourceTextBackground"] as? String, over: nil) ?? .white
        let light = background.relativeLuminance > 0.4

        // Fonts only matter for bold and italic; their names say which.
        let fonts = root["DVTSourceTextSyntaxFonts"] as? [String: String] ?? [:]
        var parsed: [(selector: String, style: HighlightStyle)] = []
        for key in syntax.keys.sorted() {
            guard let scopes = Self.xcodeScopes[key] else { continue }
            let font = fonts[key]?.lowercased() ?? ""
            let style = HighlightStyle(
                color: color(syntax[key], over: background),
                bold: font.contains("bold") || font.contains("heavy") || font.contains("semibold"),
                italic: font.contains("italic") || font.contains("oblique")
            )
            parsed += scopes.map { ($0, style) }
        }
        self.name = nil
        self.appearance = light ? .light : .dark
        self.background = background
        self.text = color(syntax["xcode.syntax.plain"], over: background) ?? (light ? .black : .white)
        self.rules = parsed
    }
}

// MARK: - Names other themes use

/// For each vocabulary scope, the TextMate scope names themes commonly style
/// it under, most specific first. The first a theme styles is the one used.
enum ScopeAliases {
    static func candidates(for scope: String) -> [String] {
        [scope] + (aliases[scope] ?? [])
    }

    static let aliases: [String: [String]] = [
        "keyword": ["keyword.control", "storage.type", "storage.modifier", "storage", "keyword.other"],
        "variable.language": ["variable.language.this", "variable.language.self", "keyword"],
        "comment.line": ["comment"],
        "comment.block": ["comment.block.documentation", "comment"],
        "string.quoted": ["string.quoted.double", "string"],
        "string.regexp": ["string"],
        "constant.character.escape": ["constant.character", "string.escape"],
        "constant.numeric": ["constant.numeric.integer", "constant"],
        "constant.language": ["constant.language.boolean", "constant"],
        "entity.name.type": ["entity.name.class", "entity.name.struct", "support.type", "support.class", "storage.type"],
        "entity.name.function": ["support.function", "meta.function-call", "variable.function"],
        "entity.name.tag": ["meta.tag", "keyword"],
        "support.type.property-name": ["support.type.property-name.json", "meta.object-literal.key", "variable.other.property", "entity.name.tag"],
        "entity.other.attribute": ["entity.other.attribute-name"],
        "meta.preprocessor": ["keyword.control.directive", "keyword.control.import", "keyword"],
        "support.function": ["entity.name.function", "meta.function-call", "variable.function"],
        "punctuation.section.embedded": ["punctuation.definition.template-expression", "punctuation"],
        "invalid": ["invalid.illegal"],
        "variable.other": ["variable"],
        "variable.other.enummember": ["constant.other.enum", "variable.other.constant", "constant"],
        "variable.parameter": ["variable.parameter.function", "variable"],
        "markup.heading": ["entity.name.section", "markup.heading.markdown"],
        "markup.raw": ["markup.inline.raw", "markup.fenced_code", "string"],
        "markup.link": ["markup.underline.link", "string.other.link"]
    ]
}
