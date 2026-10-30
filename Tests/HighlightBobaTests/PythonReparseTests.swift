import Foundation
import Testing
@testable import HighlightBoba

@Suite struct PythonReparseTests {
    static var fixtures: [Fixture] { Fixture.all().filter { $0.language == "python" } }

    static let pieces = [":", "\n", "    ", " ", "(", ")", "[", "]", "{", "}", "\"", "'", "\"\"\"", "\\", "x", "def ", "if ",
                         "match ", "case ", "type ", "#", ",", "=", "f\"{", "\t", "_", "@", "else:", "\n    pass\n", "🧋", "\r\n"]

    /// Indents or dedents the line holding `location` by up to a tab stop.
    static func indentEdit(_ highlighter: Highlighter, near location: Int, using rng: inout SeededGenerator) {
        let text = highlighter.text as NSString
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var spaces = 0
        while line.location + spaces < text.length, text.character(at: line.location + spaces) == 32 { spaces += 1 }
        if spaces > 0 && Bool.random(using: &rng) {
            highlighter.replaceCharacters(in: NSRange(location: line.location, length: Int.random(in: 1...min(4, spaces), using: &rng)), with: "")
        } else {
            highlighter.replaceCharacters(in: NSRange(location: line.location, length: 0),
                                          with: String(repeating: " ", count: Int.random(in: 1...4, using: &rng)))
        }
    }

    /// Random edits over every Python fixture, a third of them to indentation, some coalesced, with
    /// the highlighter taking the tree's re-lexing or not: the incremental tree is always the whole parse's.
    @Test(arguments: fixtures)
    func incrementalEqualsFullOnRandomEdits(_ fixture: Fixture) throws {
        let parser = PythonParser()
        let text = try fixture.input()
        for seed in UInt64(1)...4 {
        var rng = SeededGenerator(state: UInt64(text.utf16.count) &* 31 &+ seed)
        var (highlighter, tree) = ReparseTests.setUp(text, Python.grammar, parser)
        for step in 0..<40 {
            for _ in 0..<Int.random(in: 1...2, using: &rng) {
                let units = highlighter.text.utf16.count
                let location = Int.random(in: 0...units, using: &rng)
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    Self.indentEdit(highlighter, near: location, using: &rng)
                    continue
                }
                let length = Int.random(in: 0...min(3, units - location), using: &rng)
                let insert = Bool.random(using: &rng) ? Self.pieces.randomElement(using: &rng)! : ""
                let safe = (highlighter.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
                highlighter.replaceCharacters(in: safe, with: insert)
            }
            let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision) ?? TextEdit(range: NSRange(), replacementLength: 0),
                                        in: highlighter.snapshot)
            let full = parser.parse(highlighter.snapshot)
            guard sameParse(result.tree, full.tree) else {
                Issue.record("\(fixture.testDescription) step \(step): \(firstDifference(result.tree, full.tree)) in \(highlighter.text.debugDescription)")
                return
            }
            #expect(leafText(result.tree.root) == highlighter.text)
            tree = result.tree
            if Bool.random(using: &rng) { _ = highlighter.applyRelexing(of: tree) }
        }
        }
    }

    /// Typing in a name inside a function body, the common edit, reparses only a block.
    @Test func typingInABodyStaysInABlock() throws {
        let parser = PythonParser()
        let text = try Fixture.all().first { $0.language == "python" && $0.name == "parsed-tour" }!.input()
        var rng = SeededGenerator(state: 42)
        var (highlighter, tree) = ReparseTests.setUp(text, Python.grammar, parser)
        var incremental = 0
        var edits = 0
        for _ in 0..<300 {
            // Inside a name (not a keyword or builtin) on an indented line.
            let words = highlighter.syntaxTokens.filter { $0.kind == .word && $0.length >= 3 }
            let word = words.randomElement(using: &rng)!
            let units = Array(highlighter.text.utf16)
            var lineStart = word.location
            while lineStart > 0 && units[lineStart - 1] != 10 { lineStart -= 1 }
            guard units[lineStart] == 32 else { continue }
            let location = word.location + Int.random(in: 1..<(word.length - 1), using: &rng)
            let deleting = Bool.random(using: &rng)
            let result = ReparseTests.edit(highlighter, &tree, parser, NSRange(location: location, length: deleting ? 1 : 0),
                                           deleting ? "" : "q")
            edits += 1
            if result.isIncremental { incremental += 1 }
        }
        #expect(edits > 30)
        #expect(incremental * 10 > edits * 9, "only \(incremental) of \(edits) edits stayed in a block")
    }
}

/// Parser work is counted in lookahead steps, not wall time, so these never flake on a busy runner.
@Suite struct PythonPerformanceTests {
    static func steps(_ text: String) -> Int {
        let builder = TreeBuilder(highlighter: Highlighter(grammar: Python.grammar, text: text))
        PythonParser().parse(builder)
        _ = builder.finish()
        return builder.lookaheadSteps
    }

    /// Inputs built to make the parser's lookahead (match statements, `with (`, re-lexing) go quadratic.
    static let hostile: [(String, @Sendable (Int) -> String)] = [
        ("the tour, repeated", { n in String(repeating: tour + "\n", count: max(1, n / tour.utf16.count)) }),
        ("match lines that aren't statements", { String(repeating: "match (a, b, c, d, e, f, g, h)\n", count: $0 / 32) }),
        ("one long match line", { "match " + String(repeating: "a + ", count: $0 / 4) + "b:\n    case 1: pass\n" }),
        ("with ( never closed", { String(repeating: "with (a, ", count: $0 / 9) }),
        ("attributes the lexer scoped", { "x = " + String(repeating: "a.format.self.", count: $0 / 14) + "b\n" }),
        ("matrix products the lexer read as decorators", { "x = " + String(repeating: "a @b ", count: $0 / 5) + "\n" }),
        ("unclosed calls", { String(repeating: "f(x,\n", count: $0 / 5) }),
        ("deep blocks", { (0..<($0 / 400)).map { String(repeating: " ", count: $0 % 40 * 4) + "if x:\n" }.joined() + "pass\n" })
    ]

    static let tour = (try? Fixture.all().first { $0.language == "python" && $0.name == "parsed-tour" }!.input()) ?? ""

    @Test(arguments: hostile.indices)
    func parsingStaysLinear(_ index: Int) {
        let (name, make) = Self.hostile[index]
        let small = Self.steps(make(10_000))
        let large = Self.steps(make(40_000))
        let ratio = Double(large) / Double(max(small, 1))
        // 4× the input must cost about 4× the work; quadratic would be ~16×.
        #expect(ratio < 5, "\(name): 4× input cost \(String(format: "%.1f", ratio))× the work")
        #expect(large < 40_000 * 40, "\(name): \(large) steps for 40k units")
    }

    @Test func largeFileBenchmark() {
        let text = String(repeating: Self.tour + "\n", count: 200)
        let highlighter = Highlighter(grammar: Python.grammar, text: text)
        let clock = ContinuousClock()
        var tree: SyntaxTree?
        let full = clock.measure { tree = PythonParser().parse(highlighter.snapshot).tree }
        #expect(tree?.errors.isEmpty == true)
        let at = (text as NSString).range(of: "data if").location + text.utf16.count / 2
        highlighter.replaceCharacters(in: NSRange(location: (text as NSString).range(of: "data if", range: NSRange(location: at, length: text.utf16.count - at)).location, length: 0), with: "x")
        var reparse: Reparse?
        let edit = clock.measure { reparse = PythonParser().reparse(tree!, after: highlighter.edit(since: tree!.revision)!, in: highlighter.snapshot) }
        #expect(reparse?.isIncremental == true)
        print("benchmark: \(text.utf16.count / 1024) KB Python, full parse \(full), one-character reparse \(edit)")
    }
}
