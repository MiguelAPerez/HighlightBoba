import Foundation
import Testing
@testable import HighlightBoba

@Suite(.timeLimit(.minutes(2))) struct SwiftParserTests {
    static let grammar = try! Grammar.bundled("swift")
    static let parser = SwiftParser()
    static let swiftFixtures = Fixture.all().filter { $0.language == "swift" }
    /// Fixtures that are broken Swift on purpose.
    static let broken: Set<String> = ["recovery", "interpolation-line-break", "unterminated-comment"]

    static func tree(_ text: String) -> (Highlighter, SyntaxTree) {
        let highlighter = Highlighter(grammar: grammar, text: text)
        return (highlighter, parser.parse(highlighter.snapshot).tree)
    }

    /// `text` highlighted through the parser and queries, as `text: scope` for every token.
    static func scopes(_ text: String) -> [String: String] {
        let units = Array(text.utf16)
        var result: [String: String] = [:]
        for token in LanguageSupport.highlight(text, grammar: grammar) {
            let piece = String(decoding: units[token.range.location..<NSMaxRange(token.range)], as: UTF16.self)
            if result[piece] == nil { result[piece] = token.scope }
        }
        return result
    }

    // MARK: Trees

    @Test(arguments: swiftFixtures.filter { !broken.contains($0.name) })
    func validFixturesParseWithoutErrors(_ fixture: Fixture) throws {
        let (_, tree) = Self.tree(try fixture.input())
        #expect(tree.errors.isEmpty, "\(fixture.testDescription): \(tree.errors)")
    }

    @Test(arguments: swiftFixtures)
    func treesAreLossless(_ fixture: Fixture) throws {
        let (highlighter, tree) = Self.tree(try fixture.input())
        #expect(leafText(tree.root) == highlighter.text)
    }

    @Test func declarationsNameTheirParts() {
        let (_, tree) = Self.tree("func f<T>(_ a: T, label b: Int = 1) async throws -> [T] { [a] }")
        #expect(sExpression(tree.root).hasPrefix(
            "root(funcDecl(func functionName(f) genericParameters(< genericParameter(typeName(T)) >) parameterClause(( parameter(wildcard(_) parameterName(a) typeAnnotation(: typeIdentifier(T))) , parameter(parameterLabel(label) parameterName(b) typeAnnotation(: typeIdentifier(Int)) = 1) )) effects(async throws) returnClause(- > arrayType([ typeIdentifier(T) ])) codeBlock({ arrayLiteral([ identifier(a) ]) })))"))
    }

    @Test func operatorsNestByPrecedence() {
        let (_, tree) = Self.tree("x = a + b * c ?? d ? e : f")
        #expect(sExpression(tree.root) == "root(binaryExpr(identifier(x) = ternaryExpr(binaryExpr(binaryExpr(identifier(a) + binaryExpr(identifier(b) * identifier(c))) ? ? identifier(d)) ? identifier(e) : identifier(f))))")
    }

    @Test func trailingClosuresBelongToTheCallButNotToAConditionsBody() {
        let (_, tree) = Self.tree("if ready { run() }\nf(1) { a } label: { b }")
        let kinds = sExpression(tree.root)
        #expect(kinds.contains("ifStmt(if conditionList(identifier(ready)) codeBlock({ callExpr(identifier(run) ( )) }))"))
        #expect(kinds.contains("callExpr(identifier(f) ( argument(1) ) closure({ identifier(a) }) argument(argumentLabel(label) : closure({ identifier(b) })))"))
    }

    @Test func stringInterpolationHoldsExpressions() {
        let (_, tree) = Self.tree(##"let s = "a \(f(x, by: 2)) b" + #"\#(raw)"#"##)
        #expect(sExpression(tree.root).contains("interpolation(\\ ( argument(callExpr(identifier(f) ( argument(identifier(x)) , argument(argumentLabel(by) : 2) ))) )"))
    }

    // MARK: Highlighting: the lexer's known limits

    @Test func aTupleIndexChainIsTwoNumbers() {
        let tokens = LanguageSupport.highlight("let b = t.0.1", grammar: Self.grammar)
        #expect(tokens.contains(HighlightToken(range: NSRange(location: 10, length: 1), scope: "constant.numeric")))
        #expect(tokens.contains(HighlightToken(range: NSRange(location: 12, length: 1), scope: "constant.numeric")))
        // The lexer alone reads `0.1`.
        #expect(Highlighter.highlight("let b = t.0.1", grammar: Self.grammar).contains(HighlightToken(range: NSRange(location: 10, length: 3), scope: "constant.numeric")))
    }

    @Test(arguments: ["let c = x!/2", "let c = y?/2", "infix operator /+/", "let z = a!/b + c"])
    func aSlashThatIsNotARegexOpenerStaysPlain(_ text: String) {
        #expect(Highlighter.highlight(text, grammar: Self.grammar).contains { $0.scope == "string.regexp" }, "the lexer alone reads a regex")
        #expect(!LanguageSupport.highlight(text, grammar: Self.grammar).contains { $0.scope == "string.regexp" })
    }

    @Test func aRealRegexStaysARegex() {
        #expect(LanguageSupport.highlight("let r = /ab+c/", grammar: Self.grammar).contains { $0.scope == "string.regexp" })
    }

    // MARK: Highlighting: context

    @Test func contextualKeywordsUsedAsNamesAreNames() {
        let scopes = Self.scopes("let some = 1\nfunc f(async: Bool) { get(set: some) }\nvar x: some P { get }")
        #expect(scopes["get"] == "support.function", "the call; the accessor `get` comes later in the text")
        #expect(scopes["async"] == "variable.parameter")
        #expect(scopes["set"] == "variable.parameter")
        #expect(scopes["some"] == "variable.other")
        let accessor = LanguageSupport.highlight("var x: some P { get }", grammar: Self.grammar)
        #expect(accessor.contains(HighlightToken(range: NSRange(location: 7, length: 4), scope: "keyword")), "`some` in a type")
        #expect(accessor.contains(HighlightToken(range: NSRange(location: 16, length: 3), scope: "keyword")), "the accessor")
    }

    @Test func declaredNamesGetTheirRole() {
        let scopes = Self.scopes("enum Color { case red }\nstruct Point<Scalar> { let x: Scalar }\nfunc move(by delta: Int) {}\nlet URL = Color.red")
        #expect(scopes["red"] == "variable.other.enummember")
        #expect(scopes["x"] == "variable.other")
        #expect(scopes["by"] == "variable.parameter")
        #expect(scopes["delta"] == "variable.parameter")
        #expect(scopes["URL"] == "variable.other", "a capitalized name declared as a value")
        #expect(scopes["Scalar"] == "entity.name.type")
    }

    @Test func aWordInATypePositionIsAType() {
        let scopes = Self.scopes("let v: foo.bar = make()")
        #expect(scopes["foo"] == "entity.name.type")
        #expect(scopes["make"] == "support.function")
    }

    @Test func queriesUseOnlyVocabularyScopes() throws {
        let queries = try HighlightQueries.bundled("swift")
        for query in queries.queries {
            #expect(Scopes.vocabulary.contains(query.scope), "\(query.scope) is not in Scopes.vocabulary")
        }
    }

    @Test func swiftIsRegisteredAndLexerOnlyLanguagesAreNot() {
        #expect(LanguageSupport.bundled(for: "swift") != nil)
        #expect(LanguageSupport.bundled(for: "Swift") != nil)
        #expect(LanguageSupport.bundled(for: "json") == nil)
    }

    // MARK: Recovery

    @Test func aTypoCostsOneConstruct() {
        let text = """
        struct A {
            func f(_ x: Int -> Int {
                let y = x +
            }
            let list = [1, 2,
            func g() -> Bool { true }
        }
        let after = A().g()
        """
        let (_, tree) = Self.tree(text)
        #expect(!tree.errors.isEmpty)
        let scopes = Self.scopes(text)
        #expect(scopes["g"] == "entity.name.function", "the declaration after an unclosed list")
        #expect(scopes["after"] == "variable.other", "the statement after the broken type")
    }

    @Test(arguments: [
        String(repeating: "(", count: 20_000), String(repeating: "[", count: 20_000), String(repeating: "{", count: 20_000),
        String(repeating: "f(", count: 10_000), String(repeating: "a = ", count: 20_000), String(repeating: "a ? b : ", count: 10_000),
        String(repeating: "- ", count: 12_000), String(repeating: "try ", count: 20_000), String(repeating: "let x: [", count: 10_000),
        "let x: " + String(repeating: "A<", count: 20_000), String(repeating: "{ x in ", count: 10_000),
        String(repeating: "\"\\(", count: 20_000), String(repeating: "case .a(let ", count: 8_000),
        String(repeating: "f { a, b ", count: 10_000), String(repeating: "V(x: [y.map { if a { W { ", count: 4_000)
    ])
    func deepNestingStopsBeforeTheStackRunsOut(_ text: String) async {
        // A background thread's stack, the size `ParseSession` parses on.
        let finished = await withCheckedContinuation { continuation in
            let thread = Thread {
                let (highlighter, tree) = Self.tree(text)
                continuation.resume(returning: leafText(tree.root) == highlighter.text)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(finished)
    }

    // MARK: Incremental

    static let editPieces = ["{", "}", "(", ")", "[", "]", "\"", "\\(", "/", "!/", ".0.1", "x", " ", "\n", "in ", "let ",
                             "case ", "get ", "//", "/*", "*/", "#", "?", ":", ",", "<", ">", "🧋", "func f() ", "$0"]

    /// Random edits over every Swift fixture: the incremental tree is always the whole parse's.
    @Test(arguments: swiftFixtures)
    func incrementalEqualsFullOnRandomEdits(_ fixture: Fixture) throws {
        let text = try fixture.input()
        var incremental = 0
        for seed in UInt64(1)...6 {
            var rng = SeededGenerator(state: seed &* 7919 &+ UInt64(text.utf16.count))
            var (highlighter, tree) = Self.tree(text)
            for step in 0..<40 {
                for _ in 0..<Int.random(in: 1...2, using: &rng) {
                    let units = highlighter.units.count
                    let location = Int.random(in: 0...units, using: &rng)
                    let length = Int.random(in: 0...min(4, units - location), using: &rng)
                    let insert = Bool.random(using: &rng) ? IncrementalTests.randomText(Self.editPieces, count: Int.random(in: 1...2, using: &rng), using: &rng) : ""
                    let safe = (highlighter.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
                    highlighter.replaceCharacters(in: safe, with: insert)
                }
                let edit = highlighter.edit(since: tree.revision) ?? TextEdit(range: NSRange(), replacementLength: 0)
                let result = Self.parser.reparse(tree, after: edit, in: highlighter.snapshot)
                let full = Self.parser.parse(highlighter.snapshot)
                guard sameParse(result.tree, full.tree) else {
                    Issue.record("\(fixture.testDescription) seed \(seed) step \(step): \(firstDifference(result.tree, full.tree)) in \(highlighter.text.debugDescription)")
                    return
                }
                if result.isIncremental { incremental += 1 }
                tree = result.tree
                if Bool.random(using: &rng) { _ = highlighter.applyRelexing(of: tree) }
            }
        }
        _ = incremental
    }

    @Test func anEditInAFunctionBodyReparsesOnlyThatBody() {
        let text = (0..<200).map { "func f\($0)(x: Int) -> Int {\n    let y = x * \($0)\n    return y\n}\n" }.joined()
        var (highlighter, tree) = Self.tree(text)
        let at = (text as NSString).range(of: "x * 100").location
        let result = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: at, length: 1), "x + y")
        #expect(result.isIncremental)
        #expect(result.changed.kind == SwiftKind.codeBlock)
        #expect(result.steps * 50 < Self.parser.parse(highlighter.snapshot).steps, "a body's reparse costs the body, not the file")
    }

    @Test func blocksOfEveryBoundaryKindReparseAlone() {
        let text = "struct S {\n    var v: Int { get { 1 } }\n    func f() { run { x in x } }\n}\n"
        for (marker, kind) in [("1", SwiftKind.codeBlock), ("x in x", SwiftKind.closure)] {
            var (highlighter, tree) = Self.tree(text)
            let at = (text as NSString).range(of: marker)
            let result = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: NSMaxRange(at) - 1, length: 0), " ")
            #expect(result.isIncremental && result.changed.kind == kind, "\(marker)")
        }
        var (highlighter, tree) = Self.tree(text)
        let at = (text as NSString).range(of: "    func").location
        let member = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: at, length: 0), "let w = 2\n")
        #expect(member.isIncremental && member.changed.kind == SwiftKind.memberBlock)
        (highlighter, tree) = Self.tree(text)
        let getter = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: (text as NSString).range(of: " get").location, length: 0), " set {}")
        #expect(getter.isIncremental && getter.changed.kind == SwiftKind.accessorBlock)
    }

    @MainActor @Test func aParseSessionKeepsASwiftTree() async {
        let highlighter = Highlighter(grammar: Self.grammar, text: "func f() {\n    let a = 1\n}\n")
        let session = ParseSession(highlighter: highlighter, parser: Self.parser)
        session.textDidChange()
        await session.waitUntilIdle()
        _ = highlighter.replaceCharacters(in: NSRange(location: 23, length: 1), with: "2 + t.0.1")
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(session.tree.map { leafText($0.root) } == highlighter.text)
        #expect(session.tree?.errors.isEmpty == true)
    }

    // MARK: Cost

    static let growing: [(String, @Sendable (Int) -> String)] = [
        ("tour", { String(repeating: SwiftParserTests.tour, count: $0) }),
        ("generic lookahead", { String(repeating: "a<b, c<d, e ", count: $0 * 40) }),
        ("closure signatures", { String(repeating: "f { a, b, c, d, e, f, g ", count: $0 * 20) + String(repeating: "}", count: $0 * 20) }),
        ("dictionary lookahead", { String(repeating: "[a + b + c + d + e + f + g ", count: $0 * 20) }),
        ("comments between tokens", { String(repeating: "a /* c */ . /* c */ b\n", count: $0 * 40) })
    ]

    /// Parser lookahead grows linearly with the file, for real code and for inputs built to make
    /// the parser's bounded lookaheads (generics, closures, dictionaries) look far.
    @Test(arguments: growing.indices)
    func parsingStaysLinear(_ index: Int) {
        let (name, make) = Self.growing[index]
        func steps(_ copies: Int) -> Int {
            let highlighter = Highlighter(grammar: Self.grammar, text: make(copies))
            return Self.parser.parse(highlighter.snapshot).steps
        }
        let small = steps(10), large = steps(40)
        let ratio = Double(large) / Double(max(small, 1))
        #expect(ratio < 4.6, "\(name): 4× input cost \(String(format: "%.1f", ratio))× the lookahead")
    }

    static let tour: String = {
        let url = Fixture.root.appendingPathComponent("swift/parsed-statements.input")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test func largeFileBenchmark() {
        let text = String(repeating: Self.tour, count: 60)
        let clock = ContinuousClock()
        let highlighter = Highlighter(grammar: Self.grammar, text: text)
        var tree: SyntaxTree?
        let parse = clock.measure { tree = Self.parser.parse(highlighter.snapshot).tree }
        let queries = try! HighlightQueries.bundled("swift")
        let run = clock.measure { _ = queries.run(on: tree!) }
        print("benchmark: \(text.utf16.count / 1024) KB Swift, parse \(parse), queries \(run)")
        #expect(tree!.errors.isEmpty)
    }
}
