import Foundation
import Testing
@testable import HighlightBoba

/// A tiny bracket-structured language over any grammar's tokens: `{ }` blocks and `[ ]` lists are
/// reparse boundaries, `( )` groups are not, `;` or a block ends a statement, and `a + b` nests
/// through a checkpoint, so blocks also sit under nodes started after them.
///
/// With `relexes`, it re-lexes the way a JS parser does, for `relexGrammar`: `/` after `return`
/// is a regex, and `quote {` turns the brace into a block comment, which can span lines.
struct ToyBlocks: IncrementalParser {
    static let block = SyntaxKind("block")
    static let list = SyntaxKind("list")
    static let group = SyntaxKind("group")
    static let statement = SyntaxKind("statement")
    static let binary = SyntaxKind("binary")
    static let closers: Set<String> = ["}", "]", ")"]

    var relexes = false
    var reparseBoundaries: Set<SyntaxKind> { [Self.block, Self.list] }

    func parse(_ builder: TreeBuilder) {
        while !builder.isAtEnd { statement(builder) }
    }

    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { item(builder) }

    private func statement(_ builder: TreeBuilder) {
        guard let token = builder.current else { return }
        if Self.closers.contains(builder.text(of: token)) {
            builder.errorAndBump("unexpected `\(builder.text(of: token))`")
            return
        }
        builder.startNode(Self.statement)
        while let token = builder.current, !builder.at(";"), !Self.closers.contains(builder.text(of: token)) {
            let block = builder.at("{")
            expression(builder)
            if block { break }
        }
        builder.bump(";")
        builder.finishNode()
    }

    private func expression(_ builder: TreeBuilder) {
        let start = builder.checkpoint()
        item(builder)
        while builder.at("+") {
            builder.startNode(Self.binary, at: start)
            builder.bump("+")
            if let token = builder.current, !Self.closers.contains(builder.text(of: token)), !builder.at(";") { item(builder) }
            builder.finishNode()
        }
    }

    private func item(_ builder: TreeBuilder) {
        guard builder.depth < 64 else {
            builder.errorAndBump("too deep")
            return
        }
        if builder.at("{") {
            bracketed(builder, Self.block, "{", "}")
        } else if builder.at("[") {
            bracketed(builder, Self.list, "[", "]")
        } else if builder.at("(") {
            bracketed(builder, Self.group, "(", ")")
        } else if let token = builder.current {
            let word = builder.text(of: token)
            builder.bump()
            if relexes && word == "return" && builder.at("/") { builder.relex(as: "regexStart") }
            if relexes && word == "quote" && builder.at("{") { builder.relex(as: "blockStart") }
        }
    }

    private func bracketed(_ builder: TreeBuilder, _ kind: SyntaxKind, _ open: String, _ close: String) {
        builder.startNode(kind)
        builder.bump(open)
        while let token = builder.current, !builder.at(close) {
            // A closer of an enclosing bracket ends this one too.
            if Self.closers.contains(builder.text(of: token)) { break }
            statement(builder)
        }
        builder.expect(close)
        builder.finishNode()
    }
}

extension ToyJSON {
    /// `ToyJSON` with objects and arrays as reparse boundaries.
    struct Incremental: IncrementalParser {
        var reparseBoundaries: Set<SyntaxKind> { [ToyJSON.object, ToyJSON.array] }
        func parse(_ builder: TreeBuilder) { while !builder.isAtEnd { ToyJSON.parseValue(builder) } }
        func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { ToyJSON.parseValue(builder) }
    }
}

/// Whether two trees are the same parse: tokens, nodes with everything a later reparse reads,
/// child lists, errors, re-lex requests and the lexing they leave. (`maxStall` is only a bound.)
func sameParse(_ a: SyntaxTree, _ b: SyntaxTree) -> Bool {
    a.units == b.units && a.tokens == b.tokens && a.nodes == b.nodes && a.children == b.children
        && a.errors == b.errors && a.relexLog == b.relexLog && a.revision == b.revision
        && a.lexing?.lines == b.lexing?.lines && a.lexing?.overrides == b.lexing?.overrides
}

/// The first difference between two trees, to say where a property test went wrong.
func firstDifference(_ a: SyntaxTree, _ b: SyntaxTree) -> String {
    if a.tokens != b.tokens { return "tokens" }
    if let i = a.nodes.indices.first(where: { $0 < b.nodes.count && a.nodes[$0] != b.nodes[$0] }) { return "node \(i): \(a.nodes[i]) vs \(b.nodes[i])" }
    if a.nodes.count != b.nodes.count { return "node count \(a.nodes.count) vs \(b.nodes.count)" }
    if a.children != b.children { return "children" }
    if a.errors != b.errors { return "errors \(a.errors) vs \(b.errors)" }
    if a.relexLog != b.relexLog { return "relex log \(a.relexLog) vs \(b.relexLog)" }
    if a.lexing?.overrides != b.lexing?.overrides { return "overrides" }
    if a.lexing?.lines != b.lexing?.lines { return "lexing" }
    return "revision"
}

@Suite struct ReparseTests {
    /// Edits `highlighter`, reparses `tree` incrementally, and checks it against a whole parse.
    @discardableResult
    static func edit(_ highlighter: Highlighter, _ tree: inout SyntaxTree, _ parser: some IncrementalParser,
                     _ range: NSRange, _ string: String, _ note: @autoclosure () -> String = "") -> Reparse {
        highlighter.replaceCharacters(in: range, with: string)
        let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision)!, in: highlighter.snapshot)
        let full = parser.parse(highlighter.snapshot)
        #expect(sameParse(result.tree, full.tree), "\(note()) \(firstDifference(result.tree, full.tree)) in \(highlighter.text.debugDescription)")
        #expect(leafText(result.tree.root) == highlighter.text)
        tree = result.tree
        return result
    }

    static func setUp(_ text: String, _ grammar: Grammar, _ parser: some IncrementalParser) -> (Highlighter, SyntaxTree) {
        let highlighter = Highlighter(grammar: grammar, text: text)
        return (highlighter, parser.parse(highlighter.snapshot).tree)
    }

    static func location(of text: String, in highlighter: Highlighter) -> Int {
        (highlighter.text as NSString).range(of: text).location
    }

    // MARK: The property

    static let pieces = ["{", "}", "[", "]", "(", ")", ";", "+", " ", "\n", "a", "bc", "return ", "/", "/x/", "#",
                         "quote ", "🧋", "é", "\r\n", "  ", "a", "bc", " ", ";", "x + y", "\n"]

    /// Nested blocks, lists and groups of statements, so most edits land inside some block.
    static func program(depth: Int, using rng: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...4, using: &rng)).map { _ in
            switch depth > 0 ? Int.random(in: 0..<6, using: &rng) : 5 {
            case 0, 1: "{\n" + program(depth: depth - 1, using: &rng) + "}\n"
            case 2: "[ " + program(depth: depth - 1, using: &rng) + " ];\n"
            case 3: "f ( " + program(depth: depth - 1, using: &rng) + " ) + 🧋;\n"
            case 4: "return /r/ + x; # note\n"
            default: ["a b;", "c + d;", "é x;", "quote y;"].randomElement(using: &rng)! + (Bool.random(using: &rng) ? "\n" : " ")
            }
        }.joined()
    }

    /// Random edits, some coalesced, with the highlighter taking the tree's re-lexing or not:
    /// the incremental tree is always the whole parse's.
    @Test(arguments: [false, true])
    func incrementalEqualsFullOnRandomEdits(_ relexes: Bool) {
        let parser = ToyBlocks(relexes: relexes)
        var incremental = 0
        var edits = 0
        for seed in UInt64(1)...60 {
            var rng = SeededGenerator(state: seed)
            let text = Self.program(depth: 4, using: &rng)
            var (highlighter, tree) = Self.setUp(text, relexGrammar, parser)
            for step in 0..<30 {
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let units = highlighter.units.count
                    let location = Int.random(in: 0...units, using: &rng)
                    let length = Int.random(in: 0...min(4, units - location), using: &rng)
                    let insert = Bool.random(using: &rng) ? IncrementalTests.randomText(Self.pieces, count: Int.random(in: 1...2, using: &rng), using: &rng) : ""
                    let safe = (highlighter.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
                    highlighter.replaceCharacters(in: safe, with: insert)
                }
                let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision) ?? TextEdit(range: NSRange(), replacementLength: 0),
                                            in: highlighter.snapshot)
                let full = parser.parse(highlighter.snapshot)
                guard sameParse(result.tree, full.tree) else {
                    Issue.record("seed \(seed) step \(step): \(firstDifference(result.tree, full.tree)) in \(highlighter.text.debugDescription)")
                    return
                }
                edits += 1
                if result.isIncremental { incremental += 1 }
                tree = result.tree
                if Bool.random(using: &rng) { _ = highlighter.applyRelexing(of: tree) }
            }
        }
        #expect(incremental * 6 > edits, "only \(incremental) of \(edits) reparses stayed in a block")
    }

    /// The same over every fixture, with each language's own lexer and the toy bracket parser, and the
    /// JSON fixtures with the toy JSON parser: real token streams, not just the toy grammar's.
    @Test(arguments: Fixture.all())
    func incrementalEqualsFullOnFixtures(_ fixture: Fixture) throws {
        let grammar = try Grammar.bundled(fixture.language)
        let text = try fixture.input()
        let pieces = ["{", "}", "[", "]", "(", ")", "\"", "x", " ", "\n", ":", ",", "🧋", "/*", "*/", "//", "'"]
        func run(_ parser: some IncrementalParser) {
            var rng = SeededGenerator(state: UInt64(text.utf16.count))
            var (highlighter, tree) = Self.setUp(text, grammar, parser)
            for step in 0..<40 {
                let units = highlighter.units.count
                let location = Int.random(in: 0...units, using: &rng)
                let length = Int.random(in: 0...min(3, units - location), using: &rng)
                let insert = Bool.random(using: &rng) ? pieces.randomElement(using: &rng)! : ""
                let safe = (highlighter.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
                highlighter.replaceCharacters(in: safe, with: insert)
                let result = parser.reparse(tree, after: highlighter.edit(since: tree.revision)!, in: highlighter.snapshot)
                let full = parser.parse(highlighter.snapshot)
                guard sameParse(result.tree, full.tree) else {
                    Issue.record("\(fixture.testDescription) step \(step): \(firstDifference(result.tree, full.tree))")
                    return
                }
                tree = result.tree
            }
        }
        run(ToyBlocks())
        if fixture.language == "json" { run(ToyJSON.Incremental()) }
    }

    // MARK: Where a reparse stops

    @Test func anEditInsideABlockReparsesOnlyThatBlock() {
        let parser = ToyBlocks()
        var (highlighter, tree) = Self.setUp("a;\n{ b; { c; d; } e; }\nf;", relexGrammar, parser)
        let at = Self.location(of: "d", in: highlighter)
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 1), "dd + x")
        #expect(result.isIncremental)
        #expect(result.changed.kind == ToyBlocks.block)
        #expect(result.changed.text == "{ c; dd + x; }", "the innermost block, in the new text")
        #expect(sExpression(tree.root) == "root(statement(a ;) statement(block({ statement(b ;) statement(block({ statement(c ;) statement(binary(dd + x) ;) })) statement(e ;) })) statement(f ;))")
        #expect(tree.root.childNodes.last!.range == (highlighter.text as NSString).range(of: "f;"))
    }

    @Test func editsAtABlocksEdgesGoToTheEnclosingBlock() {
        let parser = ToyBlocks()
        let text = "{ x; [ a b ] y; }"
        for (target, replacement) in [("[", "[["), ("[", "(["), ("]", "] "), ("]", ""), (" a", "a"), ("b ", "b")] {
            var (highlighter, tree) = Self.setUp(text, relexGrammar, parser)
            let at = Self.location(of: target, in: highlighter)
            let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: (target as NSString).length), replacement, target)
            if target == " a" || target == "b " {
                #expect(result.changed.kind == ToyBlocks.list, "trivia just inside the brackets is the list's")
            } else {
                #expect(result.changed.kind != ToyBlocks.list, "\(target) → \(replacement) touches the list's own bracket")
            }
        }
    }

    @Test func insertingBeforeOrAfterABlockIsNotThatBlocksEdit() {
        let parser = ToyBlocks()
        for (offset, string) in [(2, "z"), (7, "z"), (7, " + q")] {
            var (highlighter, tree) = Self.setUp("{ [ a ] }", relexGrammar, parser)
            let result = Self.edit(highlighter, &tree, parser, NSRange(location: offset, length: 0), string)
            #expect(result.changed.kind == ToyBlocks.block, "an insertion at \(offset) is outside the list")
        }
    }

    @Test func unbalancedBracketsThatEscapeTheBlockFallBack() {
        let parser = ToyBlocks()
        // A closer ends the list early; an opener of its own kind takes the list's `]` and reads past it.
        for insert in ["}", "]", ")", "[", "} {"] {
            var (highlighter, tree) = Self.setUp("a;\n{ b; [ c d ] e; }\n{ f; }", relexGrammar, parser)
            let at = Self.location(of: "d", in: highlighter)
            let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 0), insert, insert)
            #expect(result.changed.kind != ToyBlocks.list, "`\(insert)` unbalances the list, so it can't be reparsed alone")
        }
        // Recovery closes these at the list's `]`, so the list still parses alone, as a whole parse has it.
        for insert in ["{", "("] {
            var (highlighter, tree) = Self.setUp("a;\n{ b; [ c d ] e; }\n{ f; }", relexGrammar, parser)
            let at = Self.location(of: "d", in: highlighter)
            let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 0), insert, insert)
            #expect(result.changed.kind == ToyBlocks.list && tree.errors.map(\.message) == ["expected `\(insert == "{" ? "}" : ")")`"])
        }
    }

    @Test func balancedBracketsStayInTheBlock() {
        let parser = ToyBlocks()
        var (highlighter, tree) = Self.setUp("{ b; [ c d ] e; }", relexGrammar, parser)
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: Self.location(of: "d", in: highlighter), length: 0), "{ q } [ ] ")
        #expect(result.changed.kind == ToyBlocks.list)
    }

    @Test func emptyAndWholeTextEdits() {
        let parser = ToyBlocks()
        var (highlighter, tree) = Self.setUp("", relexGrammar, parser)
        #expect(tree.root.range == NSRange(location: 0, length: 0))
        Self.edit(highlighter, &tree, parser, NSRange(location: 0, length: 0), "{ a; }")
        Self.edit(highlighter, &tree, parser, NSRange(location: 3, length: 0), "b")
        Self.edit(highlighter, &tree, parser, NSRange(location: 0, length: highlighter.units.count), "")
        #expect(tree.nodes.count == 1 && tree.tokens.isEmpty)
        Self.edit(highlighter, &tree, parser, NSRange(location: 0, length: 0), "")
    }

    @Test func multiByteTextKeepsUTF16Offsets() {
        let parser = ToyBlocks()
        var (highlighter, tree) = Self.setUp("🧋 é;\n{ 👩‍👩‍👧 a; [ 🧋 b ] }\nz 🧋;", relexGrammar, parser)
        let at = Self.location(of: "b", in: highlighter)
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 1), "🧋🧋")
        #expect(result.changed.kind == ToyBlocks.list)
        #expect(result.changed.range == (highlighter.text as NSString).range(of: "[ 🧋 🧋🧋 ]"))
        let last = tree.root.childNodes.last!
        #expect(last.text == "z 🧋;" && last.range == (highlighter.text as NSString).range(of: "z 🧋;"), "nodes after the block moved by the edit's UTF-16 length")
        // Typing inside the emoji's block once more, from the spliced tree.
        let again = Self.edit(highlighter, &tree, parser, NSRange(location: Self.location(of: "a;", in: highlighter), length: 0), "é")
        #expect(again.changed.kind == ToyBlocks.block)
    }

    @Test func errorsInsideAndAfterTheBlockMove() {
        let parser = ToyBlocks()
        var (highlighter, tree) = Self.setUp("{ a ) }\n{ b; }\n)", relexGrammar, parser)
        #expect(tree.errors.map(\.message) == ["expected `}`", "unexpected `)`", "unexpected `}`", "unexpected `)`"])
        // An unclosed `(` inside the second block: its error is found inside it, the last one moves.
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: Self.location(of: "b", in: highlighter), length: 0), "( ")
        #expect(result.changed.kind == ToyBlocks.block)
        #expect(tree.errors.map(\.message) == ["expected `}`", "unexpected `)`", "unexpected `}`", "expected `)`", "unexpected `)`"])
        #expect(tree.errors.last?.range == NSRange(location: (highlighter.text as NSString).length - 1, length: 1))
    }

    @Test func lookaheadIntoABlockBeforeItStartsKeepsItFromBeingReparsedAlone() {
        /// Peeks two tokens into a block before parsing it, so the block depends on what precedes it.
        struct Peeking: IncrementalParser {
            var reparseBoundaries: Set<SyntaxKind> { [ToyBlocks.block] }
            func parse(_ builder: TreeBuilder) {
                while !builder.isAtEnd {
                    if builder.at("{"), builder.peek(1).map(builder.text(of:)) == "x" { builder.bump(); continue }
                    parseBlock(ToyBlocks.block, builder)
                }
            }
            func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) {
                guard builder.at("{") else { return builder.bump() }
                builder.startNode(ToyBlocks.block)
                builder.bump("{")
                while !builder.isAtEnd && !builder.at("}") { builder.bump() }
                builder.bump("}")
                builder.finishNode()
            }
        }
        var (highlighter, tree) = Self.setUp("{ a b }", relexGrammar, Peeking())
        let result = Self.edit(highlighter, &tree, Peeking(), NSRange(location: 2, length: 1), "x")
        #expect(!result.isIncremental)
        #expect(tree.root.childNodes.isEmpty, "with `x` second, the whole parse doesn't make a block")
    }

    // MARK: Re-lexing

    @Test func reLexingInsideABlockIsReparsedWithIt() {
        let parser = ToyBlocks(relexes: true)
        var (highlighter, tree) = Self.setUp("x / y;\n{ a; [ return /re/ ] }\nreturn /z/;", relexGrammar, parser)
        #expect(tree.lexing!.overrides.count == 2)
        let at = Self.location(of: "re/", in: highlighter)
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 2), "regex")
        #expect(result.changed.kind == ToyBlocks.list)
        #expect(tree.lexing!.overrides.count == 2)
        #expect(highlighter.applyRelexing(of: tree) != nil)
        #expect(scoped(highlighter).contains("/regex/:string.regexp"))
    }

    @Test func reLexingThatReachesPastTheBlockFallsBack() {
        let parser = ToyBlocks(relexes: true)
        var (highlighter, tree) = Self.setUp("[ a; b ]\nq;\n}", relexGrammar, parser)
        // `quote {` opens a block comment that runs to the `}` two lines down, past the list.
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: Self.location(of: "b", in: highlighter), length: 0), "quote {")
        #expect(!result.isIncremental)
    }

    // MARK: Work

    @Test func aOneLineEditCostsTheBlockNotTheFile() {
        let parser = ToyBlocks()
        let text = (0..<2_000).map { "f\($0) { a; [ b c ] ( d + e ); g; }" }.joined(separator: "\n")
        var (highlighter, tree) = Self.setUp(text, relexGrammar, parser)
        let full = parser.parse(highlighter.snapshot)
        let at = Self.location(of: "g; }\nf1001 ", in: highlighter)
        let result = Self.edit(highlighter, &tree, parser, NSRange(location: at, length: 1), "gg + h")
        #expect(result.isIncremental && result.changed.range.length < 40)
        let blockTokens = result.changed.tokens.count
        #expect(result.steps < 12 * blockTokens, "a \(blockTokens)-token block took \(result.steps) lookahead steps")
        #expect(result.steps * 1_000 < full.steps, "\(result.steps) steps against \(full.steps) for the whole file")
    }

    // MARK: Edits

    @Test func editsComposeIntoOne() {
        let highlighter = Highlighter(grammar: relexGrammar, text: "abcdefghij")
        let start = highlighter.revision
        highlighter.replaceCharacters(in: NSRange(location: 2, length: 2), with: "XYZ")   // abXYZefghij
        highlighter.replaceCharacters(in: NSRange(location: 8, length: 1), with: "")      // abXYZefgij
        highlighter.replaceCharacters(in: NSRange(location: 0, length: 1), with: "__")    // __bXYZefgij
        let edit = highlighter.edit(since: start)!
        #expect(edit == TextEdit(range: NSRange(location: 0, length: 8), replacementLength: 9), "abcdefgh became __bXYZefg")
        #expect(highlighter.edit(since: highlighter.revision) == nil)
        #expect(highlighter.edit(since: highlighter.revision + 1) == nil)
        for _ in 0...Highlighter.journalLimit { highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "") }
        #expect(highlighter.edit(since: start) == nil, "edits older than the journal are forgotten")
        #expect(highlighter.edit(since: highlighter.revision - 1) == TextEdit(range: NSRange(location: 0, length: 0), replacementLength: 0))
    }

    @Test func aTreeFromAnotherHighlighterIsReparsedWhole() {
        let parser = ToyBlocks()
        let one = Highlighter(grammar: relexGrammar, text: "{ a; }")
        let other = Highlighter(grammar: relexGrammar, text: "{ a; }")
        let tree = parser.parse(one.snapshot).tree
        other.replaceCharacters(in: NSRange(location: 3, length: 0), with: "b")
        let result = parser.reparse(tree, after: other.edit(since: 0)!, in: other.snapshot)
        #expect(!result.isIncremental && sameParse(result.tree, parser.parse(other.snapshot).tree))
    }
}
