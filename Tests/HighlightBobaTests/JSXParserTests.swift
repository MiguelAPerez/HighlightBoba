import Foundation
import Testing
@testable import HighlightBoba

/// JSX and TSX: the JS/TS parser's JSX dialects over the `jsx` and `tsx` fixtures, how they decide
/// a `<`, how they recover from broken elements, and that a block reparse is always the whole parse.
///
/// Serialized for the same reason as `JSParserTests`: its CPU-heavy cases would otherwise hold
/// every concurrency thread on a small CI runner.
@Suite(.serialized) struct JSXParserTests {
    static let fixtures = Fixture.all().filter { $0.language == "jsx" || $0.language == "tsx" }

    static func highlight(_ text: String, _ language: String) throws -> (tokens: [HighlightToken], tree: SyntaxTree) {
        try JSParserTests.highlight(text, language)
    }

    /// The scope drawn over the first occurrence of `text` at or after `from`.
    static func scope(of text: String, in source: String, tokens: [HighlightToken], after from: String = "") -> String? {
        let start = from.isEmpty ? 0 : (source as NSString).range(of: from).location
        let range = (source as NSString).range(of: text, range: NSRange(location: start, length: source.utf16.count - start))
        return tokens.first { NSIntersectionRange($0.range, range).length > 0 }?.scope
    }

    // MARK: Fixtures

    /// Without the parser the lexer never enters JSX, so every fixture draws differently.
    @Test(arguments: fixtures)
    func fixturesNeedTheParser(_ fixture: Fixture) throws {
        let input = try fixture.input()
        let (tokens, tree) = try Self.highlight(input, fixture.language)
        #expect(leafText(tree.root) == input)
        let lexerOnly = Highlighter.highlight(input, grammar: try Grammar.bundled(fixture.language))
        #expect(CaretRenderer.render(input, tokens: tokens) != CaretRenderer.render(input, tokens: lexerOnly))
    }

    @Test(arguments: fixtures)
    func validFixturesParseWithoutErrors(_ fixture: Fixture) throws {
        let (_, tree) = try Self.highlight(try fixture.input(), fixture.language)
        if fixture.name == "recovery" {
            #expect(!tree.errors.isEmpty)
        } else {
            #expect(tree.errors.isEmpty, "\(fixture.testDescription): \(JSParserTests.errors(tree))")
        }
    }

    /// `jsx.json` and `tsx.json` are their base language plus the same JSX states, and their
    /// queries the same JSX queries before the base language's. `scripts/sync-jsx.py` rebuilds them.
    @Test func grammarsAndQueriesMatchTheirBase() throws {
        let sources = Fixture.packageRoot.appendingPathComponent("Sources/HighlightBoba")
        func load(_ folder: String, _ name: String) throws -> NSDictionary {
            let data = try Data(contentsOf: sources.appendingPathComponent("\(folder)/\(name).json"))
            return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        let jsxStates = try #require(try load("Grammars", "jsx")["states"] as? [String: Any]).filter { $0.key.hasPrefix("jsx") }
        let jsxQueries = try #require(try load("Queries", "jsx")["queries"] as? [NSDictionary]).filter { query in
            ["in", "inside", "notInside"].contains { key in "\(query[key] ?? "")".contains("jsx_") }
        }
        #expect(!jsxStates.isEmpty && !jsxQueries.isEmpty)
        for (name, base) in [("jsx", "javascript"), ("tsx", "typescript")] {
            let grammar = try load("Grammars", name)
            var states = try #require(try load("Grammars", base)["states"] as? [String: Any])
            #expect(!states.keys.contains { $0.hasPrefix("jsx") }, "\(base) has JSX states")
            states.merge(jsxStates) { _, jsx in jsx }
            // `code` tries the JSX guesses first.
            let code = try #require(states["code"] as? [String: Any])
            states["code"] = code.merging(["rules": [["include": "jsxGuess"]] + (code["rules"] as? [Any] ?? [])]) { _, new in new }
            #expect(grammar["states"] as? NSDictionary == states as NSDictionary,
                    "\(name).json is out of sync with \(base).json: run `python3 scripts/sync-jsx.py`")
            let queries = try #require(try load("Queries", base)["queries"] as? [NSDictionary])
            #expect(try load("Queries", name)["queries"] as? [NSDictionary] == jsxQueries + queries,
                    "Queries/\(name).json is out of sync with \(base).json: run `python3 scripts/sync-jsx.py`")
        }
    }

    // MARK: Deciding `<`

    @Test func tsxTellsGenericArrowsFromElements() throws {
        let text = """
        const a = <T,>(x: T) => x;
        const b = <T extends object>(x: T) => x;
        const c = async <const T,>(x: T) => x;
        const d = <T>(x)</T>;
        const e = <T extends="attribute" />;
        const f = a < b;
        const g = f<string>(1);

        """
        let (_, tree) = try Self.highlight(text, "tsx")
        #expect(tree.errors.isEmpty, "\(JSParserTests.errors(tree))")
        #expect(JSParserTests.kinds(of: "<T,>(x: T) => x", in: tree) == ["arrow_function"])
        #expect(JSParserTests.kinds(of: "<T extends object>(x: T) => x", in: tree) == ["arrow_function"])
        #expect(JSParserTests.kinds(of: "async <const T,>(x: T) => x", in: tree) == ["arrow_function"])
        #expect(JSParserTests.kinds(of: "<T>(x)</T>", in: tree) == ["jsx_element"])
        #expect(JSParserTests.kinds(of: "<T extends=\"attribute\" />", in: tree) == ["jsx_self_closing_tag"])
        #expect(JSParserTests.kinds(of: "a < b", in: tree) == ["binary_expression"])
        #expect(JSParserTests.kinds(of: "f<string>(1)", in: tree) == ["call_expression"])
    }

    /// The JSX dialects change nothing in `.js` and `.ts`: there, `<T>x` is a type assertion and
    /// `<div/>` isn't an element.
    @Test func plainJavaScriptAndTypeScriptHaveNoJSX() throws {
        let (_, ts) = try Self.highlight("const a = <T>x;\n", "typescript")
        #expect(ts.errors.isEmpty)
        #expect(JSParserTests.kinds(of: "<T>x", in: ts) == ["type_assertion"])
        for language in ["javascript", "typescript"] {
            let (_, tree) = try Self.highlight("const b = <div />;\n", language)
            #expect(!tree.errors.isEmpty)
            #expect(JSParserTests.kinds(of: "div", in: tree) != ["jsx_tag_name"])
        }
        let (_, jsx) = try Self.highlight("const a = <T>x</T>;\n", "jsx")
        #expect(jsx.errors.isEmpty)
        #expect(JSParserTests.kinds(of: "<T>x</T>", in: jsx) == ["jsx_element"])
    }

    // MARK: Recovery

    /// A broken element costs that element: the code after it lexes and colours as code again.
    @Test(arguments: [
        "<div className=\"a", "<div>\n    <span>", "(\n    <ul>\n      <li\n    </ul>\n  )", "<p>text (", "<", "<a b=",
        "<a b={1}", "<a {...p}", "<a>x</b>", "<a></b", "<A.", "<>", "<a>\n<b>\n<c>\n", "<x:", "<a-",
        "<a b='c\n d={1}'>", "<ul>{items.map(i => <li>{i})}</ul>", "<Foo<T"
    ])
    func brokenElementsLeaveTheCodeAfterThem(_ broken: String) throws {
        for language in ["jsx", "tsx"] {
            let text = "function f() {\n  return \(broken)\n}\nfunction after(n) { return n }\n"
            let (tokens, tree) = try Self.highlight(text, language)
            #expect(leafText(tree.root) == text)
            #expect(!tree.errors.isEmpty, "\(language) \(broken.debugDescription) parses without errors")
            #expect(Self.scope(of: "after", in: text, tokens: tokens) == "entity.name.function",
                    "\(language) \(broken.debugDescription): \(JSParserTests.errors(tree))")
            #expect(Self.scope(of: "return", in: text, tokens: tokens, after: "after") == "keyword")
            #expect(JSParserTests.kinds(of: "function after(n) { return n }", in: tree) == ["function_declaration"],
                    "\(language) \(broken.debugDescription)")
        }
    }

    /// An outer element's closing tag closes the ones left open inside it, and the lexer agrees.
    @Test func anOuterClosingTagClosesTheElementsInside() throws {
        let text = "const a = <div><p><b>x</div>;\nconst next = 1;\n"
        let (tokens, tree) = try Self.highlight(text, "jsx")
        #expect(tree.errors.count == 2, "\(JSParserTests.errors(tree))")
        #expect(JSParserTests.kinds(of: "<div><p><b>x</div>", in: tree) == ["jsx_element"])
        #expect(Self.scope(of: "next", in: text, tokens: tokens) == "variable.other")
    }

    // MARK: Incremental reparsing

    static let editPieces = ["<", "</", ">", "/>", "<div>", "</div>", "<A b={c}>", "</A>", "<>", "</>", "{", "}", "(", ")",
                             "\"", "'", "&amp;", "=", " ", "\n", "x", "<T,>", "() => ", "{/* */}", "{...p}", "//", "`", "🧋"]

    /// Random edits over every JSX and TSX fixture, the highlighter sometimes taking the tree's
    /// re-lexing: the block reparse is always exactly the whole parse.
    @Test(arguments: fixtures)
    func incrementalEqualsFullOnRandomEdits(_ fixture: Fixture) throws {
        let grammar = try Grammar.bundled(fixture.language)
        let parser = JSParserTests.parser(fixture.language)
        let text = try fixture.input()
        for seed in UInt64(1)...4 {
            var rng = SeededGenerator(state: UInt64(text.utf16.count) &* seed &+ 17)
            let highlighter = Highlighter(grammar: grammar, text: text)
            var tree = parser.parse(highlighter.snapshot).tree
            for step in 0..<40 {
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

    /// A file of 100 components: typing in one, in code or inside its JSX, reparses that body.
    @Test(arguments: ["jsx", "tsx"])
    func editsInsideComponentsStayInTheirBlock(_ language: String) throws {
        let text = (0..<100).map { Self.unit.replacingOccurrences(of: "NAME", with: "C\($0)") }.joined()
        let parser = JSParserTests.parser(language)
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        var tree = parser.parse(highlighter.snapshot).tree
        #expect(tree.errors.isEmpty, "\(JSParserTests.errors(tree))")
        var rng = SeededGenerator(state: 11)
        var incremental = 0
        let edits = 40
        for _ in 0..<edits {
            let at = (highlighter.text as NSString).range(of: "total", options: [], range: NSRange(location: Int.random(in: 0..<(highlighter.units.count - 500), using: &rng), length: 500)).location
            guard at != NSNotFound else { continue }
            highlighter.replaceCharacters(in: NSRange(location: at, length: 0), with: ["x + ", "a < b && ", "(<b>n</b>) && ", "`${v}` + "].randomElement(using: &rng)!)
            let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision)!, in: highlighter.snapshot)
            let full = parser.parse(highlighter.snapshot)
            #expect(sameParse(result.tree, full.tree))
            if result.isIncremental {
                incremental += 1
                #expect(result.steps * 40 < full.steps, "a block reparse should cost the block")
            }
            tree = result.tree
            _ = highlighter.applyRelexing(of: tree)
        }
        #expect(incremental * 4 >= edits * 3, "only \(incremental) of \(edits) edits reparsed just a block")
    }

    static let unit = """
    function NAME({ items, title }) {
      const total = items.length;
      return (
        <section className="card" data-count={total}>
          <h2>{title} &amp; more</h2>
          <ul>{items.map(item => <li key={item.id}>{item.label} of {total}</li>)}</ul>
        </section>
      );
    }

    """

    // MARK: Cost

    /// The parser's lookahead per token stays flat as a file grows, on real JSX and on input built
    /// to make recovery, re-lexing or recursion go quadratic.
    @Test(arguments: Self.linearInputs.indices)
    func parseStaysLinear(_ index: Int) throws {
        let (language, name, make) = Self.linearInputs[index]
        let grammar = try Grammar.bundled(language)
        func steps(_ size: Int) -> (parse: Int, units: Int) {
            let highlighter = Highlighter(grammar: grammar, text: make(size))
            let builder = TreeBuilder(highlighter: highlighter)
            JSParserTests.parser(language).parse(builder)
            #expect(leafText(builder.finish().root) == highlighter.text)
            return (builder.lookaheadSteps, highlighter.units.count)
        }
        let small = steps(10_000)
        let large = steps(40_000)
        let ratio = Double(large.parse) / Double(max(small.parse, 1)) * Double(small.units) / Double(large.units)
        #expect(ratio < 1.25, "\(language) \(name): lookahead per unit grew \(String(format: "%.2f", ratio))× at 4× the input")
        #expect(large.parse < large.units * 400, "\(language) \(name): \(large.parse) lookahead steps for \(large.units) units")
    }

    static let linearInputs: [(String, String, @Sendable (Int) -> String)] = [
        ("jsx", "real components", { String(repeating: unit, count: max(1, $0 / unit.utf16.count)) }),
        ("tsx", "real components", { String(repeating: unit, count: max(1, $0 / unit.utf16.count)) }),
        ("jsx", "nested elements", { "x = " + String(repeating: "<a>", count: $0 / 7) + String(repeating: "</a>", count: $0 / 7) }),
        ("jsx", "unclosed elements", { "x = " + String(repeating: "<a>", count: $0 / 3) }),
        ("jsx", "open angles", { String(repeating: "<", count: $0) }),
        ("jsx", "half-typed tags", { String(repeating: "x = <a b=\n", count: $0 / 10) }),
        ("jsx", "unclosed strings", { String(repeating: "x = <a b=\"\n", count: $0 / 11) }),
        ("jsx", "stray braces", { String(repeating: "x = <a>}\n", count: $0 / 9) }),
        ("jsx", "mismatched closers", { "x = <r>" + String(repeating: "<a><b></a>", count: $0 / 10) + "</r>" }),
        ("jsx", "expressions in elements", { "x = " + String(repeating: "<a>{", count: $0 / 4) }),
        ("jsx", "one long line of elements", { String(repeating: "f(<a b={c}>d</a>); ", count: $0 / 20) }),
        ("tsx", "generic-looking arrows", { String(repeating: "x = <T,>() => <T>(a)</T>;\n", count: $0 / 26) })
    ]

    /// Deep nesting stops at the depth limit, so a parse on a background thread's 512 KB stack never overflows.
    @Test(arguments: ["<a>", "<a b={", "<a>{", "<>", "<a><b c={() => <d>"])
    func deepNestingFitsASmallStack(_ opener: String) async throws {
        let text = "x = " + String(repeating: opener, count: 50_000 / opener.utf16.count)
        let snapshot = Highlighter(grammar: try Grammar.bundled("tsx"), text: text).snapshot
        // Awaited, not waited on: blocking a concurrency thread here can starve the other tests.
        let lossless = await withCheckedContinuation { continuation in
            let thread = Thread {
                let builder = TreeBuilder(snapshot: snapshot)
                JSParser(dialect: .tsx).parse(builder)
                continuation.resume(returning: leafText(builder.finish().root) == text)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(lossless)
    }

    // MARK: Registration

    @Test func jsxAndTSXAreRegisteredByExtension() throws {
        for (language, dialect) in [("jsx", JSParser.Dialect.jsx), ("tsx", .tsx)] {
            #expect(GrammarRegistry.shared.grammar(named: language)?.name == language)
            let support = try #require(LanguageSupport.bundled(for: language))
            #expect((support.parser as? JSParser)?.dialect == dialect)
            #expect(support.queries.language == language)
        }
        #expect(GrammarRegistry.shared.grammar(named: "js")?.name == "javascript")
        #expect(GrammarRegistry.shared.grammar(named: "ts")?.name == "typescript")
    }

    /// A background parse session applies the parser's corrections: here, a `<` the lexer took
    /// for an element's is a comparison continuing the line before.
    @MainActor @Test func aParseSessionAppliesTheJSXLexing() async throws {
        let text = "const small = total\n  <limit && ok;\n"
        let highlighter = Highlighter(grammar: try Grammar.bundled("tsx"), text: text)
        #expect(Self.scope(of: "<", in: text, tokens: highlighter.tokens) == "punctuation")
        let session = ParseSession(highlighter: highlighter, parser: JSParser(dialect: .tsx))
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(Self.scope(of: "<", in: text, tokens: highlighter.tokens) == nil)
    }
}
