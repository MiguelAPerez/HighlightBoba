import Foundation
import Testing
@testable import HighlightBoba

@Suite struct ThemeTests {
    static let blue = HighlightColor(hex: "#0000FF")!
    static let red = HighlightColor(hex: "#FF0000")!
    static let green = HighlightColor(hex: "#00FF00")!

    static func theme(_ styles: [String: HighlightStyle], background: HighlightColor = .white) -> HighlightTheme {
        HighlightTheme(id: "test", name: "Test", appearance: .light, background: background, text: .black, styles: styles)
    }

    // MARK: - Colours

    @Test(arguments: ["#1E66F5", "1E66F5", "#1e66f5", "  #1E66F5\n"])
    func parsesSixDigitHex(_ hex: String) throws {
        let color = try #require(HighlightColor(hex: hex))
        #expect(color.hex == "#1E66F5")
    }

    @Test(arguments: ["", "#", "#FFF", "#FFFFFFFF", "#GGGGGG", "##FFFFFF", "#FF FF FF", "+1E66F5", "#１２３４５６"])
    func rejectsAnythingElse(_ hex: String) {
        #expect(HighlightColor(hex: hex) == nil)
    }

    @Test func clampsComponentsAndNaN() {
        let color = HighlightColor(red: 2, green: -1, blue: .nan)
        #expect(color == HighlightColor(red: 1, green: 0, blue: 0))
    }

    @Test func hexRoundTripsEveryByteValue() throws {
        for byte in 0...255 {
            let hex = "#" + String(repeating: String(format: "%02X", byte), count: 3)
            #expect(try #require(HighlightColor(hex: hex)).hex == hex)
        }
    }

    // MARK: - Contrast

    @Test func contrastSpansOneToTwentyOne() {
        #expect(abs(HighlightColor.black.contrast(with: .white) - 21) < 0.001)
        #expect(HighlightColor.white.contrast(with: .black) == HighlightColor.black.contrast(with: .white))
        #expect(Self.blue.contrast(with: Self.blue) == 1)
    }

    @Test func readableKeepsAColourThatAlreadyPasses() {
        #expect(HighlightColor.black.readable(on: .white, ratio: 4.5) == .black)
    }

    @Test(arguments: [4.5, 7.0])
    func readableDeepensOnLightAndBrightensOnDark(_ ratio: Double) throws {
        // Dracula's comment on its own background reads at about 3:1.
        let comment = try #require(HighlightColor(hex: "#6272A4"))
        let dark = try #require(HighlightColor(hex: "#282A36"))
        #expect(comment.contrast(with: dark) < 4.5)
        let raised = comment.readable(on: dark, ratio: ratio)
        #expect(raised.contrast(with: dark) >= ratio)
        #expect(raised.relativeLuminance > comment.relativeLuminance)

        let orange = try #require(HighlightColor(hex: "#FF9500"))
        #expect(orange.contrast(with: .white) < 4.5)
        let deepened = orange.readable(on: .white, ratio: ratio)
        #expect(deepened.contrast(with: .white) >= ratio)
        #expect(deepened.relativeLuminance < orange.relativeLuminance)
    }

    @Test func readableReturnsTheBestItCanWhenTheTargetIsOutOfReach() throws {
        let grey = try #require(HighlightColor(hex: "#777777"))
        let best = Self.blue.readable(on: grey, ratio: 21)
        #expect(best == .black || best == .white)
    }

    // MARK: - Selectors

    @Test func aSelectorMatchesItselfAndItsDottedDescendants() {
        #expect(HighlightTheme.selector("string", matches: "string"))
        #expect(HighlightTheme.selector("string", matches: "string.quoted"))
        #expect(HighlightTheme.selector("string.quoted", matches: "string.quoted"))
    }

    @Test func aSelectorDoesNotMatchAPartialWordAParentOrNothing() {
        #expect(!HighlightTheme.selector("str", matches: "string.quoted"))
        #expect(!HighlightTheme.selector("string.quoted", matches: "string"))
        #expect(!HighlightTheme.selector("string.quoted.double", matches: "string.quoted"))
        #expect(!HighlightTheme.selector("", matches: "string"))
        #expect(!HighlightTheme.selector("keyword", matches: ""))
        #expect(!HighlightTheme.selector("string.", matches: "string.quoted"))
    }

    @Test func theLongestMatchingSelectorWins() {
        let theme = Self.theme([
            "string": HighlightStyle(color: Self.blue),
            "string.regexp": HighlightStyle(color: Self.red)
        ])
        #expect(theme.style(for: "string.regexp")?.color == Self.red)
        #expect(theme.style(for: "string.quoted")?.color == Self.blue)
        #expect(theme.style(for: "keyword") == nil)
    }

    @Test func stylesByScopeCoversTheVocabularyTheSelectorsReach() {
        let theme = Self.theme([
            "comment": HighlightStyle(color: Self.green, italic: true),
            "keyword": HighlightStyle(bold: true)
        ])
        let byScope = theme.stylesByScope
        #expect(Set(byScope.keys) == ["comment.line", "comment.block", "keyword"])
        #expect(byScope["comment.block"]?.italic == true)
        #expect(byScope["keyword"]?.color == nil)
    }

    @Test func readableThemeRaisesTextAndEveryColourButKeepsTheRest() throws {
        let yellow = try #require(HighlightColor(hex: "#FFFF00"))
        var theme = Self.theme([
            "string": HighlightStyle(color: yellow, bold: true),
            "keyword": HighlightStyle(italic: true)
        ])
        theme.text = try #require(HighlightColor(hex: "#BBBBBB"))
        let readable = theme.readable(ratio: 4.5)
        #expect(readable.text.contrast(with: .white) >= 4.5)
        #expect(try #require(readable.styles["string"]?.color).contrast(with: .white) >= 4.5)
        #expect(readable.styles["string"]?.bold == true)
        #expect(readable.styles["keyword"] == HighlightStyle(italic: true))
        #expect(readable.background == theme.background)
    }

    // MARK: - Files

    @Test func decodesAThemeFileWithOptionalStyleKeys() throws {
        let json = """
        {
          "id": "boba-night", "name": "Boba Night", "appearance": "dark",
          "background": "#1A1B26", "text": "#C0CAF5",
          "styles": {
            "keyword": { "color": "#BB9AF7", "bold": true },
            "comment": { "italic": true },
            "string": { "color": "#9ECE6A" }
          }
        }
        """
        let theme = try JSONDecoder().decode(HighlightTheme.self, from: Data(json.utf8))
        #expect(theme.appearance == .dark)
        #expect(theme.style(for: "keyword") == HighlightStyle(color: HighlightColor(hex: "#BB9AF7"), bold: true))
        #expect(theme.style(for: "comment.line") == HighlightStyle(italic: true))
        #expect(theme.style(for: "string.quoted")?.bold == false)
    }

    @Test func roundTripsThroughJSON() throws {
        let theme = Self.theme(["keyword": HighlightStyle(color: Self.blue, bold: true), "comment": HighlightStyle(italic: true)])
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(HighlightTheme.self, from: data) == theme)
    }

    @Test(arguments: [
        ##"{"id":"x","name":"X","appearance":"dark","background":"#12345","text":"#FFFFFF","styles":{}}"##,
        ##"{"id":"x","name":"X","appearance":"sepia","background":"#123456","text":"#FFFFFF","styles":{}}"##,
        ##"{"id":"x","name":"X","appearance":"dark","background":"#123456","text":"#FFFFFF","styles":{"keyword":{"color":"blue"}}}"##,
        ##"{"id":"x","name":"X","appearance":"dark","background":"#123456","styles":{}}"##
    ])
    func rejectsAMalformedThemeFile(_ json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HighlightTheme.self, from: Data(json.utf8)) }
    }
}
