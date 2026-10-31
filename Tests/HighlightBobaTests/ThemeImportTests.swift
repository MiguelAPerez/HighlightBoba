import Foundation
import Testing
@testable import HighlightBoba

@Suite struct ThemeImportTests {
    static func hex(_ value: String) -> HighlightColor { HighlightColor(hex: value)! }

    static func vsCode(_ json: String) throws -> HighlightTheme {
        try HighlightTheme(importing: Data(json.utf8), format: .vsCode)
    }

    // MARK: - JSON with comments

    @Test func jsoncLosesCommentsAndTrailingCommasButNotStrings() throws {
        let text = """
        {
          // a line comment
          "a": "http://example.com/x", /* a block
          comment */ "b": [1, 2,],
          "c": "not // a comment, nor /* this */",
          "d": "a \\" quote, then ,}",
        }
        """
        let object = try #require(try JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8)) as? [String: Any])
        #expect(object["a"] as? String == "http://example.com/x")
        #expect(object["b"] as? [Int] == [1, 2])
        #expect(object["c"] as? String == "not // a comment, nor /* this */")
        #expect(object["d"] as? String == "a \" quote, then ,}")
    }

    @Test func anUnterminatedBlockCommentEndsTheText() {
        #expect(JSONC.strip("{\"a\": 1 /* open") == "{\"a\": 1 ")
    }

    // MARK: - Colours

    @Test func colourForms() throws {
        #expect(HighlightColor.parse("#ABC", over: nil) == Self.hex("#AABBCC"))
        #expect(HighlightColor.parse("#aabbcc", over: nil) == Self.hex("#AABBCC"))
        // 50% white over black.
        let half = try #require(HighlightColor.parse("#FFFFFF80", over: .black))
        #expect(abs(half.red - 128.0 / 255) < 0.01)
        #expect(HighlightColor.parse("#FFF8", over: .black) == HighlightColor.parse("#FFFFFF88", over: .black))
        #expect(HighlightColor.parse("#FFFFFF00", over: .black) == .black, "fully transparent is the background")
        for bad in ["FFFFFF", "#FFFFF", "#GGGGGG", "", "#", "red", "#１２３"] {
            #expect(HighlightColor.parse(bad, over: .white) == nil, "\(bad)")
        }
    }

    // MARK: - VS Code

    static let sample = """
    {
      "name": "Boba Test",
      "type": "dark",
      "colors": { "editor.background": "#101010", "editor.foreground": "#E0E0E0" },
      "tokenColors": [
        { "settings": { "foreground": "#E0E0E0" } },
        { "scope": "comment", "settings": { "foreground": "#707070", "fontStyle": "italic" } },
        { "scope": ["string", "string.regexp"], "settings": { "foreground": "#A0D0A0" } },
        { "scope": "storage.type, storage.modifier", "settings": { "foreground": "#C090F0", "fontStyle": "bold" } },
        { "scope": "source.swift entity.name.function", "settings": { "foreground": "#80B0F0" } },
        { "scope": "string - string.regexp", "settings": { "foreground": "#FF0000" } },
        { "scope": "constant.numeric", "settings": { "foreground": "#F0A060" } },
        { "scope": "constant.numeric", "settings": { "foreground": "#F0C080" } },
        { "scope": "entity.name.class", "settings": { "foreground": "#E0D070", "fontStyle": "italic underline" } }
      ]
    }
    """

    @Test func readsTheBasics() throws {
        let theme = try Self.vsCode(Self.sample)
        #expect(theme.name == "Boba Test")
        #expect(theme.appearance == .dark)
        #expect(theme.background == Self.hex("#101010"))
        #expect(theme.text == Self.hex("#E0E0E0"))
    }

    @Test func mapsTheVocabularyThroughCommonNames() throws {
        let theme = try Self.vsCode(Self.sample)
        // "keyword" isn't styled, so it falls back to storage.type.
        #expect(theme.styles["keyword"] == HighlightStyle(color: Self.hex("#C090F0"), bold: true))
        #expect(theme.styles["comment.line"] == HighlightStyle(color: Self.hex("#707070"), italic: true))
        #expect(theme.styles["comment.block"]?.color == Self.hex("#707070"))
        #expect(theme.styles["string.quoted"]?.color == Self.hex("#A0D0A0"))
        // A descendant selector counts by its last part.
        #expect(theme.styles["entity.name.function"]?.color == Self.hex("#80B0F0"))
        // entity.name.type falls back to entity.name.class; underline is ignored.
        #expect(theme.styles["entity.name.type"] == HighlightStyle(color: Self.hex("#E0D070"), italic: true))
    }

    @Test func theLaterOfTwoEqualRulesWins() throws {
        #expect(try Self.vsCode(Self.sample).styles["constant.numeric"]?.color == Self.hex("#F0C080"))
    }

    @Test func anExclusionSelectorIsDroppedNotHalfApplied() throws {
        // "string - string.regexp" would paint strings red if read as "string".
        #expect(try Self.vsCode(Self.sample).styles["string.quoted"]?.color != Self.hex("#FF0000"))
    }

    @Test func aScopeNothingStylesIsLeftOut() throws {
        let theme = try Self.vsCode(Self.sample)
        #expect(theme.styles["invalid"] == nil)
        #expect(theme.style(for: "invalid") == nil, "draws in the text colour")
        for scope in theme.styles.keys {
            #expect(Scopes.vocabulary.contains(scope), "\(scope) isn't a vocabulary scope")
        }
    }

    @Test func aLightThemeWithNoColoursGetsVSCodesDefaults() throws {
        let theme = try Self.vsCode(##"{"type": "light", "tokenColors": []}"##)
        #expect(theme.appearance == .light)
        #expect(theme.background == .white)
        #expect(theme.text == .black)
        #expect(theme.name == "Imported Theme")
    }

    @Test func aHighContrastLightThemeIsLight() throws {
        #expect(try Self.vsCode(##"{"type": "hcLight", "colors": {"editor.background": "#FFFFFF"}}"##).appearance == .light)
        #expect(try Self.vsCode(##"{"type": "hc", "colors": {"editor.background": "#000000"}}"##).appearance == .dark)
    }

    @Test func aTranslucentTokenColourIsLaidOverTheBackground() throws {
        let theme = try Self.vsCode(##"{"colors": {"editor.background": "#000000"}, "tokenColors": [{"scope": "keyword", "settings": {"foreground": "#FFFFFF80"}}]}"##)
        let keyword = try #require(theme.styles["keyword"]?.color)
        #expect(keyword.red > 0.45 && keyword.red < 0.55)
    }

    @Test(arguments: [
        "", "[]", "not json", ##"{"name": "nothing else"}"##, ##"{"tokenColors": "nope"}"##
    ])
    func rejectsWhatIsntATheme(_ text: String) {
        #expect(throws: ThemeImportError.self) { try Self.vsCode(text) }
    }

    @Test func rejectsAHugeFile() {
        let huge = Data(repeating: 0x20, count: HighlightTheme.maximumImportSize + 1)
        #expect(throws: ThemeImportError.tooLarge(bytes: huge.count)) { try HighlightTheme(importing: huge) }
    }

    @Test func theNamePicksUpOnlyLettersAndDigitsForTheID() throws {
        let theme = try Self.vsCode(##"{"name": "  Boba: Night (v2)  ", "colors": {"editor.background": "#000000"}}"##)
        #expect(theme.name == "Boba: Night (v2)")
        #expect(theme.id == "imported.bobanightv2")
    }

    // MARK: - TextMate

    static let tmTheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>name</key><string>Boba Light</string>
      <key>settings</key><array>
        <dict><key>settings</key><dict>
          <key>background</key><string>#FAFAF5</string>
          <key>foreground</key><string>#202020</string>
        </dict></dict>
        <dict><key>scope</key><string>keyword, storage</string>
          <key>settings</key><dict><key>foreground</key><string>#7030A0</string><key>fontStyle</key><string>bold</string></dict></dict>
        <dict><key>scope</key><string>comment</string>
          <key>settings</key><dict><key>foreground</key><string>#808080</string></dict></dict>
      </array>
    </dict></plist>
    """

    @Test func readsATextMateTheme() throws {
        let theme = try HighlightTheme(importing: Data(Self.tmTheme.utf8), format: .textMate)
        #expect(theme.name == "Boba Light")
        #expect(theme.appearance == .light, "told by the background")
        #expect(theme.background == Self.hex("#FAFAF5"))
        #expect(theme.styles["keyword"] == HighlightStyle(color: Self.hex("#7030A0"), bold: true))
        #expect(theme.styles["comment.line"]?.color == Self.hex("#808080"))
    }

    // MARK: - Xcode

    static let xcode = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>DVTSourceTextBackground</key><string>0.1 0.1 0.12 1</string>
      <key>DVTSourceTextSyntaxColors</key><dict>
        <key>xcode.syntax.plain</key><string>0.9 0.9 0.9 1</string>
        <key>xcode.syntax.keyword</key><string>1 0.4 0.6 1</string>
        <key>xcode.syntax.comment</key><string>0.5 0.55 0.6 1</string>
        <key>xcode.syntax.string</key><string>1 0.5 0.4 1</string>
        <key>xcode.syntax.not.a.real.key</key><string>0 1 0 1</string>
      </dict>
      <key>DVTSourceTextSyntaxFonts</key><dict>
        <key>xcode.syntax.keyword</key><string>SFMono-Bold - 13.0</string>
        <key>xcode.syntax.comment</key><string>SFMono-RegularItalic - 13.0</string>
      </dict>
    </dict></plist>
    """

    @Test func readsAnXcodeTheme() throws {
        let theme = try HighlightTheme(importing: Data(Self.xcode.utf8), format: .xcode, name: "From Xcode")
        #expect(theme.name == "From Xcode", "an .xccolortheme carries no name")
        #expect(theme.appearance == .dark)
        #expect(theme.styles["keyword"] == HighlightStyle(color: HighlightColor(red: 1, green: 0.4, blue: 0.6), bold: true))
        #expect(theme.styles["comment.block"] == HighlightStyle(color: HighlightColor(red: 0.5, green: 0.55, blue: 0.6), italic: true))
        #expect(theme.styles["string.quoted"]?.color == HighlightColor(red: 1, green: 0.5, blue: 0.4))
        #expect(!theme.styles.values.contains { $0.color == HighlightColor(red: 0, green: 1, blue: 0) }, "unknown keys are ignored")
    }

    // MARK: - Choosing the format

    @Test func withNoFormatEachIsTried() throws {
        #expect(try HighlightTheme(importing: Data(Self.sample.utf8)).name == "Boba Test")
        #expect(try HighlightTheme(importing: Data(Self.tmTheme.utf8)).name == "Boba Light")
        #expect(try HighlightTheme(importing: Data(Self.xcode.utf8)).appearance == .dark)
    }

    @Test func fileExtensionsNameTheirFormats() {
        #expect(ThemeFormat(fileExtension: "JSON") == .vsCode)
        #expect(ThemeFormat(fileExtension: "tmTheme") == .textMate)
        #expect(ThemeFormat(fileExtension: "xccolortheme") == .xcode)
        #expect(ThemeFormat(fileExtension: "txt") == nil)
    }

    @Test func anImportedThemeCanBeMadeReadable() throws {
        let theme = try Self.vsCode(Self.sample).readable(ratio: 4.5)
        #expect(try #require(theme.styles["comment.line"]?.color).contrast(with: theme.background) >= 4.5)
    }
}
