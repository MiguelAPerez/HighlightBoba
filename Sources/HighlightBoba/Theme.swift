import Foundation

/// An opaque sRGB colour, each component in `0...1`. Written as `#RRGGBB` in a theme file.
public struct HighlightColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    /// Parses `RRGGBB`, with or without a leading `#`, in either case; `nil` for anything else.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB`, upper case.
    public var hex: String {
        func byte(_ v: Double) -> String {
            let n = Int((v * 255).rounded())
            return String(n, radix: 16, uppercase: true).leftPadded(to: 2)
        }
        return "#" + byte(red) + byte(green) + byte(blue)
    }

    public static let black = HighlightColor(red: 0, green: 0, blue: 0)
    public static let white = HighlightColor(red: 1, green: 1, blue: 1)

    private static func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }
}

extension HighlightColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = HighlightColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not a #RRGGBB colour")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

// MARK: - Contrast

extension HighlightColor {
    /// WCAG 2.x relative luminance, `0` for black to `1` for white.
    public var relativeLuminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio with `other`, `1` (none) to `21` (black on white). Order doesn't matter.
    public func contrast(with other: HighlightColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour, unchanged if it already reaches `ratio` against `background`; otherwise mixed toward
    /// black (on a light background) or white (on a dark one) just far enough to reach it, so the hue stays
    /// recognisable. When even black or white can't reach `ratio`, the end of the mix: the best there is.
    public func readable(on background: HighlightColor, ratio target: Double) -> HighlightColor {
        guard contrast(with: background) < target else { return self }
        let toward: HighlightColor = Self.black.contrast(with: background) >= Self.white.contrast(with: background) ? .black : .white
        // Contrast rises monotonically along the mix, so bisect for the smallest mix that clears the target.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if mixed(toward: toward, by: mid).contrast(with: background) >= target { high = mid } else { low = mid }
        }
        return mixed(toward: toward, by: high)
    }

    func mixed(toward other: HighlightColor, by amount: Double) -> HighlightColor {
        HighlightColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}

// MARK: - Styles and themes

/// How one kind of token draws. A `nil` colour is the theme's text colour.
public struct HighlightStyle: Hashable, Sendable {
    public var color: HighlightColor?
    public var bold: Bool
    public var italic: Bool

    public init(color: HighlightColor? = nil, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

extension HighlightStyle: Codable {
    private enum CodingKeys: String, CodingKey { case color, bold, italic }

    /// Every key optional, so `{"color": "#0000FF"}` is a whole style.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(HighlightColor.self, forKey: .color)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(color, forKey: .color)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
    }
}

/// What highlighted code looks like: a background, a text colour, and a style per scope.
///
/// Styles are keyed by scope *selector*. A selector matches a scope when it is the scope or a
/// dot-separated prefix of it, so `"string"` styles `string.quoted` and `string.regexp`, and the
/// longest matching selector wins: `"string.regexp"` beats `"string"` for a regex. A scope no
/// selector matches draws in ``text``.
public struct HighlightTheme: Hashable, Sendable, Codable, Identifiable {
    public enum Appearance: String, Hashable, Sendable, Codable {
        case light, dark
    }

    public var id: String
    public var name: String
    public var appearance: Appearance
    public var background: HighlightColor
    public var text: HighlightColor
    public var styles: [String: HighlightStyle]

    public init(
        id: String,
        name: String,
        appearance: Appearance,
        background: HighlightColor,
        text: HighlightColor,
        styles: [String: HighlightStyle]
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = background
        self.text = text
        self.styles = styles
    }

    /// The style of the longest selector matching `scope`, or `nil` when none does.
    public func style(for scope: String) -> HighlightStyle? {
        var best: (length: Int, style: HighlightStyle)?
        for (selector, style) in styles where Self.selector(selector, matches: scope) {
            if selector.utf8.count > best?.length ?? -1 { best = (selector.utf8.count, style) }
        }
        return best?.style
    }

    /// The style of every scope in ``Scopes/vocabulary`` that some selector matches, looked up once,
    /// for a renderer that styles tokens by their exact scope.
    public var stylesByScope: [String: HighlightStyle] {
        var result: [String: HighlightStyle] = [:]
        for scope in Scopes.vocabulary {
            if let style = style(for: scope) { result[scope] = style }
        }
        return result
    }

    /// This theme with ``text`` and every style's colour made readable on ``background`` at `ratio`
    /// (4.5 is WCAG AA for text, 7 is AAA). Colours that already reach it are kept as they are.
    public func readable(ratio: Double) -> HighlightTheme {
        var theme = self
        theme.text = text.readable(on: background, ratio: ratio)
        theme.styles = styles.mapValues { style in
            var style = style
            style.color = style.color?.readable(on: background, ratio: ratio)
            return style
        }
        return theme
    }

    static func selector(_ selector: String, matches scope: String) -> Bool {
        let scope = scope.utf8, selector = selector.utf8
        guard !selector.isEmpty, scope.starts(with: selector) else { return false }
        return scope.count == selector.count
            || scope[scope.index(scope.startIndex, offsetBy: selector.count)] == UInt8(ascii: ".")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
