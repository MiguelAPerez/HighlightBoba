import Foundation
import Testing
@testable import HighlightBoba

/// Linearity is asserted on the scanner's own work counter, not wall time, so these never flake
/// on a busy runner. The benchmark prints timings for humans and asserts nothing about them.
@Suite struct PerformanceTests {
    /// Inputs built to make a backtracking or rescanning matcher go quadratic.
    static let hostile: [(String, String, @Sendable (Int) -> String)] = [
        ("swift", "long identifier", { String(repeating: "a", count: $0) }),
        ("swift", "digits then a dot", { String(repeating: "1", count: $0) + "." }),
        ("swift", "open comments", { String(repeating: "/*", count: $0 / 2) }),
        ("swift", "interpolation openers", { String(repeating: "\"\\(", count: $0 / 3) }),
        ("swift", "backslashes in a string", { "\"" + String(repeating: "\\", count: $0) }),
        ("swift", "one huge line comment", { "//" + String(repeating: "x", count: $0) }),
        ("python", "f-string braces", { "f\"" + String(repeating: "{", count: $0) }),
        ("python", "quote soup", { String(repeating: "'\"", count: $0 / 2) }),
        ("json", "number then letters", { String(repeating: "9", count: $0) + "x" }),
        ("json", "many short lines", { String(repeating: "[1,\n", count: $0 / 4) }),
        ("json", "key lookahead that never finds a colon", { "{\"a\": 1, " + String(repeating: "\"", count: $0) }),
        ("sql", "dollar quote openers", { String(repeating: "$a$ $", count: $0 / 5) }),
        ("sql", "nested comment openers", { String(repeating: "/*", count: $0 / 2) }),
        ("sql", "quote soup", { String(repeating: "'\"`", count: $0 / 3) }),
        ("sql", "function names without a paren", { String(repeating: "count ", count: $0 / 6) }),
        ("swift", "raw string hash runs", { String(repeating: "#", count: $0) + "\"" + String(repeating: "\"#", count: $0 / 4) }),
        ("swift", "func captures", { String(repeating: "func ", count: $0 / 5) }),
        ("rust", "raw string hash runs", { "r" + String(repeating: "#", count: 200) + "\"" + String(repeating: "\"" + String(repeating: "#", count: 199), count: $0 / 200) }),
        ("rust", "lifetime and char quotes", { String(repeating: "'a'b'", count: $0 / 5) }),
        ("rust", "open comments", { String(repeating: "/*", count: $0 / 2) }),
        ("rust", "attribute brackets", { "#[" + String(repeating: "[", count: $0) }),
        ("rust", "macro-like names", { String(repeating: "a!=", count: $0 / 3) }),
        ("heredoc", "heredoc openers", { String(repeating: "<<EOF\n", count: $0 / 6) }),
        ("heredoc", "long delimiter, near misses", { "<<" + String(repeating: "A", count: 200) + "\n" + String(repeating: String(repeating: "A", count: 199) + "\n", count: $0 / 200) }),
        ("fence", "fence spam", { String(repeating: "```swift\n", count: $0 / 9) }),
        ("javascript", "slashes after operators", { String(repeating: "= /", count: $0 / 3) }),
        ("javascript", "template openers", { String(repeating: "`${", count: $0 / 3) }),
        ("java", "text block quote runs", { "\"\"\"" + String(repeating: "\"\"x", count: $0 / 3) }),
        ("java", "annotation runs", { String(repeating: "@a.", count: $0 / 3) }),
        ("java", "unicode escape near misses", { "\"" + String(repeating: "\\uuu0", count: $0 / 6) }),
        ("kotlin", "template openers", { String(repeating: "\"${", count: $0 / 3) }),
        ("kotlin", "braces in a template", { "\"${" + String(repeating: "{", count: $0) }),
        ("kotlin", "open nested comments", { String(repeating: "/*", count: $0 / 2) }),
        ("kotlin", "label-like runs", { String(repeating: "return@", count: $0 / 7) }),
        ("go", "receiver lookahead without a close", { String(repeating: "func (", count: $0 / 6) }),
        ("diff", "hunk headers that never close", { String(repeating: "@@ -1,2 +1\n", count: $0 / 11) }),
        ("diff", "at-sign runs", { String(repeating: "@", count: $0) }),
        ("diff", "marker soup in a hunk", { "@@ -1 +1 @@\n" + String(repeating: "-\n+\n \n\\\n", count: $0 / 8) }),
        ("c", "directives at every line", { String(repeating: "#include <a\n", count: $0 / 12) }),
        ("c", "continued directive", { "#define A " + String(repeating: "\\\n", count: $0 / 2) }),
        ("c", "digit separators", { String(repeating: "1'", count: $0 / 2) }),
        ("cpp", "raw string delimiter near misses", { "R\"abcdefghijklmnop(" + String(repeating: ")abcdefghijklmno\"", count: $0 / 18) }),
        ("cpp", "raw string openers that never open", { String(repeating: "R\"abcdefghijklmnopq", count: $0 / 19) }),
        ("cpp", "attribute openers", { String(repeating: "[[", count: $0 / 2) }),
        ("cpp", "class attribute lookahead", { String(repeating: "class [[a ", count: $0 / 10) }),
        ("yaml", "key-like runs without a colon", { String(repeating: "abc-def ", count: $0 / 8) }),
        ("yaml", "block scalars at every line", { String(repeating: "a: |\n", count: $0 / 5) }),
        ("toml", "quote soup", { "a = " + String(repeating: "\"'", count: $0 / 2) }),
        ("toml", "array openers", { "a = " + String(repeating: "[", count: $0) }),
        ("toml", "multi-line quote runs", { "a = \"\"\"" + String(repeating: "\"\"x", count: $0 / 3) }),
        ("toml", "header openers", { String(repeating: "[[a.", count: $0 / 4) }),
        ("markdown", "unclosed emphasis and backticks", { String(repeating: "**_`", count: $0 / 4) }),
        ("markdown", "real fence spam", { String(repeating: "```swift\n", count: $0 / 9) }),
        ("shell", "heredoc openers on one line", { String(repeating: "<<A ", count: $0 / 4) }),
        ("shell", "nested substitutions", { String(repeating: "$(", count: $0 / 2) }),
        ("dockerfile", "heredoc openers on one line", { "RUN " + String(repeating: "<<A ", count: $0 / 4) }),
        ("dockerfile", "continued flags", { "RUN " + String(repeating: "--a=b \\\n", count: $0 / 8) }),
        ("dockerfile", "instruction spam", { String(repeating: "RUN \"$(\n", count: $0 / 8) }),
        ("css", "declaration lookahead that never finds a brace", { "a{" + String(repeating: "b:c ", count: $0 / 4) }),
        ("css", "open functions", { "a{b:" + String(repeating: "f(", count: $0 / 2) }),
        ("css", "escapes in a selector", { String(repeating: ".a\\:", count: $0 / 4) }),
        ("css", "nested blocks", { String(repeating: "a{", count: $0 / 2) }),
        ("html", "open tags", { String(repeating: "<a ", count: $0 / 3) }),
        ("html", "attribute soup", { "<a " + String(repeating: "b=c d='e' ", count: $0 / 10) }),
        ("html", "script and style openers", { String(repeating: "<script><style>", count: $0 / 15) }),
        ("html", "style attributes", { String(repeating: "<p style=\"a:b\" onclick='f()'>", count: $0 / 30) }),
        ("html", "entity-like runs", { String(repeating: "&a&#x", count: $0 / 5) }),
        ("xml", "open tags", { String(repeating: "<a ", count: $0 / 3) }),
        ("xml", "attribute soup", { "<a " + String(repeating: "b='c' d=\"&e;\" ", count: $0 / 14) }),
        ("xml", "comment dashes", { "<!--" + String(repeating: "-", count: $0) }),
        ("xml", "doctype subset openers", { "<!DOCTYPE a [" + String(repeating: "<!%a;", count: $0 / 5) }),
        ("php", "open and close tags", { String(repeating: "<?php ?>", count: $0 / 8) }),
        ("php", "heredoc openers on one line", { "<?php " + String(repeating: "<<<A ", count: $0 / 5) }),
        ("php", "interpolation openers", { "<?php \"" + String(repeating: "{$a", count: $0 / 3) }),
        ("php", "tags inside HTML attributes", { String(repeating: "<a b=\"<?= $c ?>\">", count: $0 / 18) }),
        ("block", "deep indentation", { String(repeating: "a: |\n" + String(repeating: " ", count: 40) + "x\n", count: $0 / 48) })
    ]

    static func steps(_ grammar: Grammar, _ text: String) -> Int {
        Highlighter(grammar: grammar, text: text).lastSteps
    }

    @Test(arguments: hostile.indices)
    func hostileInputStaysLinear(_ index: Int) throws {
        let (language, name, make) = Self.hostile[index]
        let grammar = try IncrementalTests.grammar(language)
        let small = Self.steps(grammar, make(20_000))
        let large = Self.steps(grammar, make(80_000))
        let ratio = Double(large) / Double(max(small, 1))
        // 4× the input must cost about 4× the work; quadratic would be ~16×.
        #expect(ratio < 5, "\(language) \(name): 4× input cost \(String(format: "%.1f", ratio))× the work")
        #expect(large < 80_000 * 64, "\(language) \(name): \(large) steps for 80k units")
    }

    @Test func largeFileBenchmark() throws {
        let grammar = try Grammar.bundled("swift")
        let unit = """
        /// Doc comment for item.
        @MainActor func render(_ item: Item, count: Int = 42) async throws -> String {
            let label = "Item \\(item.name) has \\(count) parts" // trailing
            /* block /* nested */ comment */ return label + "\\u{1F9CB}"
        }

        """
        let text = String(repeating: unit, count: 4_000)
        let clock = ContinuousClock()
        var highlighter: Highlighter?
        let full = clock.measure { highlighter = Highlighter(grammar: grammar, text: text) }
        let middle = text.utf16.count / 2
        let edit = clock.measure { highlighter!.replaceCharacters(in: NSRange(location: middle, length: 0), with: "x") }
        print("benchmark: \(text.utf16.count / 1024) KB Swift, full highlight \(full), one-character edit \(edit)")
        #expect(highlighter!.tokens.count > 50_000)
    }
}
