import Foundation
import Testing
@testable import HighlightBoba

@Suite(.timeLimit(.minutes(2))) struct ShellParserTests {
    static let grammar = try! Grammar.bundled("shell")
    static let parser = ShellParser()
    static let shellFixtures = Fixture.all().filter { $0.language == "shell" }
    /// Fixtures that are broken shell on purpose.
    static let broken: Set<String> = ["recovery"]
    /// Fixtures that exist for what the parser fixes: the lexer alone renders them differently.
    static let parserFixtures: Set<String> = ["parsed-commands", "parsed-compound", "relexing", "recovery"]

    static func tree(_ text: String) -> (Highlighter, SyntaxTree) {
        let highlighter = Highlighter(grammar: grammar, text: text)
        return (highlighter, parser.parse(highlighter.snapshot).tree)
    }

    /// The scope of each token of `text` through the parser and queries, by its text (first wins).
    static func scopes(_ text: String) -> [String: String] {
        let units = Array(text.utf16)
        var result: [String: String] = [:]
        for token in LanguageSupport.highlight(text, grammar: grammar) {
            let piece = String(decoding: units[token.range.location..<NSMaxRange(token.range)], as: UTF16.self)
            if result[piece] == nil { result[piece] = token.scope }
        }
        return result
    }

    /// The scope at the `occurrence`-th match of `piece` (from 0), or nil where it is plain.
    static func scope(of piece: String, occurrence: Int = 0, in text: String) -> String? {
        var range = NSRange(location: 0, length: 0)
        var searchFrom = 0
        for _ in 0...occurrence {
            range = (text as NSString).range(of: piece, range: NSRange(location: searchFrom, length: text.utf16.count - searchFrom))
            searchFrom = NSMaxRange(range)
        }
        return LanguageSupport.highlight(text, grammar: grammar).first { NSIntersectionRange($0.range, range).length > 0 }?.scope
    }

    // MARK: Trees

    @Test(arguments: shellFixtures.filter { !broken.contains($0.name) })
    func validFixturesParseWithoutErrors(_ fixture: Fixture) throws {
        let (_, tree) = Self.tree(try fixture.input())
        #expect(tree.errors.isEmpty, "\(fixture.testDescription): \(tree.errors)")
    }

    @Test(arguments: shellFixtures)
    func treesAreLossless(_ fixture: Fixture) throws {
        let (highlighter, tree) = Self.tree(try fixture.input())
        #expect(leafText(tree.root) == highlighter.text)
    }

    @Test(arguments: shellFixtures.filter { parserFixtures.contains($0.name) })
    func parserFixturesFailWithTheLexerAlone(_ fixture: Fixture) throws {
        let input = try fixture.input()
        let lexed = CaretRenderer.render(input, tokens: Highlighter.highlight(input, grammar: Self.grammar))
        #expect(lexed != fixture.expected(), "\(fixture.testDescription) doesn't need the parser")
    }

    @Test func commandsNameTheirParts() {
        let (_, tree) = Self.tree("FOO=1 ls -la >out 2>&1 | grep -v x && echo done; sleep 1 &")
        #expect(sExpression(tree.root) == "root(andOr(pipeline(command(assignment(variableName(FOO) = word(1)) commandName(ls) option(- la) redirect(> word(out)) redirect(2 > & word(1))) | command(commandName(grep) option(- v) word(x))) & & command(builtinName(echo) word(done))) ; command(commandName(sleep) word(1)) &)")
    }

    @Test func compoundCommandsNest() {
        let (_, tree) = Self.tree("f() { if a; then for x in 1 2; do (b); done; fi; }")
        #expect(sExpression(tree.root) == "root(functionDefinition(functionName(f) ( ) braceGroup({ ifCommand(if command(commandName(a)) ; then forCommand(for variableName(x) in word(1) word(2) ; do subshell(( command(commandName(b)) )) ; done) ; fi) ; })))")
    }

    @Test func heredocBodiesFollowTheirLine() {
        let (_, tree) = Self.tree("cat <<A <<'B' | wc\none $x\nA\ntwo\nB\necho after\n")
        #expect(sExpression(tree.root) == "root(pipeline(command(commandName(cat) redirect(<<A) redirect(<<'B')) | command(commandName(wc))) heredocBody(one  $x A) heredocBody(two B) command(builtinName(echo) word(after)))")
    }

    @Test func substitutionsHoldCommands() {
        let (_, tree) = Self.tree("echo \"$(ls $(pwd))\" `date` ${x:-$(id)} $((n + 1)) <(sort f)")
        let s = sExpression(tree.root)
        #expect(s.contains("word(\" commandSubstitution($ ( command(commandName(ls) word(commandSubstitution($ ( command(builtinName(pwd)) )))) )) \")"))
        #expect(s.contains("word(backtickSubstitution(` command(commandName(date)) `))"))
        #expect(s.contains("word(expansion(${x:- commandSubstitution($ ( command(commandName(id)) )) }))"))
        #expect(s.contains("word(arithmeticExpansion($ ( ( arithmetic(variableName(n) + 1) ) )))"))
        #expect(s.contains("word(processSubstitution(< ( command(commandName(sort) word(f)) )))"))
    }

    // MARK: Highlighting: command position

    @Test(arguments: [
        ("echo if then else fi do done case esac in select time function", ["if", "done", "esac", "function"]),
        ("x=done y=true", ["done", "true"]), ("cat <<< for", ["for"]), ("printf '%s' echo test", ["echo", "test"])
    ])
    func reservedWordsAndBuiltinsAreArgumentsOutsideCommandPosition(_ text: String, _ plain: [String]) {
        let lexed = Highlighter.highlight(text, grammar: Self.grammar)
        for word in plain {
            let range = (text as NSString).range(of: word, options: .backwards)
            #expect(lexed.contains { $0.range == range }, "the lexer alone scopes \(word)")
            #expect(Self.scope(of: word, occurrence: text.components(separatedBy: word).count - 2, in: text) == nil, "\(word) in \(text)")
        }
    }

    @Test func builtinsAndCommandsAreToldApart() {
        let text = "echo a; ls b; local c=1; ./run d; sudo echo e; [ -f x ]"
        #expect(Self.scope(of: "echo", in: text) == "support.function")
        #expect(Self.scope(of: "ls", in: text) == "entity.name.function")
        #expect(Self.scope(of: "local", in: text) == "keyword")
        #expect(Self.scope(of: "run", in: text) == "entity.name.function")
        #expect(Self.scope(of: "sudo", in: text) == "entity.name.function")
        #expect(Self.scope(of: "echo", occurrence: 1, in: text) == nil, "an argument of sudo")
        #expect(Self.scope(of: "[", in: text) == "support.function")
    }

    @Test func declaredAndAssignedNamesAreVariables() {
        let text = "a=1 b+=2 c[0]=3 cmd; export D E=5; read -r F G; for H in x; do :; done; local -a I=(1); getopts ab J; unset K"
        for name in ["a", "b", "c", "D", "E", "F", "G", "H", "I", "J", "K"] {
            #expect(Self.scope(of: name, in: text) == "variable.other", "\(name)")
        }
        #expect(Self.scope(of: " x;", in: text) == nil)
        #expect(Self.scope(of: "ab", in: text) == nil, "getopts' option string")
    }

    @Test func functionNamesOptionsPatternsAndTestOperators() {
        let text = "my-func() { :; }\ncase $1 in start|-x) ls --all -l;; esac\n[[ -n $a && $b =~ ^x+$ ]]"
        #expect(Self.scope(of: "my", in: text) == "entity.name.function")
        #expect(Self.scope(of: "func", in: text) == "entity.name.function")
        #expect(Self.scope(of: "start", in: text) == "string.regexp")
        #expect(Self.scope(of: "all", in: text) == "variable.parameter")
        #expect(Self.scope(of: "-n", in: text) == "keyword")
        #expect(Self.scope(of: "&&", in: text) == "keyword")
        #expect(Self.scope(of: "^x+$", in: text) == "string.regexp")
    }

    // MARK: Highlighting: the lexer's mistakes

    @Test func aCasePatternInASubstitutionKeepsTheSubstitutionOpen() {
        let text = "echo \"$(case $v in a) echo a;; esac)\" tail"
        let lexed = Highlighter.highlight(text, grammar: Self.grammar)
        let parsed = LanguageSupport.highlight(text, grammar: Self.grammar)
        let close = (text as NSString).range(of: "esac)").location + 4
        #expect(lexed.contains { NSLocationInRange(close, $0.range) && $0.scope == "string.quoted" }, "the lexer alone closed the substitution early")
        #expect(parsed.contains { $0.range.location == close && $0.scope == "punctuation.section.embedded" })
        #expect(Self.scope(of: "tail", in: text) == nil)
    }

    @Test(arguments: ["echo $((1 << n))\necho next", "(( a <<b ))\necho next"])
    func aShiftIsNotAHeredoc(_ text: String) {
        #expect(Highlighter.highlight(text, grammar: Self.grammar).contains { $0.scope == "string.quoted" }, "the lexer alone reads a heredoc")
        #expect(!LanguageSupport.highlight(text, grammar: Self.grammar).contains { $0.scope == "string.quoted" })
        #expect(Self.scope(of: "echo", occurrence: text.hasPrefix("echo") ? 1 : 0, in: text) == "support.function")
    }

    @Test func anEscapedHeredocDelimiterIsAHeredoc() {
        let text = "cat <<\\END\nno $x here\nEND\necho back"
        #expect(Self.scope(of: "no", in: text) == "string.quoted")
        #expect(Self.scope(of: "$x", in: text) == "string.quoted", "a quoted delimiter's body has no expansions")
        #expect(Self.scope(of: "echo", in: text) == "support.function")
        #expect(Highlighter.highlight(text, grammar: Self.grammar).contains { $0.scope == "variable.other" })
    }

    @Test func queriesUseOnlyVocabularyScopes() throws {
        let queries = try HighlightQueries.bundled("shell")
        for query in queries.queries {
            #expect(Scopes.vocabulary.contains(query.scope), "\(query.scope) is not in Scopes.vocabulary")
        }
    }

    @Test func shellIsRegistered() {
        #expect(LanguageSupport.bundled(for: "shell") != nil)
    }

    // MARK: Recovery

    @Test func aTypoCostsOneConstruct() {
        let text = """
        if true; then
          echo "no fi"
        while; do done
        f() { echo unclosed
        case x in a) ls
        echo ) stray
        [[ -f x
        y=(a b; echo after
        echo && || echo
        greet() { echo hi; }
        """
        let (_, tree) = Self.tree(text)
        #expect(!tree.errors.isEmpty)
        #expect(Self.scope(of: "greet", in: text) == "entity.name.function", "the definition after the broken ones")
        #expect(Self.scope(of: "after", in: text) == nil)
        #expect(Self.scope(of: "y=(", in: text) == "variable.other")
    }

    @Test(arguments: [
        String(repeating: "$(", count: 20_000), String(repeating: "{ ", count: 20_000), String(repeating: "( ", count: 20_000),
        String(repeating: "if a; then ", count: 10_000), String(repeating: "\"$(echo ", count: 10_000),
        String(repeating: "case a in a) ", count: 8_000), String(repeating: "while a; do ", count: 10_000),
        String(repeating: "f() { ", count: 10_000), String(repeating: "$((", count: 20_000), String(repeating: "<(", count: 20_000),
        String(repeating: "${a:-$(", count: 10_000), String(repeating: "x=(", count: 20_000), String(repeating: "a | ", count: 20_000),
        String(repeating: "a && ", count: 20_000), String(repeating: "`", count: 20_000), String(repeating: "cat <<E\n", count: 10_000)
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

    static let editPieces = ["{", "}", "(", ")", "((", "))", "$(", "`", "\"", "'", "\\", ";", ";;", "&&", "|", "\n", " ",
                             "if ", "then ", "fi", "do ", "done", "case ", "esac", "in ", "<<EOF\n", "EOF", "<<", "[[ ", " ]]",
                             "=", "x=", "-", "#", "$", "${", "f() ", "echo ", "🧋"]

    /// Random edits over every shell fixture: the incremental tree is always the whole parse's.
    @Test(arguments: shellFixtures)
    func incrementalEqualsFullOnRandomEdits(_ fixture: Fixture) throws {
        let text = try fixture.input()
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
                tree = result.tree
                if Bool.random(using: &rng) { _ = highlighter.applyRelexing(of: tree) }
            }
        }
    }

    @Test func anEditInAFunctionBodyReparsesOnlyThatBody() {
        let text = (0..<200).map { "f\($0)() {\n  local y=$1\n  echo \"$y\" | grep \($0)\n}\n" }.joined()
        var (highlighter, tree) = Self.tree(text)
        let at = (text as NSString).range(of: "grep 100").location
        let result = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: at, length: 4), "sed -n")
        #expect(result.isIncremental)
        #expect(result.changed.kind == ShellKind.braceGroup)
        #expect(result.steps * 50 < Self.parser.parse(highlighter.snapshot).steps, "a body's reparse costs the body, not the file")
    }

    @Test(arguments: [
        ("{ a; }", "a", ShellKind.braceGroup), ("( a )", "a", ShellKind.subshell), ("if a; then b; fi", "b", ShellKind.ifCommand),
        ("while a; do b; done", "b", ShellKind.whileCommand), ("for x in y; do b; done", "b", ShellKind.forCommand),
        ("case x in y) b;; esac", "b", ShellKind.caseCommand), ("echo $(a b)", "b", ShellKind.commandSubstitution)
    ])
    func blocksOfEveryBoundaryKindReparseAlone(_ block: String, _ marker: String, _ kind: SyntaxKind) {
        let text = "echo before\n\(block)\necho after\n"
        var (highlighter, tree) = Self.tree(text)
        let at = (text as NSString).range(of: marker, range: NSRange(location: 12, length: block.utf16.count))
        let result = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: NSMaxRange(at), length: 0), "z")
        #expect(result.isIncremental && result.changed.kind == kind, "\(block)")
    }

    @Test func editingAHeredocDelimiterFallsBack() {
        let text = "f() {\n  cat <<EOF\n  body }\nEOF\n}\necho after\n"
        var (highlighter, tree) = Self.tree(text)
        let at = (text as NSString).range(of: "<<EOF").location + 4
        let result = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: at, length: 1), "X")
        #expect(sameParse(result.tree, Self.parser.parse(highlighter.snapshot).tree))
        #expect(!result.isIncremental || result.changed.range.location == 0, "the body now runs past the function")
        // In the body itself, an edit stays inside the block.
        let body = (highlighter.text as NSString).range(of: "body").location
        let inside = ReparseTests.edit(highlighter, &tree, Self.parser, NSRange(location: body, length: 0), "more ")
        #expect(sameParse(inside.tree, Self.parser.parse(highlighter.snapshot).tree))
    }

    @Test func aBoundaryWaitingOnAHeredocIsNotOne() {
        let (_, tree) = Self.tree("cat <<EOF && {\nbody\nEOF\necho in; }\n`{ a; }`\n")
        let s = sExpression(tree.root)
        #expect(s.contains("braceGroupInContext({ heredocBody(body EOF)"))
        #expect(s.contains("backtickSubstitution(` braceGroupInContext("))
    }

    @MainActor @Test func aParseSessionKeepsAShellTree() async {
        let highlighter = Highlighter(grammar: Self.grammar, text: "f() {\n  echo a\n}\n")
        let session = ParseSession(highlighter: highlighter, parser: Self.parser)
        session.textDidChange()
        await session.waitUntilIdle()
        _ = highlighter.replaceCharacters(in: NSRange(location: 13, length: 1), with: "b done")
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(session.tree.map { leafText($0.root) } == highlighter.text)
        #expect(session.tree?.errors.isEmpty == true)
    }

    // MARK: Cost

    static let growing: [(String, @Sendable (Int) -> String)] = [
        ("tour", { String(repeating: ShellParserTests.tour, count: $0) }),
        ("keyword arguments", { String(repeating: "echo if then fi done esac in do\n", count: $0 * 20) }),
        ("long words", { String(repeating: "a-b-c-d-e-f-g-h=i-j-k ", count: $0 * 40) }),
        ("assignments", { String(repeating: "a[b[c[d]]]=x ", count: $0 * 40) }),
        ("heredocs", { String(repeating: "cat <<E <<F\nx $y\nE\nz\nF\n", count: $0 * 20) })
    ]

    /// Parser lookahead grows linearly with the file.
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
        ["shell/tour.input", "shell/parsed-commands.input", "shell/parsed-compound.input"].map {
            (try? String(contentsOf: Fixture.root.appendingPathComponent($0), encoding: .utf8)) ?? ""
        }.joined()
    }()

    @Test func largeFileBenchmark() {
        let text = String(repeating: Self.tour, count: 60)
        let clock = ContinuousClock()
        let highlighter = Highlighter(grammar: Self.grammar, text: text)
        var tree: SyntaxTree?
        let parse = clock.measure { tree = Self.parser.parse(highlighter.snapshot).tree }
        let queries = try! HighlightQueries.bundled("shell")
        let run = clock.measure { _ = queries.run(on: tree!) }
        print("benchmark: \(text.utf16.count / 1024) KB shell, parse \(parse), queries \(run)")
        #expect(tree!.errors.isEmpty)
    }
}
