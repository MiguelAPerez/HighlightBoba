import Foundation
import Testing
@testable import HighlightBoba

/// SplitMix64: a seeded generator so a failing edit sequence can be replayed from its seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct IncrementalTests {
    /// Fragments that open and close states, so random edits keep changing what later lines mean.
    static let fragments: [String: [String]] = [
        "swift": ["/*", "*/", "\"", "\"\"\"", "\\(", ")", "(", "let ", "x", " ", "\n", "\r\n", "// c", "1.5", "🧋", "\\n", "Type",
                  "#", "##", "\\#(", "func f"],
        "python": ["\"", "'''", "\"\"\"", "f\"", "{", "}", "#", "def ", "x", " ", "\n", "\r\n", "r'", "\\", "🧋", "1e3", "None"],
        "json": ["\"", "{", "}", "[", "]", ":", ",", "\\", "\\u00e9", "true", "-1.5", " ", "\n", "🧋", "\"k\":"],
        "javascript": ["`", "${", "}", "/", "/re/g", "x", "return ", "//", "/*", "*/", "\"", "'", "\n", "(", ")", "[", "]", "🧋", "\\"],
        "typescript": ["interface ", "T", "<", ">", "`", "${", "}", "/", "x", "\n", "\"", "'", "as ", "{", "\\"],
        "go": ["`", "\"", "'", "\\", "func ", "(p *T) ", "f", "/*", "*/", "//", "\n", "x"],
        "yaml": ["key: ", "- ", "|", ">-", "\n", "  ", "    ", "\"", "'", "#", "true", "1.5", "&a", "[", "]"],
        "markdown": ["```", "````", "~~~", "swift", "json", "yaml", "\n", " ", "**", "*", "_", "`", "# ", "> ", "- ", "/*", "\"", "x", "<div>", "<!--", "-->", "\n\n", "[a]: u", "][b]", "==="],
        "shell": ["<<EOF", "<<'R'", "<<-T", "EOF", "R", "\tT", "\n", "$x", "${", "}", "$(", ")", "\"", "'", "#", "x", " ", "\\", "\\'"],
        "heredoc": ["<<EOF", "<<-'END'", "EOF", "END", "\t", "\n", "x", " ", "EOFX", "\r\n"],
        "fence": ["```", "````", "swift", "json", "\n", " ", "/*", "*/", "\"", "let", "x", "cobol"],
        "block": ["key:", " |", " >", "\n", "  ", "    ", "line", "\n\n", "a"]
    ]

    /// Bundled grammars, plus the inline v1 grammars that exercise remembered delimiters, embedding and indentation.
    static func grammar(_ name: String) throws -> Grammar {
        switch name {
        case "heredoc": return try FormatV1Tests.grammar(FormatV1Tests.heredoc)
        case "fence": return try FormatV1Tests.grammar(FormatV1Tests.markdown, initial: "text")
        case "block": return try FormatV1Tests.grammar(FormatV1Tests.blockScalar)
        default: return try Grammar.bundled(name)
        }
    }

    static func randomText(_ pieces: [String], count: Int, using rng: inout SeededGenerator) -> String {
        (0..<count).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    @Test(arguments: ["swift", "python", "json", "javascript", "typescript", "go", "yaml", "markdown", "shell", "heredoc", "fence", "block"])
    func incrementalMatchesFullRehighlight(_ language: String) throws {
        let grammar = try Self.grammar(language)
        let pieces = Self.fragments[language]!
        for seed in UInt64(1)...40 {
            var rng = SeededGenerator(state: seed)
            let highlighter = Highlighter(grammar: grammar, text: Self.randomText(pieces, count: 60, using: &rng))
            for step in 0..<40 {
                let units = highlighter.units.count
                let location = Int.random(in: 0...units, using: &rng)
                let length = Int.random(in: 0...min(8, units - location), using: &rng)
                let insert = Bool.random(using: &rng) ? Self.randomText(pieces, count: Int.random(in: 0...3, using: &rng), using: &rng) : ""
                // Never cut a surrogate pair or a CRLF in half: editors don't, and the full scan can't either.
                let text = highlighter.text as NSString
                let safe = text.rangeOfComposedCharacterSequences(for: NSRange(location: min(location, units), length: length))
                let changed = highlighter.replaceCharacters(in: safe, with: insert)
                let full = Highlighter(grammar: grammar, text: highlighter.text)
                #expect(highlighter.tokens == full.tokens, "\(language) seed \(seed) step \(step): edit \(safe) ← \(insert.debugDescription)")
                #expect(changed.location >= 0 && NSMaxRange(changed) <= highlighter.units.count)
                if highlighter.tokens != full.tokens { return }
            }
        }
    }

    @Test func editInsideAFunctionRescansOnlyNearbyLines() throws {
        let grammar = try Grammar.bundled("swift")
        let body = (0..<2_000).map { "let value\($0) = \"text \\($0)\" // note" }.joined(separator: "\n")
        let highlighter = Highlighter(grammar: grammar, text: body)
        let location = (body as NSString).range(of: "value1000").location
        let changed = highlighter.replaceCharacters(in: NSRange(location: location, length: 0), with: "new")
        #expect(changed.length < 200, "a one-word edit re-scanned \(changed.length) units")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: highlighter.text).tokens)
    }

    @Test func openingACommentRescansToTheEndAndClosingItRecovers() throws {
        let grammar = try Grammar.bundled("swift")
        let text = (0..<50).map { "let a\($0) = 1" }.joined(separator: "\n")
        let highlighter = Highlighter(grammar: grammar, text: text)
        let changed = highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
        #expect(NSMaxRange(changed) == highlighter.units.count, "an unclosed comment changes every later line")
        #expect(highlighter.tokens.allSatisfy { $0.scope == "comment.block" })
        highlighter.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: text).tokens)
    }

    @Test func joiningAndSplittingCRLF() throws {
        let grammar = try Grammar.bundled("swift")
        let highlighter = Highlighter(grammar: grammar, text: "let a\rlet b")
        highlighter.replaceCharacters(in: NSRange(location: 6, length: 0), with: "\n")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: "let a\r\nlet b").tokens)
        highlighter.replaceCharacters(in: NSRange(location: 5, length: 1), with: "")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: "let a\nlet b").tokens)
    }

    @Test func editsAtTheEdges() throws {
        let grammar = try Grammar.bundled("json")
        let highlighter = Highlighter(grammar: grammar, text: "")
        highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "{\"a\": 1}\n")
        highlighter.replaceCharacters(in: NSRange(location: highlighter.units.count, length: 0), with: "[true]")
        #expect(highlighter.text == "{\"a\": 1}\n[true]")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: highlighter.text).tokens)
        highlighter.replaceCharacters(in: NSRange(location: 0, length: highlighter.units.count), with: "")
        #expect(highlighter.tokens.isEmpty)
    }

    /// A continuation backslash keeps a single-line string open, so deleting or adding one re-colours the next line.
    @Test(arguments: ["python", "javascript"])
    func continuationEditsRecolourTheNextLine(_ language: String) throws {
        let grammar = try Grammar.bundled(language)
        let text = "a = 'one \\\ntwo' + 1\n"
        func scope(_ highlighter: Highlighter) -> String? {
            let two = (highlighter.text as NSString).range(of: "two")
            return highlighter.tokens.first { NSIntersectionRange($0.range, two).length > 0 }?.scope
        }
        let highlighter = Highlighter(grammar: grammar, text: text)
        #expect(scope(highlighter) == "string.quoted")

        highlighter.replaceCharacters(in: (text as NSString).range(of: "\\"), with: "")
        #expect(scope(highlighter) != "string.quoted")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: highlighter.text).tokens)

        highlighter.replaceCharacters(in: NSRange(location: (highlighter.text as NSString).range(of: "\n").location, length: 0), with: "\\")
        #expect(scope(highlighter) == "string.quoted")
        #expect(highlighter.tokens == Highlighter(grammar: grammar, text: highlighter.text).tokens)
    }
}
