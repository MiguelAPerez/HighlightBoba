import Foundation
import Testing
@testable import HighlightBoba

/// Every parser's deepest inputs, on half the stack an iOS secondary thread gets, all at once.
///
/// A background parse may run on a 512 KB stack, and a debug build's frames are several times a
/// release build's. Each parser stops nesting at its depth limit or when `StackGuard` finds the
/// stack low, whichever comes first, so these finish on 256 KB: half the budget is to spare.
@Suite struct StackTests {
    /// Openers repeated 2,000 times: past every parser's depth limit.
    static let deepInputs: [(String, [String])] = [
        ("swift", ["(", "[", "{", "f(", "a = ", "a ? b : ", "- ", "try ", "let x: [", "A<", "{ x in ", "\"\\(",
                   "case .a(let ", "f { a, b ", "V(x: [y.map { if a { W { "]),
        ("javascript", ["(", "({", "[", "{", "`${", "x = { a: [", "f(", "a ? b : ", "!", "if (x) ", "() => ", "[..."]),
        ("typescript", ["(", "<", "T<", "f<", "type A = (", "A<", "x = {a:", "a < b < c, "]),
        ("jsx", ["<a>", "<a b={", "<a>{", "<>", "<", "x = (<a>"]),
        ("tsx", ["<a>", "<a b={", "<a>{", "<a><b c={() => <d>", "<T,>() => <a>"]),
        ("python", ["(", "-", "not ", "lambda: ", "[{", "x if y else ", "yield ", "a + ", "case [", "f("]),
        ("shell", ["$(", "{ ", "( ", "if a; then ", "\"$(echo ", "case a in a) ", "while a; do ", "f() { ", "$((", "<(",
                   "${a:-$(", "x=(", "a | ", "a && ", "`", "cat <<E\n"])
    ]
    /// Lexer-only languages that embed others: the lexer's own stack is an array, not the thread's.
    static let embeddedInputs: [(String, [String])] = [
        ("html", ["<div>", "<script>(", "<style>a{", "<a href=\"", "<!--"]),
        ("php", ["<?php (", "<?php {", "<div><?php if (a) { ?>", "<?php $a = [", "<?php f("])
    ]
    static let stackSize = 256 * 1024

    /// Parses (or, for a lexer-only language, highlights) each input on its own small-stack thread.
    static func survives(_ language: String, _ text: String) async throws -> Bool {
        let grammar = try Grammar.bundled(language)
        let parser = LanguageSupport.bundledParsers[language]
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let highlighter = Highlighter(grammar: grammar, text: text)
                guard let parser else { return continuation.resume(returning: highlighter.text == text) }
                continuation.resume(returning: leafText(parser.parse(highlighter.snapshot).tree.root) == text)
            }
            thread.stackSize = stackSize
            thread.start()
        }
    }

    @Test func deepNestingLeavesHalfOfA512KBStack() async throws {
        let cases = (Self.deepInputs + Self.embeddedInputs).flatMap { language, openers in
            openers.map { (language, String(repeating: $0, count: 2_000)) }
        }
        // All at once, so each parse runs while the others load the machine.
        try await withThrowingTaskGroup(of: (String, String, Bool).self) { group in
            for (language, text) in cases {
                group.addTask { (language, text, try await Self.survives(language, text)) }
            }
            for try await (language, text, survived) in group {
                #expect(survived, "\(language) \(String(text.prefix(12)).debugDescription)…")
            }
        }
    }
}
