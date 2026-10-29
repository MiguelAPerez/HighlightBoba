import Foundation
import Testing
@testable import HighlightBoba

/// Engine behaviour that fixtures can't show well: exact UTF-16 ranges, nesting limits, and
/// grammars written to probe the scanner's guards.
@Suite struct EngineTests {
    static let swift = try! Grammar.bundled("swift")
    static let json = try! Grammar.bundled("json")

    static func tokens(_ text: String, _ grammar: Grammar = swift) -> [String] {
        let units = Array(text.utf16)
        return Highlighter.highlight(text, grammar: grammar).map {
            let body = String(decoding: units[$0.range.location..<NSMaxRange($0.range)], as: UTF16.self)
            return "\($0.scope):\(body)"
        }
    }

    @Test func emptyInputHasNoTokens() {
        #expect(Highlighter.highlight("", grammar: Self.swift).isEmpty)
        #expect(Highlighter.highlight("\n\n", grammar: Self.json).isEmpty)
    }

    @Test func rangesAreUTF16() {
        // 🧋 is two UTF-16 units; the string token after it must start at offset 6, not 5.
        let tokens = Highlighter.highlight("🧋 = \"a\"", grammar: Self.swift)
        #expect(tokens == [HighlightToken(range: NSRange(location: 5, length: 3), scope: "string.quoted")])
        let text = "let 👩‍💻 = 1"
        let number = Highlighter.highlight(text, grammar: Self.swift).last!
        #expect(number.range.location == (text as NSString).range(of: "1").location)
    }

    @Test func surrogatePairsAreNeverSplit() {
        let text = "\"🧋\\🧋\""
        for token in Highlighter.highlight(text, grammar: Self.json) {
            let units = Array(text.utf16)
            #expect(!UTF16.isTrailSurrogate(units[token.range.location]), "token starts mid-pair: \(token)")
            if NSMaxRange(token.range) < units.count {
                #expect(!UTF16.isTrailSurrogate(units[NSMaxRange(token.range)]), "token ends mid-pair: \(token)")
            }
        }
    }

    @Test func crlfIsOneLineBreakAndNotHighlighted() {
        let text = "let a = \"x\r\nlet b\r\n"
        #expect(Self.tokens(text) == ["keyword:let", "string.quoted:\"x", "keyword:let"])
        let tokens = Highlighter.highlight(text, grammar: Self.swift)
        let units = Array(text.utf16)
        #expect(tokens.allSatisfy { !$0.range.contains(units.firstIndex(of: 13)!) })
    }

    @Test func loneCarriageReturnBreaksLines() {
        #expect(Self.tokens("let a = \"x\rlet") == ["keyword:let", "string.quoted:\"x", "keyword:let"])
    }

    @Test func unterminatedStringAtEOFRunsToTheEnd() {
        #expect(Self.tokens("let s = \"abc") == ["keyword:let", "string.quoted:\"abc"])
        #expect(Self.tokens("let s = \"\"\"\nabc") == ["keyword:let", "string.quoted:\"\"\"", "string.quoted:abc"])
    }

    @Test func nestedCommentsCloseAtTheMatchingDelimiter() {
        #expect(Self.tokens("/* a /* b */ c */ let") == ["comment.block:/* a /* b */ c */", "keyword:let"])
        #expect(Self.tokens("/* a /* b */ c") == ["comment.block:/* a /* b */ c"])
        #expect(Self.tokens("*/ let") == ["keyword:let"], "a stray closer outside a comment is plain text")
    }

    @Test func interpolationNestsStringsAndParens() {
        let tokens = Self.tokens(#""a \(f("b \(c)", (d))) e""#)
        #expect(tokens == [
            "string.quoted:\"a ", "punctuation.section.embedded:\\(", "string.quoted:\"b ",
            "punctuation.section.embedded:\\(", "punctuation.section.embedded:)", "string.quoted:\"",
            "punctuation.section.embedded:)", "string.quoted: e\""
        ])
    }

    @Test func keywordsNeedWordBoundaries() {
        #expect(Self.tokens("letter iffy x1 _if if_") == [])
        #expect(Self.tokens("(let)") == ["keyword:let"])
    }

    @Test func hostileNestingIsCappedNotUnbounded() {
        let deep = String(repeating: "/*", count: 10_000) + " x " + String(repeating: "*/ ", count: 10_000) + " let"
        let highlighter = Highlighter(grammar: Self.swift, text: deep)
        // Pushes past maxDepth are dropped, so the closers run out early and `let` is code again.
        #expect(highlighter.tokens.last?.scope == "keyword")
    }

    @Test func zeroWidthRulesCannotLoop() throws {
        let grammar = try GrammarTests.grammar(#"""
        {"name":"t","initial":"a","states":{
          "a":{"rules":[{"match":{"repeat":"[x]"},"scope":"keyword"},
                        {"match":{"opt":{"literal":"y"}},"push":"b"},
                        {"match":{"literal":"("},"push":"b"}]},
          "b":{"scope":"string.quoted","rules":[{"match":{"repeat":"[q]","min":1},"pop":true},
                                                {"match":{"eol":true},"pop":true}]}}}
        """#)
        // The `a` rules can match empty without popping; the scanner must skip them and still advance.
        #expect(Self.tokens("zz(ab\nxx", grammar) == ["string.quoted:ab", "keyword:xx"])
    }

    @Test func eolRulePopsAtLineEnd() throws {
        let grammar = try GrammarTests.grammar(#"""
        {"name":"t","initial":"a","states":{
          "a":{"rules":[{"match":{"literal":"#"},"scope":"comment.line","push":"c"},{"match":{"literal":"k"},"scope":"keyword"}]},
          "c":{"scope":"comment.line","rules":[{"match":{"eol":true},"pop":true}]}}}
        """#)
        #expect(Self.tokens("k #k k\nk", grammar) == ["keyword:k", "comment.line:#k k", "keyword:k"])
    }
}
