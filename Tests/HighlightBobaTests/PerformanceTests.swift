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
        ("json", "many short lines", { String(repeating: "[1,\n", count: $0 / 4) })
    ]

    static func steps(_ grammar: Grammar, _ text: String) -> Int {
        Highlighter(grammar: grammar, text: text).lastSteps
    }

    @Test(arguments: hostile.indices)
    func hostileInputStaysLinear(_ index: Int) throws {
        let (language, name, make) = Self.hostile[index]
        let grammar = try Grammar.bundled(language)
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
