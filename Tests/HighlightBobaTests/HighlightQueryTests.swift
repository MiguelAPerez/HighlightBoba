import Foundation
import Testing
@testable import HighlightBoba

/// A toy language for the query tests: `fn name(params) { … }`, `let name = expr;`, `return expr;`
/// and calls, parsed by recursive descent over `TreeBuilder` like a real parser.
enum ToyLanguage {
    static let function = SyntaxKind("function")
    static let name = SyntaxKind("name")
    static let parameters = SyntaxKind("parameters")
    static let parameter = SyntaxKind("parameter")
    static let block = SyntaxKind("block")
    static let binding = SyntaxKind("let")
    static let returning = SyntaxKind("return")
    static let call = SyntaxKind("call")
    static let arguments = SyntaxKind("arguments")
    static let binary = SyntaxKind("binary")

    static let grammar: Grammar = {
        let json = #"""
        {"name":"toy","initial":"code","states":{
          "code":{"rules":[
            {"match":{"literal":"#"},"scope":"comment.line","push":"comment"},
            {"match":{"words":["fn","let","return"]},"scope":"keyword"},
            {"match":{"literal":"\""},"scope":"string.quoted","push":"string"},
            {"match":{"repeat":"[0-9]","min":1},"scope":"constant.numeric"},
            {"match":{"class":"[(){};,]"},"scope":"punctuation"}]},
          "string":{"scope":"string.quoted","endsAtEOL":true,"rules":[{"match":{"literal":"\""},"pop":true}]},
          "comment":{"scope":"comment.line","endsAtEOL":true,"rules":[]}}}
        """#
        return try! Grammar(data: Data(json.utf8))
    }()

    static func parse(_ highlighter: Highlighter) -> SyntaxTree {
        let builder = TreeBuilder(highlighter: highlighter)
        while !builder.isAtEnd { statement(builder) }
        return builder.finish()
    }

    static func parse(_ text: String) -> (Highlighter, SyntaxTree) {
        let highlighter = Highlighter(grammar: grammar, text: text)
        return (highlighter, parse(highlighter))
    }

    static func isWord(_ builder: TreeBuilder) -> Bool { builder.current?.kind == .word }

    static func statement(_ builder: TreeBuilder) {
        if builder.at("fn") {
            builder.startNode(function)
            builder.bump()
            if isWord(builder) {
                builder.startNode(name)
                builder.bump()
                builder.finishNode()
            } else {
                builder.error("expected a name")
            }
            builder.startNode(parameters)
            builder.expect("(")
            while !builder.isAtEnd && !builder.at(")") && !builder.at("{") {
                if isWord(builder) {
                    builder.startNode(parameter)
                    builder.bump()
                    builder.finishNode()
                } else {
                    builder.errorAndBump("expected a parameter")
                }
                builder.bump(",")
            }
            builder.expect(")")
            builder.finishNode()
            block(builder)
            builder.finishNode()
        } else if builder.at("let") {
            builder.startNode(binding)
            builder.bump()
            if isWord(builder) {
                builder.startNode(name)
                builder.bump()
                builder.finishNode()
            }
            builder.expect("=")
            expression(builder)
            end(builder)
            builder.finishNode()
        } else if builder.at("return") {
            builder.startNode(returning)
            builder.bump()
            expression(builder)
            end(builder)
            builder.finishNode()
        } else if builder.at("}") || builder.at(")") {
            builder.errorAndBump("unexpected closing bracket")
        } else {
            expression(builder)
            end(builder)
        }
    }

    static func end(_ builder: TreeBuilder) {
        if !builder.bump(";") {
            builder.recover("expected `;`", until: [";", "}"])
            builder.bump(";")
        }
    }

    static func block(_ builder: TreeBuilder) {
        builder.startNode(block)
        builder.expect("{")
        while !builder.isAtEnd && !builder.at("}") { statement(builder) }
        builder.expect("}")
        builder.finishNode()
    }

    static func expression(_ builder: TreeBuilder) {
        let start = builder.checkpoint()
        primary(builder)
        while builder.at("+") {
            builder.startNode(binary, at: start)
            builder.bump()
            primary(builder)
            builder.finishNode()
        }
    }

    static func primary(_ builder: TreeBuilder) {
        guard builder.depth < 200 else { return builder.errorAndBump("nested too deeply") }
        if isWord(builder) {
            let start = builder.checkpoint()
            builder.bump()
            guard builder.at("(") else { return }
            builder.startNode(call, at: start)
            builder.startNode(arguments)
            builder.bump()
            while !builder.isAtEnd && !builder.at(")") && !builder.at(";") {
                expression(builder)
                if !builder.bump(",") { break }
            }
            builder.expect(")")
            builder.finishNode()
            builder.finishNode()
        } else if builder.current?.kind == .lexeme && !builder.at(";") && !builder.at("}") && !builder.at(")") {
            builder.bump()
        } else {
            builder.errorAndBump("expected an expression")
        }
    }
}

func queries(_ list: String) throws -> HighlightQueries {
    try HighlightQueries(data: Data(#"{"format":1,"language":"toy","queries":\#(list)}"#.utf8))
}

/// Each override as `text:scope`.
func overridden(_ refinement: ScopeRefinement, in text: String) -> [String] {
    let units = Array(text.utf16)
    return refinement.overrides.map {
        "\(String(decoding: units[$0.range.location..<NSMaxRange($0.range)], as: UTF16.self)):\($0.scope)"
    }
}

@Suite struct HighlightQueryTests {
    static let toyQueries = #"""
    [
      {"in": ["name", "function"], "scope": "entity.name.function"},
      {"kind": "word", "in": ["call"], "index": 0, "scope": "support.function"},
      {"text": "self", "kind": "word", "scope": "variable.language"},
      {"in": ["parameter"], "scope": "variable.other"},
      {"in": ["name", "let"], "inside": "function", "scope": "variable.other"},
      {"in": ["error"], "scope": "invalid"}
    ]
    """#

    static let program = """
    fn area(self, width, height) {
        let size = mul(width, height); # local
        return size + self;
    }
    let total = area(1, 2);
    print("done", total);

    """

    @Test func queriesRefineTheTokensTheyMatch() throws {
        let (_, tree) = ToyLanguage.parse(Self.program)
        let refinement = try queries(Self.toyQueries).run(on: tree)
        #expect(overridden(refinement, in: Self.program) == [
            "area:entity.name.function", "self:variable.language", "width:variable.other", "height:variable.other",
            "size:variable.other", "mul:support.function", "self:variable.language", "area:support.function", "print:support.function"
        ])
        #expect(tree.errors.isEmpty)
    }

    @Test func theFirstMatchingQueryWins() throws {
        let text = "fn f(self, x) {}"
        let (_, tree) = ToyLanguage.parse(text)
        let selfFirst = try queries(#"[{"text":"self","scope":"variable.language"},{"in":["parameter"],"scope":"variable.other"}]"#)
        let parameterFirst = try queries(#"[{"in":["parameter"],"scope":"variable.other"},{"text":"self","scope":"variable.language"}]"#)
        #expect(overridden(selfFirst.run(on: tree), in: text) == ["self:variable.language", "x:variable.other"])
        #expect(overridden(parameterFirst.run(on: tree), in: text) == ["self:variable.other", "x:variable.other"])
    }

    @Test func aQueryThatKeepsTheScopeStillWins() throws {
        // `return` is already a keyword: the first query matches, changes nothing and stops the second.
        let text = "fn f() { return 1; }"
        let (_, tree) = ToyLanguage.parse(text)
        let set = try queries(#"[{"text":"return","scope":"keyword"},{"lexerScope":"keyword","scope":"constant.language"}]"#)
        #expect(overridden(set.run(on: tree), in: text) == ["fn:constant.language"])
    }

    @Test func pathsMatchFromTheParentOutward() throws {
        let text = "let a = f(b); fn g(c) { let d = 1; }"
        let (_, tree) = ToyLanguage.parse(text)
        #expect(overridden(try queries(#"[{"in":["name","let"],"scope":"variable.other"}]"#).run(on: tree), in: text)
                == ["a:variable.other", "d:variable.other"])
        #expect(overridden(try queries(#"[{"in":["name","let","block"],"scope":"variable.other"}]"#).run(on: tree), in: text)
                == ["d:variable.other"])
        #expect(overridden(try queries(#"[{"in":["name","*","root"],"scope":"variable.other"}]"#).run(on: tree), in: text)
                == ["a:variable.other", "g:variable.other"])
        #expect(overridden(try queries(#"[{"kind":"word","in":["call"],"scope":"support.function"}]"#).run(on: tree), in: text)
                == ["f:support.function"], "`b` is in arguments, not directly in the call")
    }

    @Test func ancestorsMatchAtAnyDepth() throws {
        let text = "let a = f(g(b)); fn h() { let c = k(d); }"
        let (_, tree) = ToyLanguage.parse(text)
        let inside = try queries(#"[{"kind":"word","inside":["function","arguments"],"scope":"variable.other"}]"#)
        #expect(overridden(inside.run(on: tree), in: text) == ["d:variable.other"])
        let outside = try queries(#"[{"kind":"word","inside":"arguments","notInside":"function","scope":"variable.other"}]"#)
        #expect(overridden(outside.run(on: tree), in: text) == ["g:variable.other", "b:variable.other"])
    }

    @Test func positionsCountSignificantChildren() throws {
        // A comment and line breaks between the parameters don't count.
        let text = "fn f(a, # first\n b,\n c) {}"
        let (_, tree) = ToyLanguage.parse(text)
        let first = try queries(#"[{"in":["*","parameters"],"scope":"variable.other"},{"kind":"word","index":0,"scope":"keyword"}]"#)
        #expect(overridden(first.run(on: tree), in: text) == ["f:keyword", "a:variable.other", "b:variable.other", "c:variable.other"],
                "`f` is the first child of its name node")
        let last = try queries(#"[{"kind":"symbol","index":-1,"scope":"invalid"},{"lexerScope":"punctuation","index":-1,"in":"parameters","scope":"keyword"}]"#)
        #expect(overridden(last.run(on: tree), in: text) == ["):keyword"])
        let neighbours = try queries(#"[{"kind":"word","after":"fn","scope":"keyword"},{"lexerScope":"punctuation","before":"{","scope":"keyword"}]"#)
        #expect(neighbours.run(on: tree).overrides.isEmpty, "`f` is in a name node and `{` in a block: neither is a sibling")
    }

    @Test func neighboursAreSiblingTokens() throws {
        let text = "g(a, b, c);"
        let (_, tree) = ToyLanguage.parse(text)
        let set = try queries(#"[{"kind":"word","after":"(","scope":"keyword"},{"kind":"word","after":",","before":",","scope":"variable.other"},{"kind":"word","before":"(","scope":"support.function"}]"#)
        #expect(overridden(set.run(on: tree), in: text) == ["a:keyword", "b:variable.other"],
                "`g` is the call's child and `(` the arguments' first, so they aren't siblings")
    }

    @Test func lexerScopesMatchByPrefix() throws {
        let text = "let a = \"s\"; # c\nlet b = 2;"
        let (_, tree) = ToyLanguage.parse(text)
        let set = try queries(#"[{"lexerScope":"string","in":"let","scope":"markup.raw"},{"lexerScope":"constant.num","scope":"keyword"}]"#)
        #expect(overridden(set.run(on: tree), in: text) == ["\"s\":markup.raw"], "`constant.num` is not a prefix of `constant.numeric`")
        let comments = try queries(#"[{"lexerScope":"comment","scope":"keyword"}]"#)
        #expect(comments.run(on: tree).overrides.isEmpty, "trivia never matches")
    }

    @Test func errorNodesOnlyMatchQueriesThatNameThem() throws {
        let text = "fn f(1, x) { let y = ; }\n)"
        let (_, tree) = ToyLanguage.parse(text)
        #expect(!tree.errors.isEmpty)
        let set = try queries(#"[{"kind":"word","inside":"function","scope":"variable.other"},{"inside":"function","lexerScope":"constant","scope":"keyword"}]"#)
        #expect(overridden(set.run(on: tree), in: text) == ["f:variable.other", "x:variable.other", "y:variable.other"],
                "the `1` in an error node keeps its scope")
        let errors = try queries(#"[{"in":"error","scope":"invalid"},{"inside":["error","function"],"kind":"symbol","scope":"keyword"}]"#)
        #expect(overridden(errors.run(on: tree), in: text) == ["1:invalid", ";:invalid", "):invalid"])
    }

    @Test func aSubtreeRunEqualsTheWholeTreeRunOverItsRange() throws {
        let text = String(repeating: Self.program, count: 3) + "fn broken(1 { g(;\n"
        let (_, tree) = ToyLanguage.parse(text)
        let set = try queries(Self.toyQueries)
        let whole = set.run(on: tree).overrides
        var nodes = [tree.root]
        var checked = 0
        while let node = nodes.popLast() {
            nodes += node.childNodes
            let part = set.run(on: node)
            let range = node.range
            #expect(part.range == range)
            #expect(part.overrides == whole.filter { NSIntersectionRange($0.range, range).length > 0 }, "\(node.kind) at \(range)")
            checked += 1
        }
        #expect(checked > 40)
    }

    @Test func queriesNeverRetokenise() throws {
        let text = Self.program + "fn bad(1, \"q\") { x(]; }\n😀 let é = mul(é, 2);\n"
        let (highlighter, tree) = ToyLanguage.parse(text)
        let refinement = try queries(Self.toyQueries + "").run(on: tree)
        let boundaries = Set(tree.tokens.flatMap { [$0.location, $0.end] })
        let byRange = Dictionary(uniqueKeysWithValues: tree.tokens.map { ($0.range, $0) })
        for override in refinement.overrides {
            #expect(byRange[override.range] != nil, "an override is exactly one token")
            #expect(byRange[override.range]?.isTrivia == false)
        }

        let lexed = highlighter.tokens
        let refined = try #require(highlighter.tokens(refinedBy: refinement))
        func scopes(_ tokens: [HighlightToken]) -> [String?] {
            var result = [String?](repeating: nil, count: text.utf16.count)
            for token in tokens {
                for unit in token.range.location..<NSMaxRange(token.range) {
                    #expect(result[unit] == nil, "spans overlap at \(unit)")
                    result[unit] = token.scope
                }
            }
            return result
        }
        let before = scopes(lexed)
        let after = scopes(refined)
        let overridden = Set(refinement.overrides.flatMap { Array($0.range.location..<NSMaxRange($0.range)) })
        for unit in before.indices where !overridden.contains(unit) {
            #expect(before[unit] == after[unit], "unit \(unit) was repainted without an override")
        }
        for override in refinement.overrides {
            #expect(after[override.range.location] == override.scope)
        }
        // Spans only ever end where a lexer span or a tree token already did.
        let lexerBoundaries = Set(lexed.flatMap { [$0.range.location, NSMaxRange($0.range)] })
        for token in refined {
            #expect(lexerBoundaries.contains(token.range.location) || boundaries.contains(token.range.location))
            #expect(lexerBoundaries.contains(NSMaxRange(token.range)) || boundaries.contains(NSMaxRange(token.range)))
        }
        #expect(refined == refined.sorted { $0.range.location < $1.range.location })
        #expect(tree.tokens == ToyLanguage.parse(text).1.tokens, "running queries leaves the tree as it was")
    }

    @Test func applyingCutsPunctuationRunsOnlyAtTheOverride() {
        let refinement = ScopeRefinement(range: NSRange(location: 0, length: 6),
                                         overrides: [ScopeOverride(range: NSRange(location: 0, length: 1), scope: "a"),
                                                     ScopeOverride(range: NSRange(location: 3, length: 1), scope: "b")],
                                         highlighter: nil, revision: 0, steps: 0)
        let lexed = [HighlightToken(range: NSRange(location: 2, length: 3), scope: "punctuation")]
        #expect(refinement.apply(to: lexed) == [
            HighlightToken(range: NSRange(location: 0, length: 1), scope: "a"),
            HighlightToken(range: NSRange(location: 2, length: 1), scope: "punctuation"),
            HighlightToken(range: NSRange(location: 3, length: 1), scope: "b"),
            HighlightToken(range: NSRange(location: 4, length: 1), scope: "punctuation")
        ])
    }

    @Test func aStaleRefinementIsNotApplied() throws {
        let (highlighter, tree) = ToyLanguage.parse("fn f() {}")
        let refinement = try queries(Self.toyQueries).run(on: tree)
        #expect(highlighter.tokens(refinedBy: refinement) != nil)
        highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")
        #expect(highlighter.tokens(refinedBy: refinement) == nil)
        let other = Highlighter(grammar: ToyLanguage.grammar, text: " fn f() {}")
        #expect(other.tokens(refinedBy: refinement) == nil)
    }

    @Test func aDeepTreeRunsWithoutRecursion() throws {
        let depth = 50_000
        let text = String(repeating: "(", count: depth)
        let builder = TreeBuilder(tokens: (0..<depth).map { SyntaxToken(kind: .symbol, location: $0, length: 1) }, text: text)
        for _ in 0..<depth {
            builder.startNode(ToyLanguage.arguments)
            builder.bump()
        }
        for _ in 0..<depth { builder.finishNode() }
        let tree = builder.finish()
        let set = try queries(#"[{"in":["arguments","arguments","arguments"],"inside":"root","scope":"keyword"}]"#)
        #expect(set.run(on: tree).overrides.count == depth - 2)
    }

    @Test(arguments: [
        (#"{"format":2,"language":"toy","queries":[]}"#, "format"),
        (#"{"format":1,"queries":[]}"#, "language"),
        (#"{"format":1,"language":"toy","queries":[{"scope":"keyword"}]}"#, "every token"),
        (#"{"format":1,"language":"toy","queries":[{"text":"a"}]}"#, "scope"),
        (#"{"format":1,"language":"toy","queries":[{"text":"a","scope":"keyword","colour":1}]}"#, "unknown key \"colour\""),
        (#"{"format":1,"language":"toy","queries":[{"kind":"space","scope":"keyword"}]}"#, "\"kind\""),
        (#"{"format":1,"language":"toy","queries":[{"kind":"word","lexerScope":"keyword","scope":"keyword"}]}"#, "lexer scope"),
        (#"{"format":1,"language":"toy","queries":[{"index":"1","scope":"keyword"}]}"#, "integer"),
        (#"{"format":1,"language":"toy","queries":[{"inside":"*","scope":"keyword"}]}"#, "\"*\""),
        (#"{"format":1,"language":"toy","queries":[{"in":[],"scope":"keyword"}]}"#, "non-empty array"),
        (#"{"format":1,"language":"toy","queries":[{"text":["a",""],"scope":"keyword"}]}"#, "\"text\""),
        (#"{"format":1,"language":"toy","queries":[{"after":"","scope":"keyword"}]}"#, "\"after\""),
        ("[1]", "JSON object")
    ])
    func badQueriesAreRejected(_ json: String, _ message: String) {
        #expect {
            try HighlightQueries(data: Data(json.utf8))
        } throws: { error in
            (error as? QueryError)?.description.contains(message) == true
        }
    }

    // MARK: Linearity

    static let shapes: [(String, @Sendable (Int) -> String)] = [
        ("many functions", { String(repeating: "fn f(a, b) { let c = g(a, b) + 1; }\n", count: $0 / 36) }),
        ("deeply nested calls", { String(repeating: String(repeating: "f(", count: 150) + "x" + String(repeating: ")", count: 150) + ";\n", count: $0 / 452) }),
        ("long argument lists", { "f(" + String(repeating: "a, ", count: $0 / 3) + ");" }),
        ("error soup", { String(repeating: "fn ) ( 1 } ; ", count: $0 / 13) })
    ]

    static let manyQueries = #"""
    [
      {"in": ["name", "function"], "scope": "entity.name.function"},
      {"kind": "word", "in": ["call"], "index": 0, "scope": "support.function"},
      {"kind": "word", "in": ["*", "arguments", "call", "*", "arguments"], "scope": "variable.other"},
      {"kind": "word", "inside": ["function", "block", "arguments"], "notInside": "error", "scope": "variable.other"},
      {"text": ["a", "b", "c", "x"], "after": ",", "before": ",", "scope": "variable.other"},
      {"in": ["error"], "scope": "invalid"}
    ]
    """#

    @Test(arguments: shapes.indices)
    func runsStayLinear(_ index: Int) throws {
        let (name, make) = Self.shapes[index]
        let set = try queries(Self.manyQueries)
        let small = set.run(on: ToyLanguage.parse(make(20_000)).1).steps
        let large = set.run(on: ToyLanguage.parse(make(80_000)).1).steps
        let ratio = Double(large) / Double(max(small, 1))
        #expect(ratio < 5, "\(name): 4× input cost \(String(format: "%.1f", ratio))× the work")
        #expect(large < 80_000 * 16, "\(name): \(large) steps for 80k units")
    }

    @Test func benchmark() throws {
        let text = String(repeating: Self.program, count: 4_000)
        let (_, tree) = ToyLanguage.parse(text)
        let set = try queries(Self.toyQueries)
        let clock = ContinuousClock()
        var refinement: ScopeRefinement?
        let time = clock.measure { refinement = set.run(on: tree) }
        print("benchmark: \(text.utf16.count / 1024) KB toy source, \(tree.tokens.count) tokens, queries ran in \(time)")
        #expect(refinement!.overrides.count == 9 * 4_000)
    }
}
