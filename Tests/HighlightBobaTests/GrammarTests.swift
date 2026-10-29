import Foundation
import Testing
@testable import HighlightBoba

@Suite struct GrammarTests {
    static func grammar(_ json: String) throws -> Grammar { try Grammar(data: Data(json.utf8)) }

    static func error(_ json: String) -> String? {
        do {
            _ = try grammar(json)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test(arguments: Grammar.bundledNames)
    func bundledGrammarLoadsAndUsesOnlyVocabularyScopes(_ name: String) throws {
        let grammar = try Grammar.bundled(name)
        #expect(grammar.name == name)
        #expect(!grammar.fileExtensions.isEmpty)
        for scope in grammar.scopes {
            #expect(Scopes.vocabulary.contains(scope), "\(name) emits \(scope), which is not in Scopes.vocabulary")
        }
    }

    @Test func shipsTheStarterLanguages() {
        #expect(Set(Grammar.bundledNames).isSuperset(of: ["json", "swift", "python"]))
    }

    @Test func unknownBundledGrammarThrows() {
        #expect(throws: GrammarError.self) { try Grammar.bundled("cobol") }
    }

    @Test(arguments: [
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"literal":"a"},"push":"b"}]}}}"#, "pushes unknown state"),
        (#"{"name":"x","initial":"z","states":{"a":{"rules":[]}}}"#, "initial state"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"regex":"a+"}}]}}}"#, "unknown matcher"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"literal":"a"},"scop":"keyword"}]}}}"#, "unknown key \"scop\""),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"class":"[z-a]"}}]}}}"#, "reversed range"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"class":"abc"}}]}}}"#, "must look like"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"class":"[🧋]"}}]}}}"#, "outside the BMP"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"literal":""}}]}}}"#, "empty literal"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"match":{"repeat":"[a]","min":3,"max":2}}]}}}"#, "repeat bounds"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"include":"b"}]},"b":{"rules":[{"include":"a"}]}}}"#, "include cycle"),
        (#"{"name":"x","initial":"a","states":{"a":{"rules":[{"include":"nope"}]}}}"#, "unknown state"),
        (#"[1, 2]"#, "JSON object"),
        (#"not json"#, "not valid JSON")
    ])
    func invalidGrammarIsRejectedWithAMessage(_ json: String, _ message: String) {
        let error = Self.error(json)
        #expect(error?.contains(message) == true, "expected an error mentioning \(message.debugDescription), got \(error ?? "no error")")
    }

    @Test func characterClassParsesRangesEscapesAndNegation() throws {
        let digits = try CharClass.parse(#"[\d.]"#)
        #expect(digits.contains(UInt16(UInt8(ascii: "7"))) && digits.contains(UInt16(UInt8(ascii: "."))))
        #expect(!digits.contains(UInt16(UInt8(ascii: "a"))))
        let notQuote = try CharClass.parse(#"[^"\\]"#)
        #expect(!notQuote.contains(UInt16(UInt8(ascii: "\""))) && !notQuote.contains(UInt16(UInt8(ascii: "\\"))))
        #expect(notQuote.contains(0x00E9) && notQuote.contains(0xD83E), "negated class matches non-ASCII and surrogate halves")
        let signs = try CharClass.parse("[+-]")
        #expect(signs.contains(UInt16(UInt8(ascii: "-"))) && signs.contains(UInt16(UInt8(ascii: "+"))))
        let accented = try CharClass.parse("[à-ö]")
        #expect(accented.contains(0x00E9) && !accented.contains(0x00F8))
    }
}
