import Foundation
import Testing
@testable import HighlightBoba

/// The constructs format v0 couldn't express, each with a small inline grammar so the feature is
/// tested on its own. The language grammars that use these features have fixtures of their own.
@Suite struct FormatV1Tests {
    static func tokens(_ text: String, _ grammar: Grammar) -> [String] {
        let units = Array(text.utf16)
        return Highlighter.highlight(text, grammar: grammar).map {
            "\($0.scope):\(String(decoding: units[$0.range.location..<NSMaxRange($0.range)], as: UTF16.self))"
        }
    }

    static func grammar(_ states: String, initial: String = "code") throws -> Grammar {
        try Grammar(data: Data(#"{"name":"t","initial":"\#(initial)","states":\#(states)}"#.utf8))
    }

    // MARK: anyOf, captures

    @Test func anyOfTriesAlternativesInOrder() throws {
        let grammar = try Self.grammar(#"""
        {"code":{"rules":[{"match":{"seq":[{"anyOf":[{"literal":"0x"},{"literal":"0b"},{"literal":"0"}]},{"repeat":"[0-9A-Fa-f]","min":1}]},"scope":"constant.numeric"}]}}
        """#)
        #expect(Self.tokens("0x1F 0b10 017 x9", grammar) == ["constant.numeric:0x1F", "constant.numeric:0b10", "constant.numeric:017"])
    }

    @Test func capturesGiveEachSequencePartItsOwnScope() throws {
        let grammar = try Self.grammar(#"""
        {"code":{"rules":[{"match":{"seq":[{"words":["func"]},{"repeat":"[ \\t]","min":1},{"wordStarting":"[A-Za-z_]"}]},
                           "captures":["keyword",null,"entity.name.function"]}]}}
        """#)
        #expect(Self.tokens("func load() funcx y", grammar) == ["keyword:func", "entity.name.function:load"])
    }

    // MARK: lookahead and look-behind

    @Test func followedByPeeksWithoutConsuming() throws {
        let grammar = try Self.grammar(#"""
        {"code":{"rules":[
          {"match":{"seq":[{"wordStarting":"[a-z_]"},{"followedBy":{"seq":[{"repeat":"[ \\t]"},{"literal":"("}]}}]},"scope":"support.function"},
          {"match":{"literal":"("},"scope":"punctuation"},
          {"match":{"seq":[{"wordStarting":"[A-Z]"},{"notFollowedBy":{"literal":"."}}]},"scope":"entity.name.type"}]}}
        """#)
        #expect(Self.tokens("print (x) value Type Enum.case", grammar) == [
            "support.function:print", "punctuation:(", "entity.name.type:Type"
        ])
    }

    @Test func notAfterTellsRegexFromDivision() throws {
        // A `/` after an identifier, number or closing bracket divides; anywhere else it starts a regex.
        let grammar = try Self.grammar(#"""
        {"code":{"rules":[
          {"match":{"literal":"/"},"scope":"string.quoted","push":"regex","notAfter":"[A-Za-z0-9_$)\\]]"},
          {"match":{"literal":"/"},"scope":"punctuation"}]},
         "regex":{"scope":"string.quoted","endsAtEOL":true,"rules":[
          {"match":{"seq":[{"literal":"\\"},{"class":"[^\\r\\n]"}]}},
          {"match":{"seq":[{"literal":"/"},{"repeat":"[a-z]"}]},"pop":true}]}}
        """#)
        #expect(Self.tokens("a / b / 2", grammar) == ["punctuation:/", "punctuation:/"])
        #expect(Self.tokens("x = /ab\\/c/gi", grammar) == ["string.quoted:/ab\\/c/gi"])
        #expect(Self.tokens("f(/x/) / 2", grammar) == ["string.quoted:/x/", "punctuation:/"])
        #expect(Self.tokens("/start/", grammar) == ["string.quoted:/start/"], "line start counts as not-after")
    }

    // MARK: remembered delimiters

    static let heredoc = #"""
    {"code":{"rules":[
      {"match":{"seq":[{"literal":"<<"},{"opt":{"literal":"-"}},{"opt":{"class":"['\"]"}},{"wordStarting":"[A-Za-z_]"},{"opt":{"class":"['\"]"}}]},
       "scope":"keyword","push":"heredoc","remember":3}]},
     "heredoc":{"scope":"string.quoted","rules":[
      {"match":{"seq":[{"bol":true},{"repeat":"[\\t]"},{"remembered":true},{"eol":true}]},"scope":"keyword","pop":true}]}}
    """#

    @Test func heredocEndsOnlyAtItsOwnDelimiterAtLineStart() throws {
        let grammar = try Self.grammar(Self.heredoc)
        let text = "cat <<EOF\nnot EOF here\nEOFX\nEOF\nafter\ncat <<-'END'\nbody\n\tEND\n"
        #expect(Self.tokens(text, grammar) == [
            "keyword:<<EOF", "string.quoted:not EOF here", "string.quoted:EOFX", "keyword:EOF",
            "keyword:<<-'END'", "string.quoted:body", "keyword:\tEND"
        ])
    }

    @Test func unterminatedHeredocRunsToEOF() throws {
        let grammar = try Self.grammar(Self.heredoc)
        #expect(Self.tokens("x <<A\nB\nAA", grammar) == ["keyword:<<A", "string.quoted:B", "string.quoted:AA"])
    }

    @Test func swiftRawStringsMatchTheirHashCount() throws {
        let swift = try Grammar.bundled("swift")
        #expect(Self.tokens(##"let a = #"no \(interp) "quote" "#"##, swift) == [
            "keyword:let", ##"string.quoted:#"no \(interp) "quote" "#"##
        ])
        #expect(Self.tokens(###"let b = ##"one "# still"## + "x""###, swift) == [
            "keyword:let", ###"string.quoted:##"one "# still"##"###, "string.quoted:\"x\""
        ])
        #expect(Self.tokens(##"let c = #"v \#(n) \#n"#"##, swift) == [
            "keyword:let", ##"string.quoted:#"v "##, ##"punctuation.section.embedded:\#("##,
            "punctuation.section.embedded:)", "string.quoted: ", ##"constant.character.escape:\#n"##, ##"string.quoted:"#"##
        ])
    }

    // MARK: indentation

    static let blockScalar = #"""
    {"code":{"rules":[
      {"match":{"seq":[{"wordStarting":"[a-z]"},{"literal":":"}]},"scope":"keyword"},
      {"match":{"class":"[|>]"},"scope":"punctuation","push":"block","rememberIndent":true}]},
     "block":{"scope":"string.quoted","endsAtDedent":true,"rules":[]}}
    """#

    @Test func blockScalarEndsAtDedentNotAtBlankLines() throws {
        let grammar = try Self.grammar(Self.blockScalar)
        let text = "  key: |\n    line one\n\n      deeper\n  next: 1\n"
        #expect(Self.tokens(text, grammar) == [
            "keyword:key:", "punctuation:|", "string.quoted:    line one", "string.quoted:      deeper", "keyword:next:"
        ])
    }

    // MARK: embedding

    static let markdown = #"""
    {"text":{"rules":[
      {"match":{"seq":[{"bol":true},{"repeat":"[ ]","max":3},{"repeat":"[`]","min":3},{"repeat":"[ ]"},{"repeat":"[A-Za-z0-9_+-]"}]},
       "captures":[null,null,"punctuation",null,"keyword"],"push":"fence","remember":2,"embedPart":4}]},
     "fence":{"scope":"string.quoted","rules":[
      {"match":{"seq":[{"bol":true},{"repeat":"[ ]","max":3},{"remembered":true},{"repeat":"[`]"},{"eol":true}]},"scope":"punctuation","pop":true}]}}
    """#

    @Test func fencedCodeIsHighlightedByTheNamedGrammar() throws {
        let grammar = try Self.grammar(Self.markdown, initial: "text")
        let text = "Intro\n```swift\nlet x = \"```\"\n````\nafter\n"
        #expect(Self.tokens(text, grammar) == [
            "punctuation:```", "keyword:swift", "keyword:let", "string.quoted:\"```\"", "punctuation:````"
        ], "a longer closing fence closes; a fence inside a Swift string does not")
    }

    @Test func fenceWithUnknownOrNoLanguageUsesTheHostScope() throws {
        let grammar = try Self.grammar(Self.markdown, initial: "text")
        #expect(Self.tokens("```cobol\nMOVE A\n```\n", grammar) == [
            "punctuation:```", "keyword:cobol", "string.quoted:MOVE A", "punctuation:```"
        ])
        #expect(Self.tokens("```\nplain\n```", grammar) == ["punctuation:```", "string.quoted:plain", "punctuation:```"])
    }

    @Test func embeddedGrammarStateCarriesAcrossLines() throws {
        let grammar = try Self.grammar(Self.markdown, initial: "text")
        let text = "```swift\n/* open\n``` still comment\n*/ let\n```\n"
        #expect(Self.tokens(text, grammar) == [
            "punctuation:```", "keyword:swift", "comment.block:/* open", "comment.block:``` still comment",
            "comment.block:*/", "keyword:let", "punctuation:```"
        ])
    }

    @Test func embeddingByFileExtensionAndNamedEmbed() throws {
        let grammar = try Self.grammar(#"""
        {"text":{"rules":[{"match":{"literal":"<py>"},"scope":"keyword","push":"py","embed":"py"}]},
         "py":{"rules":[{"match":{"literal":"</py>"},"scope":"keyword","pop":true}]}}
        """#, initial: "text")
        #expect(Self.tokens("<py>None</py> None", grammar) == ["keyword:<py>", "constant.language:None", "keyword:</py>"])
    }

    // MARK: validation

    @Test(arguments: [
        (#"{"code":{"rules":[{"match":{"literal":"a"},"captures":["keyword"]}]}}"#, "captures"),
        (#"{"code":{"rules":[{"match":{"seq":[{"literal":"a"}]},"captures":["keyword","keyword"]}]}}"#, "captures"),
        (#"{"code":{"rules":[{"match":{"seq":[{"literal":"a"}]},"remember":0}]}}"#, "needs \"push\""),
        (#"{"code":{"rules":[{"match":{"seq":[{"literal":"a"}]},"push":"code","remember":3}]}}"#, "remember"),
        (#"{"code":{"rules":[{"match":{"literal":"a"},"embed":"swift"}]}}"#, "needs \"push\""),
        (#"{"code":{"rules":[{"match":{"anyOf":[]}}]}}"#, "anyOf"),
        (#"{"code":{"rules":[{"match":{"literal":"a"},"notAfter":"oops"}]}}"#, "must look like")
    ])
    func invalidV1RulesAreRejected(_ states: String, _ message: String) {
        do {
            _ = try Self.grammar(states)
            Issue.record("expected an error mentioning \(message)")
        } catch {
            #expect(String(describing: error).contains(message), "got \(error)")
        }
    }
}
