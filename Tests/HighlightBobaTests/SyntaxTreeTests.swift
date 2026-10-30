import Foundation
import Testing
@testable import HighlightBoba

/// A toy JSON parser, the shape every real parser takes: recursive descent over `TreeBuilder`.
enum ToyJSON {
    static let object = SyntaxKind("object")
    static let array = SyntaxKind("array")
    static let member = SyntaxKind("member")
    static let value = SyntaxKind("value")

    static func parse(_ text: String) throws -> SyntaxTree {
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("json"), text: text))
        while !builder.isAtEnd { parseValue(builder) }
        return builder.finish()
    }

    static func parseValue(_ builder: TreeBuilder) {
        if builder.at("{") {
            builder.startNode(object)
            builder.bump("{")
            while !builder.isAtEnd && !builder.at("}") {
                builder.startNode(member)
                builder.bump()
                builder.bump(":")
                if !builder.at(",") && !builder.at("}") { parseValue(builder) }
                builder.finishNode()
                builder.bump(",")
            }
            builder.bump("}")
            builder.finishNode()
        } else if builder.at("[") {
            builder.startNode(array)
            builder.bump("[")
            while !builder.isAtEnd && !builder.at("]") {
                parseValue(builder)
                builder.bump(",")
            }
            builder.bump("]")
            builder.finishNode()
        } else {
            builder.startNode(value)
            builder.bump()
            builder.finishNode()
        }
    }
}

/// Precedence climbing with checkpoints, over the JavaScript lexer: `a - b - c` must nest left.
enum ToyExpression {
    static let binary = SyntaxKind("binary")
    static let atom = SyntaxKind("atom")
    static let precedence: [String: Int] = ["+": 1, "-": 1, "*": 2, "/": 2, "**": 3]

    static func parse(_ text: String) throws -> SyntaxTree {
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("javascript"), text: text))
        parse(builder, minimum: 1)
        return builder.finish()
    }

    static func parse(_ builder: TreeBuilder, minimum: Int) {
        let start = builder.checkpoint()
        builder.startNode(atom)
        builder.bump()
        builder.finishNode()
        while let op = ["**", "+", "-", "*", "/"].first(where: { builder.at($0) }), let level = precedence[op], level >= minimum {
            builder.startNode(binary, at: start)
            builder.bump(op)
            parse(builder, minimum: op == "**" ? level : level + 1)
            builder.finishNode()
        }
    }
}

/// `kind(child child …)` with tokens as their text, trivia left out: a compact shape to assert on.
func sExpression(_ node: SyntaxNode) -> String {
    let parts = node.children.compactMap { child -> String? in
        switch child {
        case .node(let inner): sExpression(inner)
        case .token(let token): token.isTrivia ? nil : node.tree.text(of: token)
        }
    }
    return "\(node.kind)(\(parts.joined(separator: " ")))"
}

/// Concatenates every leaf in tree order: must give back the text.
func leafText(_ node: SyntaxNode) -> String { node.tokens.map(node.tree.text(of:)).joined() }

@Suite struct SyntaxTokenTests {
    static func tokens(_ text: String, _ language: String) throws -> [(SyntaxToken.Kind, String, String?)] {
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        return highlighter.syntaxTokens.map { token in
            (token.kind, String(decoding: Array(text.utf16)[token.location..<token.end], as: UTF16.self), token.scope)
        }
    }

    /// Every fixture in every language: the tokens tile the text exactly, none empty, none overlapping.
    @Test(arguments: Fixture.all())
    func tokensTileTheText(_ fixture: Fixture) throws {
        let text = try fixture.input()
        let highlighter = Highlighter(grammar: try Grammar.bundled(fixture.language), text: text)
        var position = 0
        for token in highlighter.syntaxTokens {
            #expect(token.location == position, "gap or overlap at \(position) in \(fixture.testDescription)")
            #expect(token.length > 0)
            position = token.end
        }
        #expect(position == text.utf16.count)
    }

    @Test func gapsSplitIntoWordsSymbolsSpacesAndNewlines() throws {
        let tokens = try Self.tokens("let x1 = a->b // note\r\n", "swift")
        #expect(tokens.map(\.0) == [.lexeme, .space, .word, .space, .symbol, .space, .word, .symbol, .symbol, .word,
                                    .space, .lexeme, .newline])
        #expect(tokens.map(\.1) == ["let", " ", "x1", " ", "=", " ", "a", "-", ">", "b", " ", "// note", "\r\n"])
        #expect(tokens[0].2 == "keyword")
        #expect(tokens[11].2 == "comment.line")
    }

    @Test func mergedPunctuationIsSplitPerCharacter() throws {
        let tokens = try Self.tokens("[[1]],", "json")
        #expect(tokens.map(\.1) == ["[", "[", "1", "]", "]", ","])
        #expect(tokens.allSatisfy { $0.0 == .lexeme })
    }

    @Test func nonASCIIStaysInWordsAndSurrogatePairsStayWhole() throws {
        let tokens = try Self.tokens("café🧋x + é", "python")
        #expect(tokens.map(\.1) == ["café🧋x", " ", "+", " ", "é"])
        #expect(tokens[0].0 == .word)
    }

    @Test func triviaIsSpaceNewlineAndComments() throws {
        let tokens = try Self.tokens("a /* c */\n# x", "javascript")
        let highlighter = Highlighter(grammar: try Grammar.bundled("javascript"), text: "a /* c */\n")
        #expect(highlighter.syntaxTokens.map(\.isTrivia) == [false, true, true, true])
        #expect(tokens.count > 0)
    }

    @Test func emptyTextHasNoTokens() throws {
        #expect(try Self.tokens("", "swift").isEmpty)
    }

    /// The stream follows edits: same tokens as a fresh highlighter after each one.
    @Test func tokensFollowEdits() throws {
        let grammar = try Grammar.bundled("swift")
        let highlighter = Highlighter(grammar: grammar, text: "let a = \"x\"\nlet b = 2\n")
        for (range, insert) in [(NSRange(location: 9, length: 0), "\\("), (NSRange(location: 0, length: 3), "var"),
                                (NSRange(location: 4, length: 8), ""), (NSRange(location: 0, length: 0), "/* ")] {
            highlighter.replaceCharacters(in: range, with: insert)
            #expect(highlighter.syntaxTokens == Highlighter(grammar: grammar, text: highlighter.text).syntaxTokens)
        }
    }
}

@Suite struct SyntaxTreeTests {
    @Test func toyJSONBuildsNestedNodes() throws {
        let text = #"{"a": [1, true], "b": {}}"#
        let tree = try ToyJSON.parse(text)
        #expect(sExpression(tree.root) == #"root(object({ member("a" : array([ value(1) , value(true) ])) , member("b" : object({ })) }))"#)
        #expect(leafText(tree.root) == text)
        #expect(tree.root.range == NSRange(location: 0, length: text.utf16.count))
    }

    @Test func triviaGoesToTheEnclosingNodeAndNodesStartAtTheirFirstToken() throws {
        let text = "  [ 1 ,\n 2 ]  "
        let tree = try ToyJSON.parse(text)
        let array = try #require(tree.root.childNodes.first)
        #expect(array.range == NSRange(location: 2, length: 10), "the array starts at [ and ends at ]")
        #expect(tree.root.children.first == .token(SyntaxToken(kind: .space, location: 0, length: 2)))
        let values = array.childNodes
        #expect(values.map(\.text) == ["1", "2"])
        #expect(values.allSatisfy { $0.parent == array })
        #expect(leafText(tree.root) == text)
    }

    @Test func checkpointsNestLeftAssociativeAndRightAssociativeOperators() throws {
        let tree = try ToyExpression.parse("a - b - c * d ** e ** f")
        // `**` is two adjacent `*` tokens, which sExpression prints apart.
        #expect(sExpression(tree.root) ==
                "root(binary(binary(atom(a) - atom(b)) - binary(atom(c) * binary(atom(d) * * binary(atom(e) * * atom(f))))))")
    }

    @Test func multiCharacterOperatorsMatchOnlyWhenAdjacent() throws {
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("javascript"), text: "a === b = == c"))
        builder.bump()
        #expect(builder.at("==="))
        #expect(builder.at("=="))
        #expect(!builder.at("===="))
        #expect(builder.bump("==="))
        builder.bump()
        #expect(builder.at("="))
        #expect(!builder.at("= =="), "trivia between tokens never spells an operator")
        #expect(!builder.at("=="), "`=` then a space then `==` is not `==`")
        #expect(!builder.at(""))
        _ = builder.finish()
    }

    @Test func peekSkipsTrivia() throws {
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("swift"), text: "let // c\n  x"))
        #expect(builder.peek(0).map(builder.text(of:)) == "let")
        #expect(builder.peek(1).map(builder.text(of:)) == "x")
        #expect(builder.peek(2) == nil)
        #expect(builder.at(scope: "keyword"))
        _ = builder.finish()
    }

    @Test func finishKeepsWhatTheParserNeverConsumed() throws {
        let text = "[1] trailing, junk }"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("json"), text: text))
        ToyJSON.parseValue(builder)
        let tree = builder.finish()
        #expect(leafText(tree.root) == text)
        #expect(tree.root.childNodes.count == 1)
    }

    @Test func emptyTextAndEmptyNodes() throws {
        let empty = try ToyJSON.parse("")
        #expect(empty.root.children.isEmpty)
        #expect(empty.root.range == NSRange(location: 0, length: 0))

        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled("json"), text: "  1"))
        builder.startNode(ToyJSON.value)
        builder.finishNode()
        builder.bump()
        let tree = builder.finish()
        let node = try #require(tree.root.childNodes.first)
        #expect(node.range == NSRange(location: 2, length: 0), "an empty node sits where it was started, after the trivia")
        #expect(node.children.isEmpty)
        #expect(leafText(tree.root) == "  1")
    }

    /// Every fixture of every language through the toy JSON parser's generic walk: whatever the
    /// parse, the leaves give back the text.
    @Test(arguments: Fixture.all())
    func anyParseIsLossless(_ fixture: Fixture) throws {
        let text = try fixture.input()
        let builder = TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled(fixture.language), text: text))
        while !builder.isAtEnd { ToyJSON.parseValue(builder) }
        let tree = builder.finish()
        #expect(leafText(tree.root) == text)
        #expect(tree.text == text)
    }

    @Test func nodesAreHashableHandles() throws {
        let tree = try ToyJSON.parse("[1, 2]")
        let array = try #require(tree.root.childNodes.first)
        #expect(Set(array.childNodes).count == 2)
        #expect(array.childNodes[0].parent == array)
        #expect(tree.root.parent == nil)
        let other = try ToyJSON.parse("[1, 2]")
        #expect(other.root != tree.root, "same shape in another tree is a different node")
    }
}

@Suite struct TreeBuilderContractTests {
    static func builder(_ text: String, _ language: String = "json") throws -> TreeBuilder {
        TreeBuilder(highlighter: Highlighter(grammar: try Grammar.bundled(language), text: text))
    }

    /// Taking a checkpoint and never using it must not change the tree: trailing trivia stays outside the node.
    @Test func anUnusedCheckpointLeavesTrailingTriviaOutside() throws {
        let builder = try Self.builder("1 /* c */ \n2", "javascript")
        builder.startNode(SyntaxKind("a"))
        builder.bump()
        _ = builder.checkpoint()
        builder.finishNode()
        builder.startNode(SyntaxKind("b"))
        builder.bump()
        builder.finishNode()
        let tree = builder.finish()
        let nodes = tree.root.childNodes
        #expect(nodes.map(\.text) == ["1", "2"])
        #expect(nodes[0].range == NSRange(location: 0, length: 1))
        #expect(leafText(tree.root) == "1 /* c */ \n2")
    }

    /// The same, with the checkpoint used on nothing: the wrapper is empty and the trivia stays pending.
    @Test func aCheckpointWrappingNothingIsEmptyAndKeepsTriviaOutside() throws {
        let builder = try Self.builder("  1")
        let start = builder.checkpoint()
        builder.startNode(SyntaxKind("w"), at: start)
        builder.finishNode()
        builder.bump()
        let tree = builder.finish()
        let wrapper = try #require(tree.root.childNodes.first)
        #expect(wrapper.range == NSRange(location: 2, length: 0))
        #expect(wrapper.children.isEmpty)
        #expect(leafText(tree.root) == "  1")
    }

    /// Trivia inside a wrapped run stays inside; trivia in front of the checkpoint stays outside.
    @Test func aWrapperStartsAtTheFirstSignificantTokenAfterTheCheckpoint() throws {
        let builder = try Self.builder("[ /* c */ 1 , 2 ]", "javascript")
        builder.startNode(SyntaxKind("array"))
        builder.bump("[")
        let start = builder.checkpoint()
        builder.bump()
        builder.bump(",")
        builder.bump()
        builder.startNode(SyntaxKind("wrap"), at: start)
        builder.finishNode()
        builder.bump("]")
        builder.finishNode()
        let tree = builder.finish()
        let wrap = try #require(tree.root.childNodes.first?.childNodes.first)
        #expect(wrap.text == "1 , 2")
        #expect(wrap.range == NSRange(location: 10, length: 5))
        #expect(wrap.children.first.map { if case .token(let token) = $0 { !token.isTrivia } else { false } } == true)
        #expect(leafText(tree.root) == "[ /* c */ 1 , 2 ]")
    }

    /// Nested checkpoints, used inner first and then outer, keep parents, ranges and order right.
    @Test func nestedCheckpointsWrapInOrder() throws {
        let builder = try Self.builder("1 2 3")
        let outer = builder.checkpoint()
        let inner = builder.checkpoint()
        builder.bump()
        builder.bump()
        builder.startNode(SyntaxKind("inner"), at: inner)
        builder.finishNode()
        builder.bump()
        builder.startNode(SyntaxKind("outer"), at: outer)
        builder.finishNode()
        let tree = builder.finish()
        let outerNode = try #require(tree.root.childNodes.first)
        let innerNode = try #require(outerNode.childNodes.first)
        #expect(outerNode.kind == SyntaxKind("outer") && outerNode.text == "1 2 3")
        #expect(innerNode.kind == SyntaxKind("inner") && innerNode.text == "1 2")
        #expect(innerNode.parent == outerNode && outerNode.parent == tree.root)
        #expect(leafText(tree.root) == "1 2 3")
    }

    /// `finish()` when the parser consumed nothing keeps the whole text in the root.
    @Test func finishWithNothingConsumedKeepsEverything() throws {
        let text = "  // c\n 1 2 "
        let tree = try Self.builder(text).finish()
        #expect(leafText(tree.root) == text)
        #expect(tree.root.range == NSRange(location: 0, length: text.utf16.count))
        #expect(tree.root.children.count == tree.tokens.count)
    }

    /// Every node's range is the span of its own tokens, whatever the builder calls were.
    @Test func everyNodeRangeMatchesItsTokens() throws {
        let tree = try ToyExpression.parse("a - /* x */ b -\n c * d ** e ** f ")
        func check(_ node: SyntaxNode) {
            let tokens = node.tokens
            if let first = tokens.first, let last = tokens.last, node.kind != .root {
                #expect(node.range == NSRange(location: first.location, length: last.end - first.location))
                #expect(!first.isTrivia, "a node starts at a significant token")
            }
            for child in node.childNodes {
                #expect(child.parent == node)
                check(child)
            }
        }
        check(tree.root)
    }

    /// Looking ahead over long runs of trivia and many tokens stays linear.
    /// Asserted on the builder's work counter, not wall time, so it never flakes on a busy runner.
    @Test func lookaheadIsLinear() throws {
        let comments = String(repeating: "// c\n", count: 30_000) + "a"
        let builder = try Self.builder(comments, "javascript")
        builder.stallLimit = .max
        for _ in 0..<30_000 { #expect(builder.at("a")) }
        #expect(builder.lookaheadSteps <= 2 * 30_000, "30k `at` calls behind 60k trivia tokens took \(builder.lookaheadSteps) steps")

        let words = try Self.builder(String(repeating: "a ", count: 30_000), "javascript")
        words.stallLimit = .max
        var offset = 0
        while words.peek(offset) != nil { offset += 1 }
        #expect(offset == 30_000)
        #expect(words.lookaheadSteps <= 30_001, "peek(n) for every n took \(words.lookaheadSteps) steps")
        _ = builder.finish()
        _ = words.finish()
    }

    @Test func deepTreesWalkWithoutRecursion() throws {
        let depth = 200_000
        let builder = try Self.builder(String(repeating: "[", count: depth))
        for _ in 0..<depth {
            builder.startNode(SyntaxKind("n"))
            builder.bump()
        }
        for _ in 0..<depth { builder.finishNode() }
        let tree = builder.finish()
        #expect(tree.root.tokens.count == depth)
    }
}

@Suite struct SyntaxTokenEdgeTests {
    private func assertTiles(_ highlighter: Highlighter, _ note: String) {
        var position = 0
        for token in highlighter.syntaxTokens {
            #expect(token.location == position && token.length > 0, "\(note): gap, overlap or empty token at \(position)")
            position = token.end
        }
        #expect(position == highlighter.text.utf16.count, "\(note): short")
    }

    /// Embedded grammars, lone `\r`, and `\r\n` joined or split by an edit all keep the tiling and match a fresh stream.
    @Test func embeddedGrammarsAndLineBreaksTileThroughEdits() throws {
        let grammar = try Grammar.bundled("markdown")
        let highlighter = Highlighter(grammar: grammar, text: "# t\r```swift\rlet x = \"🧋\" // c\r\n```\nend")
        assertTiles(highlighter, "fresh")
        for (range, insert) in [(NSRange(location: 4, length: 0), "\n"), (NSRange(location: 4, length: 1), ""),
                                (NSRange(location: 0, length: 0), "\r"), (NSRange(location: 1, length: 0), "\n"),
                                (NSRange(location: 20, length: 3), "🧋🧋"), (NSRange(location: 0, length: 40), "")] {
            let end = highlighter.text.utf16.count
            highlighter.replaceCharacters(in: NSRange(location: min(range.location, end), length: min(range.length, end - min(range.location, end))), with: insert)
            assertTiles(highlighter, "after inserting \(insert.debugDescription)")
            #expect(highlighter.syntaxTokens == Highlighter(grammar: grammar, text: highlighter.text).syntaxTokens)
        }
    }

    /// A punctuation lexeme holding a surrogate pair is split per character, never mid-pair.
    @Test func punctuationSplitKeepsSurrogatePairsWhole() throws {
        let highlighter = Highlighter(grammar: try Grammar.bundled("json"), text: "[🧋,]")
        assertTiles(highlighter, "json")
        let units = Array(highlighter.text.utf16)
        for token in highlighter.syntaxTokens where token.length == 1 {
            #expect(!UTF16.isLeadSurrogate(units[token.location]) && !UTF16.isTrailSurrogate(units[token.location]))
        }
    }
}
