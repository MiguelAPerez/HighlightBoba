import Foundation
import Testing
@testable import HighlightBoba

enum Python {
    static let grammar = try! Grammar.bundled("python")
    static let parser = PythonParser()

    static func parse(_ text: String) -> (Highlighter, SyntaxTree) {
        let highlighter = Highlighter(grammar: grammar, text: text)
        return (highlighter, parser.parse(highlighter.snapshot).tree)
    }

    /// The tree as nested lists, significant tokens as their text: `(call f (arguments ( x )))`.
    static func outline(_ node: SyntaxNode) -> String {
        let parts = node.children.compactMap { child -> String? in
            switch child {
            case .token(let token): token.isTrivia ? nil : node.tree.text(of: token)
            case .node(let inner): outline(inner)
            }
        }
        return "(" + ([node.kind.name] + parts).joined(separator: " ") + ")"
    }

    /// The outline of the tree's statements, without the `root` wrapper.
    static func outline(_ text: String) -> String {
        let (_, tree) = parse(text)
        return tree.root.childNodes.map(outline).joined(separator: " ")
    }

    static func errors(_ text: String) -> [String] { parse(text).1.errors.map(\.message) }

    /// What a user sees: the lexer's tokens, with the parse's re-lexing and the highlight queries applied.
    static func highlight(_ text: String) -> (tokens: [HighlightToken], tree: SyntaxTree) {
        let (highlighter, tree) = parse(text)
        _ = highlighter.applyRelexing(of: tree)
        let refinement = LanguageSupport.bundled(for: "python")!.queries.run(on: tree)
        return (highlighter.tokens(refinedBy: refinement)!, tree)
    }

    /// The scope each token with the given text gets, in order.
    static func scopes(of word: String, in text: String) -> [String?] {
        let tokens = highlight(text).tokens
        let units = Array(text.utf16)
        var result: [String?] = []
        var search = text.startIndex
        while let range = text.range(of: word, range: search..<text.endIndex) {
            let location = NSRange(range, in: text).location
            let match = tokens.first { $0.range.location == location && $0.range.length == word.utf16.count }
            // Only whole tokens: a word inside a longer identifier or a string has no token of its own.
            let before = location == 0 ? 32 : units[location - 1]
            if match != nil || !(before == 95 || (before >= 65 && before <= 122)) { result.append(match?.scope) }
            search = range.upperBound
        }
        return result
    }
}

@Suite struct PythonParserTests {
    /// `PY_DEBUG=<file> swift test --filter debugFile` prints a file's tree, errors and highlighting.
    @Test func debugFile() throws {
        guard let path = ProcessInfo.processInfo.environment["PY_DEBUG"] else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let (tokens, tree) = Python.highlight(text)
        for node in tree.root.childNodes { print(Python.outline(node)) }
        for error in tree.errors { print("error:", error.range.location, error.message) }
        print(CaretRenderer.render(text, tokens: tokens))
    }

    /// `PY_CORPUS=<dir> swift test --filter corpusParsesWithoutErrors` parses every `.py` file under
    /// a directory of valid code, such as CPython's standard library, and lists the files with errors.
    @Test func corpusParsesWithoutErrors() throws {
        guard let directory = ProcessInfo.processInfo.environment["PY_CORPUS"] else { return }
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory).filter { $0.hasSuffix(".py") }.sorted()
        var failing: [String] = []
        for file in files {
            guard let text = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) else { continue }
            let (_, tree) = Python.parse(text)
            guard let error = tree.errors.first else { continue }
            let line = (text as NSString).substring(to: error.range.location).components(separatedBy: "\n").count
            failing.append("\(file):\(line): \(error.message)")
        }
        print("corpus: \(failing.count) of \(files.count) files with errors\n" + failing.joined(separator: "\n"))
    }

    // MARK: Shapes

    /// Shapes checked against CPython 3.14's `ast` for grouping (precedence, what binds to what).
    static let shapes: [(String, String)] = [
        ("a or b and not c == d | e ^ f & g << h + i * -j ** k",
         "(expression_statement (binary a or (binary b and (unary not (binary c = = (binary d | (binary e ^ (binary f & (binary g < < (binary h + (binary i * (unary - (binary j * * k)))))))))))))"),
        ("x = a if b else c if d else e", "(assignment (target x) = (conditional a if b else (conditional c if d else e)))"),
        ("-x ** 2", "(expression_statement (unary - (binary x * * 2)))"),
        ("2 ** -1", "(expression_statement (binary 2 * * (unary - 1)))"),
        ("a < b < c", "(expression_statement (binary (binary a < b) < c))"),
        ("a not in b is not c", "(expression_statement (binary (binary a not in b) is not c))"),
        ("f = lambda x, *a, k=1, **kw: x", "(assignment (target f) = (lambda lambda (parameters (parameter x) , (parameter * a) , (parameter k = (default 1)) , (parameter * * kw)) : x))"),
        ("[y for x in xs if x for y in x]", "(expression_statement (list [ y (for_clause for (target x) in xs) (if_clause if x) (for_clause for (target y) in x) ]))"),
        ("f(*a, **k, key=v)", "(expression_statement (call f (arguments ( (starred * a) , (starred * * k) , (keyword_argument key = v) ))))"),
        ("f(x for x in y)", "(expression_statement (call f (arguments ( (generator x (for_clause for (target x) in y)) ))))"),
        ("if (n := 10) > 5: pass", "(if_statement if (binary (parenthesized ( (named_expression (target n) : = 10) )) > 5) : (keyword_statement pass))"),
        ("a[1:2, ::3, *b]", "(expression_statement (subscript a [ (slice 1 : 2) , (slice : : 3) , (starred * b) ]))"),
        ("x: list[int] = []", "(assignment (target x) : (annotation (subscript list [ int ])) = (list [ ]))"),
        ("a = b = c", "(assignment (target a) = (target b) = c)"),
        ("a, *b = c", "(assignment (target (tuple a , (starred * b))) = c)"),
        ("x += yield", "(assignment (target x) + = (yield yield))"),
        ("type T[K: int = str, *Ts, **P] = dict[K, int]",
         "(type_alias type T (type_parameters [ (type_parameter K : (annotation int) = (annotation str)) , (type_parameter * Ts) , (type_parameter * * P) ]) = (annotation (subscript dict [ K , int ])))"),
        ("with (open(a) as f, b as g): pass", "(with_statement with ( (with_item (call open (arguments ( a ))) as (target f)) , (with_item b as (target g)) ) : (keyword_statement pass))"),
        ("with (a, b) as c: pass", "(with_statement with (with_item (tuple ( a , b )) as (target c)) : (keyword_statement pass))"),
        ("global a, b; nonlocal c", "(keyword_statement global a , b) (keyword_statement nonlocal c)"),
        ("from .. import (a as b, c)", "(import_from from . . import ( a as (target b) , c ))"),
        ("x = f'{a!r:>{w}}'", "(assignment (target x) = (string f' (fstring_field { a ! r (format_spec : > (fstring_field { w })) }) '))"),
        ("@a.b(c)\nclass C[T](D, metaclass=M): pass",
         "(decorated (decorator (call @a.b (arguments ( c )))) (class class C (type_parameters [ (type_parameter T) ]) (arguments ( D , (keyword_argument metaclass = M) )) : (keyword_statement pass)))"),
        ("try:\n    pass\nexcept* E as e:\n    pass\nelse:\n    pass\nfinally:\n    pass",
         "(try_statement try : (block (keyword_statement pass)) (except_clause except * E as (target e) : (block (keyword_statement pass))) (else_clause else : (block (keyword_statement pass))) (finally_clause finally : (block (keyword_statement pass))))"),
        ("match p:\n    case Point(x=0) | [1, *_] as q if q:\n        pass",
         "(match_statement match p : (case_block (case_clause case (case_pattern (as_pattern (or_pattern (class_pattern (value_pattern Point) ( (keyword_pattern x = (value_pattern 0)) )) | (sequence_pattern [ (value_pattern 1) , (starred * _) ])) as (target q))) (guard if q) : (block (keyword_statement pass)))))"),
        ("match x:\n    case {'k': v, **rest}: pass\n    case -1 | 1+2j | a.b: pass",
         "(match_statement match x : (case_block (case_clause case (case_pattern (mapping_pattern { (pair (value_pattern (string 'k')) : v) , (starred * * rest) })) : (keyword_statement pass)) (case_clause case (case_pattern (or_pattern (value_pattern - 1) | (value_pattern 1 + 2j) | (value_pattern a . b))) : (keyword_statement pass))))"),
        ("async def f():\n    async with a: await b\n    return [x async for x in y]",
         "(function async def f (parameters ( )) : (block (with_statement async with (with_item a) : (expression_statement (await await b))) (keyword_statement return (list [ x (for_clause async for (target x) in y) ]))))")
    ]

    @Test(arguments: shapes.indices)
    func parsesTheShapeCPythonDoes(_ index: Int) {
        let (text, expected) = Self.shapes[index]
        #expect(Python.outline(text) == expected, "\(text)")
        #expect(Python.errors(text).isEmpty, "\(text): \(Python.errors(text))")
    }

    // MARK: Soft keywords

    @Test func softKeywordsAreKeywordsOnlyWhereTheyStartAStatementOrPattern() {
        // The lexer reads all of these `match`es as keywords: only the last starts a match statement.
        #expect(Python.scopes(of: "match", in: "match (x)\nmatch [x]\nmatch not in xs\nmatch (x):\n    case 1: pass\n")
                == [nil, nil, nil, "keyword"])
        #expect(Python.scopes(of: "case", in: "case not in xs\nmatch x:\n    case case: pass\n") == [nil, "keyword", nil])
        #expect(Python.scopes(of: "type", in: "type Σ = int\ntype(x)\ntype = 1\nx.type\n")
                == ["keyword", "support.function", "variable.other", nil])
        #expect(Python.scopes(of: "_", in: "match x:\n    case [_, Color._] if _: _ = _\n") == ["keyword", nil, nil, nil, nil])
    }

    /// A header too long to scan to its end (past 2048 tokens) is still decided: `match` as the lexer
    /// read it at the start of the line, `with (` as parenthesized items. (So a call `match(…)` that
    /// long reads as a match statement, as the lexer alone reads it.)
    @Test func headersTooLongToScanAreStillDecided() {
        let subject = String(repeating: "a + ", count: 2500) + "b"
        let match = "match " + subject + ":\n    case 1:\n        pass\n"
        // The subject nests 2500 deep, too deep for the recursive `outline`.
        let (_, tree) = Python.parse(match)
        let statement = tree.root.childNodes.first
        #expect(statement?.kind.name == "match_statement")
        #expect(statement?.childNodes.last?.kind.name == "case_block")
        #expect(tree.errors.isEmpty)
        let items = "with (" + (0..<1200).map { "a\($0) as b\($0)" }.joined(separator: ", ") + "):\n    pass\n"
        #expect(Python.outline(items).hasPrefix("(with_statement with ( (with_item"))
        #expect(Python.errors(items).isEmpty)
    }

    // MARK: Lines and indentation

    @Test func bracketsAndBackslashesJoinLinesAndBlankLinesDontCount() {
        let text = """
        def f(a,
        b):
            x = (1 +
          2)

            # comment at column 0 below
        # here
            y = 1 + \\
        2
            return x
        z = 3
        """
        #expect(Python.errors(text).isEmpty, "\(Python.errors(text))")
        #expect(Python.outline(text) == """
            (function def f (parameters ( (parameter a) , (parameter b) )) : (block (assignment (target x) = (parenthesized ( (binary 1 + 2) ))) (assignment (target y) = (binary 1 + \\ 2)) (keyword_statement return x))) (assignment (target z) = 3)
            """)
    }

    @Test func tabsIndentToTheNextMultipleOfEight() {
        // A tab is 8 columns: the `\t` line is in the block opened by the 8-space line, not deeper.
        #expect(Python.errors("if a:\n        if b:\n\t\tc\n\td\n").isEmpty)
        #expect(Python.outline("if a:\n        b\n\tc\n") == "(if_statement if a : (block (expression_statement b) (expression_statement c)))")
    }

    @Test func badIndentationIsReportedAndStillParsed() {
        #expect(Python.errors("a\n    b\n") == ["unexpected indent"])
        #expect(Python.errors("if a:\n    b\n  c\n") == ["unexpected indent"])
        #expect(Python.errors("if a:\nb\n") == ["expected an indented block"])
        #expect(Python.outline("if a:\n    b\n  c\n") == "(if_statement if a : (block (expression_statement b))) (expression_statement c)")
    }

    @Test func aMultiLineStringDoesNotEndTheLogicalLine() {
        #expect(Python.errors("x = \"\"\"\nnot: code\n\"\"\" + y\nif x:\n    pass\n").isEmpty)
        #expect(Python.errors("t = f\"\"\"{\n    a +\nb\n}\"\"\"\n").isEmpty)
    }

    // MARK: Recovery

    @Test func aHalfTypedBlockStillHighlightsWhatFollows() {
        for broken in ["def f(a, b\n", "def f(a)\n", "if x\n", "x = g(1, 2\n", "class C(:\n", "y = [1,\n", "z = {\n"] {
            let text = broken + "    pass\ndef g(self, list):\n    return list\n"
            let (tokens, tree) = Python.highlight(text)
            #expect(!tree.errors.isEmpty, "\(broken.debugDescription) reported no error")
            #expect(leafText(tree.root) == text)
            func scope(of word: String) -> String? {
                let location = (text as NSString).range(of: word, options: .backwards).location
                return tokens.first { $0.range.location == location }?.scope
            }
            #expect(scope(of: "g(") == "entity.name.function", "\(broken.debugDescription)")
            #expect(scope(of: "list)") == "variable.parameter", "\(broken.debugDescription)")
        }
    }

    @Test func deepInputCostsNoStack() {
        for text in [String(repeating: "(", count: 60_000), String(repeating: "-", count: 60_000) + "x",
                     String(repeating: "not ", count: 50_000), String(repeating: "lambda: ", count: 30_000),
                     String(repeating: "[{", count: 50_000), String(repeating: "x if y else ", count: 20_000) + "z",
                     String(repeating: "yield ", count: 30_000), "case " + String(repeating: "[", count: 50_000),
                     (0..<600).map { String(repeating: " ", count: $0) + "if x:\n" }.joined() + "    pass\n"] {
            let (_, tree) = Python.parse(text)
            #expect(leafText(tree.root) == text)
        }
    }

    // MARK: Block reparses at the edges

    @Test func indentationEditsAtABlockEdgeReparseTheBlockAroundIt() {
        let parser = PythonParser()
        let text = "def f():\n    a = 1\n    if a:\n        b = 2\n        c = 3\n    d = 4\ne = 5\n"
        func run(_ find: String, _ length: Int, _ replacement: String, incremental: Bool) {
            var (highlighter, tree) = ReparseTests.setUp(text, Python.grammar, parser)
            let at = ReparseTests.location(of: find, in: highlighter)
            let result = ReparseTests.edit(highlighter, &tree, parser, NSRange(location: at, length: length), replacement, find)
            #expect(result.isIncremental == incremental, "\(find.debugDescription) → \(replacement.debugDescription)")
        }
        run("b = 2", 1, "bb", incremental: true)            // inside the inner block
        run("        c", 2, "", incremental: true)            // the inner block's last line leaves it: the outer block has it
        run("        b", 4, "", incremental: true)            // the inner block's first line: the outer block reparses
        run("    a", 2, "", incremental: false)               // the outer block's first line: the whole file
        run("e = 5", 0, "    ", incremental: false)           // indenting the line after the block joins it
        run("    d", 0, "    ", incremental: true)            // the last line of the outer block moves into the inner one
    }
}

extension PythonParserTests {
    @Test func queriesUseOnlyVocabularyScopes() throws {
        for query in try HighlightQueries.bundled("python").queries {
            #expect(Scopes.vocabulary.contains(query.scope), "python queries use \(query.scope)")
        }
    }
}
