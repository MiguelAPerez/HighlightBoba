import Foundation
import Testing
@testable import HighlightBoba

/// The JavaScript/TypeScript parser over the JS and TS fixtures: what the parser fixes, the
/// errors it finds, and that a block reparse is always the whole parse.
///
/// Serialized: its many CPU-heavy cases would otherwise hold every concurrency thread on a small CI
/// runner, while `ParseSessionTests` parks threads at its gates and needs one free to open them.
@Suite(.serialized) struct JSParserTests {
    static let fixtures = Fixture.all().filter { $0.language == "javascript" || $0.language == "typescript" }

    static func parser(_ language: String) -> JSParser {
        JSParser(dialect: language == "typescript" ? .typescript : .javascript)
    }

    /// Parses `text`, applies the tree's re-lexing and runs the bundled queries.
    static func highlight(_ text: String, _ language: String) throws -> (tokens: [HighlightToken], tree: SyntaxTree) {
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        let tree = parser(language).parse(highlighter.snapshot).tree
        _ = highlighter.applyRelexing(of: tree)
        let queries = try #require(LanguageSupport.bundled(for: language)?.queries)
        let tokens = try #require(highlighter.tokens(refinedBy: queries.run(on: tree)))
        return (tokens, tree)
    }

    static func errors(_ tree: SyntaxTree) -> String {
        tree.errors.map { "\($0.message) at \(String(decoding: tree.units[$0.range.location..<NSMaxRange($0.range)], as: UTF16.self).debugDescription) (\($0.range.location))" }
            .joined(separator: "; ")
    }

    /// The fixture tests draw every fixture through its parser (`LanguageSupport.highlight`). Fixtures
    /// named `parser-…` exist to show what the parser fixes, so the lexer alone must draw them differently.
    @Test(arguments: fixtures.filter { $0.name.hasPrefix("parser-") })
    func parserFixturesNeedTheParser(_ fixture: Fixture) throws {
        let input = try fixture.input()
        let (tokens, tree) = try Self.highlight(input, fixture.language)
        #expect(leafText(tree.root) == input)
        let lexerOnly = Highlighter.highlight(input, grammar: try Grammar.bundled(fixture.language))
        #expect(CaretRenderer.render(input, tokens: tokens) != CaretRenderer.render(input, tokens: lexerOnly),
                "\(fixture.testDescription) highlights the same without the parser")
    }

    /// The fixtures are valid code, apart from the ones about broken code.
    @Test(arguments: fixtures)
    func validFixturesParseWithoutErrors(_ fixture: Fixture) throws {
        guard !["recovery", "unterminated"].contains(where: fixture.name.contains) else { return }
        let (_, tree) = try Self.highlight(try fixture.input(), fixture.language)
        #expect(tree.errors.isEmpty, "\(fixture.testDescription): \(Self.errors(tree))")
    }

    // MARK: Incremental reparsing

    static let editPieces = ["{", "}", "(", ")", "[", "]", "/", "`", "${", "\"", "'", "<", ">", "=>", "x", " ", "\n",
                             ";", ",", ":", "?", "a / ", "/re/", "//", "/*", "*/", "function f() {", "class ", "if (x) ",
                             "type ", "🧋", "of ", "async ", "<T>", "get ", "=", ".", "!", "\\"]

    /// Random edits over every JS and TS fixture, the highlighter sometimes taking the tree's
    /// re-lexing: the block reparse is always exactly the whole parse.
    @Test(arguments: fixtures)
    func incrementalEqualsFullOnRandomEdits(_ fixture: Fixture) throws {
        let grammar = try Grammar.bundled(fixture.language)
        let parser = Self.parser(fixture.language)
        let text = try fixture.input()
        for seed in UInt64(1)...4 {
            var rng = SeededGenerator(state: UInt64(text.utf16.count) &* seed)
            let highlighter = Highlighter(grammar: grammar, text: text)
            var tree = parser.parse(highlighter.snapshot).tree
            for step in 0..<50 {
                for _ in 0..<Int.random(in: 1...2, using: &rng) {
                    let units = highlighter.units.count
                    let location = Int.random(in: 0...units, using: &rng)
                    let length = Int.random(in: 0...min(4, units - location), using: &rng)
                    let insert = Bool.random(using: &rng) ? Self.editPieces.randomElement(using: &rng)! : ""
                    let safe = (highlighter.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
                    highlighter.replaceCharacters(in: safe, with: insert)
                }
                let edit = highlighter.edit(since: tree.revision) ?? TextEdit(range: NSRange(), replacementLength: 0)
                let result = parser.reparse(tree, after: edit, in: highlighter.snapshot)
                let full = parser.parse(highlighter.snapshot)
                guard sameParse(result.tree, full.tree) else {
                    Issue.record("\(fixture.testDescription) seed \(seed) step \(step): \(firstDifference(result.tree, full.tree)) in \(highlighter.text.debugDescription)")
                    return
                }
                #expect(leafText(result.tree.root) == highlighter.text)
                tree = result.tree
                if Bool.random(using: &rng) { _ = highlighter.applyRelexing(of: tree) }
            }
        }
    }

    /// A file of 120 functions and classes: typing inside one body reparses that body, not the file.
    @Test(arguments: ["javascript", "typescript"])
    func editsInsideBodiesStayInTheirBlock(_ language: String) throws {
        let unit = language == "typescript" ? Self.typeScriptUnit : Self.javaScriptUnit
        let text = (0..<120).map { unit.replacingOccurrences(of: "NAME", with: "f\($0)") }.joined()
        let parser = Self.parser(language)
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        var tree = parser.parse(highlighter.snapshot).tree
        #expect(tree.errors.isEmpty, "\(Self.errors(tree))")
        var rng = SeededGenerator(state: 7)
        var incremental = 0
        let edits = 40
        for _ in 0..<edits {
            let at = (highlighter.text as NSString).range(of: "total", options: [], range: NSRange(location: Int.random(in: 0..<(highlighter.units.count - 400), using: &rng), length: 400)).location
            guard at != NSNotFound else { continue }
            highlighter.replaceCharacters(in: NSRange(location: at, length: 0), with: ["x + ", "/re/.test(s) && ", "(a) / 2 + ", "`${v}` + "].randomElement(using: &rng)!)
            let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision)!, in: highlighter.snapshot)
            let full = parser.parse(highlighter.snapshot)
            #expect(sameParse(result.tree, full.tree))
            if result.isIncremental {
                incremental += 1
                #expect(result.steps * 50 < full.steps, "a block reparse should cost the block")
            }
            tree = result.tree
        }
        #expect(incremental * 4 >= edits * 3, "only \(incremental) of \(edits) edits reparsed just a block")
    }

    static let javaScriptUnit = """
    function NAME(items, { limit = 10 } = {}) {
      let total = 0;
      for (const item of items) { if (item.ok) total += item.value / limit; }
      return { total, label: `sum ${total}` };
    }
    class NAMEBox extends Base { get size() { const total = 1; return total; } }

    """

    static let typeScriptUnit = """
    function NAME<T extends object>(items: T[], opts?: { limit: number }): Map<string, T> {
      let total: number = 0;
      for (const item of items as Array<T>) { if (item) total += 1 / (opts?.limit ?? 1); }
      return new Map<string, T>();
    }
    interface NAMEShape { readonly id: string; area(): number }
    class NAMEBox<T> implements Store<T> { private total = 0; get size(): number { const total = 1; return total; } }

    """

    // MARK: Cost

    /// The parser's lookahead per token stays flat as a file grows, on real code and on input
    /// built to make lookahead scans or recursion go quadratic.
    @Test(arguments: Self.linearInputs.indices)
    func parseStaysLinear(_ index: Int) throws {
        let (language, name, make) = Self.linearInputs[index]
        let grammar = try Grammar.bundled(language)
        func steps(_ size: Int) -> Int {
            let highlighter = Highlighter(grammar: grammar, text: make(size))
            let builder = TreeBuilder(highlighter: highlighter)
            Self.parser(language).parse(builder)
            #expect(leafText(builder.finish().root) == highlighter.text)
            return builder.lookaheadSteps
        }
        let small = steps(10_000)
        let large = steps(40_000)
        let ratio = Double(large) / Double(max(small, 1))
        #expect(ratio < 5, "\(language) \(name): 4× input cost \(String(format: "%.1f", ratio))× the lookahead")
        #expect(large < 40_000 * 400, "\(language) \(name): \(large) lookahead steps for 40k units")
    }

    static let linearInputs: [(String, String, @Sendable (Int) -> String)] = [
        ("javascript", "real code", { String(repeating: javaScriptUnit, count: max(1, $0 / javaScriptUnit.utf16.count)) }),
        ("typescript", "real code", { String(repeating: typeScriptUnit, count: max(1, $0 / typeScriptUnit.utf16.count)) }),
        ("javascript", "open parens", { String(repeating: "(", count: $0) }),
        ("javascript", "parens and braces", { String(repeating: "({", count: $0 / 2) }),
        ("javascript", "arrow-like lists that never arrow", { String(repeating: "(a, b, c = (d, e)) + ", count: $0 / 21) }),
        ("javascript", "long parameter lists", { String(repeating: "f((" + String(repeating: "a, ", count: 120) + "b) => 1);\n", count: $0 / 370) }),
        ("javascript", "slashes", { String(repeating: "a / b /\n", count: $0 / 8) }),
        ("javascript", "template openers", { String(repeating: "`${", count: $0 / 3) }),
        ("javascript", "unclosed objects", { String(repeating: "x = { a: [", count: $0 / 10) }),
        ("typescript", "less-thans", { String(repeating: "a < b < c, ", count: $0 / 11) }),
        ("typescript", "open angles", { String(repeating: "f<", count: $0 / 2) }),
        ("typescript", "generic-looking comparisons", { String(repeating: "a < (b, c) > d;\n", count: $0 / 16) }),
        ("typescript", "nested generics", { "type T = " + String(repeating: "A<", count: $0 / 4) + String(repeating: ">", count: $0 / 4) }),
        ("typescript", "arrow return types", { String(repeating: "x ? (a) : (b) : c;\n", count: $0 / 19) })
    ]

    /// Deep nesting stops at the depth limit, so a parse on a background thread's 512 KB stack never overflows.
    @Test(arguments: ["(", "[", "{", "x = {a:", "!", "<", "f(", "a ? b : ", "`${", "if (x) ", "() => ", "[...", "T<", "type A = ("])
    func deepNestingFitsASmallStack(_ opener: String) async throws {
        let text = String(repeating: opener, count: 50_000 / opener.utf16.count)
        let snapshot = Highlighter(grammar: try Grammar.bundled("typescript"), text: text).snapshot
        // Awaited, not waited on: blocking a concurrency thread here can starve the other tests.
        let lossless = await withCheckedContinuation { continuation in
            let thread = Thread {
                let builder = TreeBuilder(snapshot: snapshot)
                JSParser(dialect: .typescript).parse(builder)
                continuation.resume(returning: leafText(builder.finish().root) == text)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(lossless)
    }

    // MARK: Registration

    @Test func bothLanguagesAreRegisteredWithTheirQueries() throws {
        for language in ["javascript", "typescript"] {
            let support = try #require(LanguageSupport.bundled(for: language))
            let parser = try #require(support.parser as? JSParser)
            #expect(parser.dialect == (language == "typescript" ? .typescript : .javascript))
            #expect(support.queries.language == language)
        }
    }

    /// The re-lexing a parse asks for reaches the highlighter, through a background parse session too.
    @MainActor @Test func aParseSessionAppliesTheParsersRelexing() async throws {
        let highlighter = Highlighter(grammar: try Grammar.bundled("javascript"), text: "const ratio = total\n  / count / 2;\n")
        #expect(highlighter.tokens.contains { $0.scope == "string.regexp" }, "the lexer alone reads `/ count /` as a regex")
        let session = ParseSession(highlighter: highlighter, parser: JSParser())
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(!highlighter.tokens.contains { $0.scope == "string.regexp" })
    }

    // MARK: Specific shapes

    /// The kind of the innermost node whose text is exactly `text`, for each place it occurs.
    static func kinds(of text: String, in tree: SyntaxTree) -> [String] {
        var found: [NSRange: String] = [:]
        var stack = [tree.root]
        while let node = stack.popLast() {
            if node.text == text { found[node.range] = node.kind.name }
            stack.append(contentsOf: node.childNodes)
        }
        return found.keys.sorted { $0.location < $1.location }.map { found[$0]! }
    }

    /// Both names of an export specifier are names the queries can colour, as an import's are.
    @Test func exportSpecifiersWrapBothNames() throws {
        let text = "export { path as paths, read, x as default };\nimport { readFile as rf, default as d } from \"fs\";\n"
        let (tokens, tree) = try Self.highlight(text, "javascript")
        #expect(tree.errors.isEmpty, "\(Self.errors(tree))")
        #expect(Self.kinds(of: "path", in: tree) == ["identifier"])
        #expect(Self.kinds(of: "paths", in: tree) == ["identifier"])
        #expect(Self.kinds(of: "read", in: tree) == ["identifier"])
        #expect(Self.kinds(of: "readFile", in: tree) == ["identifier"])
        #expect(Self.kinds(of: "rf", in: tree) == ["binding"])
        let defaults = tokens.filter { (text as NSString).substring(with: $0.range) == "default" }
        #expect(defaults.count == 2 && defaults.allSatisfy { $0.scope == "keyword" }, "`default` in a specifier stays a keyword")
    }

    /// `in` is an operator in a conditional's consequent even in a `for` head: the grammar gives
    /// that arm `[+In]`; only the test and the alternate inherit the head's `[~In]`.
    @Test func inIsAnOperatorInAConditionalsConsequentInsideAForHead() throws {
        let (_, tree) = try Self.highlight("for (ready ? start in end : skip;;) {}\nfor (x = a ? b : c in d) {}\n", "javascript")
        #expect(tree.errors.isEmpty, "\(Self.errors(tree))")
        #expect(Self.kinds(of: "start in end", in: tree) == ["binary_expression"])
        #expect(Self.kinds(of: "for (x = a ? b : c in d) {}", in: tree) == ["for_in_statement"])
    }
}
