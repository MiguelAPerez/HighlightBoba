import Foundation
import Testing
@testable import HighlightBoba

/// A grammar that guesses JS-style: `/` after a word or `)` is division, anywhere else a regex.
/// `regexStart`, `divide`, `greater`, `blockStart` and `nestStart` exist only for the parser to re-lex with.
let relexGrammar: Grammar = {
    let json = #"""
    {
      "name": "relex",
      "initial": "code",
      "states": {
        "code": { "rules": [
          { "match": { "literal": "#" }, "scope": "comment.line", "push": "comment" },
          { "match": { "literal": "/" }, "scope": "string.regexp", "push": "regex", "notAfter": "[A-Za-z0-9_)]" },
          { "match": { "literal": "=>" }, "scope": "punctuation" },
          { "match": { "class": "[;,()]" }, "scope": "punctuation" }
        ] },
        "greater": { "rules": [ { "match": { "literal": ">" }, "scope": "keyword.operator" } ] },
        "regexStart": { "rules": [ { "match": { "literal": "/" }, "scope": "string.regexp", "push": "regex" } ] },
        "divide": { "rules": [ { "match": { "literal": "/" }, "scope": "keyword.operator" } ] },
        "blockStart": { "rules": [ { "match": { "literal": "{" }, "scope": "comment.block", "push": "block" } ] },
        "nestStart": { "rules": [ { "match": { "literal": "{" }, "scope": "keyword", "push": "nest" } ] },
        "nest": { "rules": [] },
        "regex": { "scope": "string.regexp", "endsAtEOL": true, "rules": [ { "match": { "literal": "/" }, "pop": true } ] },
        "comment": { "scope": "comment.line", "endsAtEOL": true, "rules": [] },
        "block": { "scope": "comment.block", "rules": [ { "match": { "literal": "}" }, "pop": true } ] }
      }
    }
    """#
    return try! Grammar(data: Data(json.utf8))
}()

/// Each significant token as `text:scope`, or bare text when unscoped.
func significant(_ tokens: [SyntaxToken], in text: String) -> [String] {
    let units = Array(text.utf16)
    return tokens.filter { !$0.isTrivia }.map { token in
        let body = String(decoding: units[token.location..<token.end], as: UTF16.self)
        return token.scope.map { "\(body):\($0)" } ?? body
    }
}

func scoped(_ highlighter: Highlighter) -> [String] {
    let units = Array(highlighter.text.utf16)
    return highlighter.tokens.map {
        "\(String(decoding: units[$0.range.location..<NSMaxRange($0.range)], as: UTF16.self)):\($0.scope)"
    }
}

@Suite struct RecoveryTests {
    static func builder(_ text: String) -> TreeBuilder {
        TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
    }

    @Test func expectConsumesOrRecordsWhereItLooked() {
        let builder = Self.builder("( a b")
        #expect(builder.expect("("))
        builder.bump()
        #expect(!builder.expect(")"))
        #expect(builder.current.map(builder.text(of:)) == "b", "a failed expect consumes nothing")
        builder.bump()
        #expect(!builder.expect(")"))
        let tree = builder.finish()
        #expect(tree.errors == [
            SyntaxError(message: "expected `)`", range: NSRange(location: 4, length: 1)),
            SyntaxError(message: "expected `)`", range: NSRange(location: 5, length: 0)),
        ], "at the end, an error is empty at the end of the text")
    }

    @Test func errorAndBumpWrapsOneToken() {
        let builder = Self.builder("a ; b")
        builder.bump()
        builder.errorAndBump("unexpected `;`")
        builder.bump()
        builder.errorAndBump("nothing left")
        let tree = builder.finish()
        #expect(sExpression(tree.root) == "root(a error(;) b)")
        #expect(tree.errors.map(\.message) == ["unexpected `;`", "nothing left"])
        #expect(leafText(tree.root) == "a ; b")
    }

    @Test func recoverSkipsBracketsWhole() {
        let builder = Self.builder("a ( b ; [ c ; ] ) d ; e")
        builder.recover("bad statement", until: [";"])
        #expect(builder.at(";"), "the `;` inside the brackets doesn't stop it")
        builder.bump()
        builder.bump()
        let tree = builder.finish()
        #expect(sExpression(tree.root) == "root(error(a ( b ; [ c ; ] ) d) ; e)")
        #expect(tree.errors == [SyntaxError(message: "bad statement", range: NSRange(location: 0, length: 1))])
    }

    @Test func recoverLeavesAnEnclosingClosingBracket() {
        let builder = Self.builder("( x y ) z")
        builder.bump()
        builder.startNode(SyntaxKind("list"))
        builder.recover("bad item", until: [","])
        builder.finishNode()
        #expect(builder.expect(")"), "the `)` belongs to the list's parent")
        builder.bump()
        #expect(sExpression(builder.finish().root) == "root(( list(error(x y)) ) z)")
    }

    /// A closer that doesn't match what `recover` opened belongs to an enclosing construct: taking it
    /// as the end of the unclosed `(` would swallow the block's `}` and everything up to the next `;`.
    @Test func recoverLeavesABracketThatDoesNotMatchWhatItOpened() {
        let builder = Self.builder("{ a ( b } c ; d")
        builder.bump()
        builder.recover("bad statement", until: [";"])
        #expect(builder.at("}"), "the block's `}`, not the end of the unclosed `(`")
        #expect(sExpression(builder.finish().root) == "root({ error(a ( b) } c ; d)")

        let mixed = Self.builder("x ( y ] z ;")
        mixed.recover("bad", until: [";"])
        #expect(mixed.at("]"))
        #expect(sExpression(mixed.finish().root) == "root(error(x ( y) ] z ;)")
    }

    /// A closer for something further out in what `recover` opened closes the brackets inside it.
    @Test func recoverClosesBracketsLeftOpenInsideAnOuterOne() {
        let builder = Self.builder("a ( [ b ) c ; d")
        builder.recover("bad", until: [";"])
        #expect(builder.at(";"), "the `)` closes the `(`, the unclosed `[` with it")
        #expect(sExpression(builder.finish().root) == "root(error(a ( [ b ) c) ; d)")
    }

    @Test func recoverAtAStopTokenSkipsNothing() {
        for text in ["; a", ") a", ""] {
            let builder = Self.builder(text)
            builder.recover("nothing to skip", until: [";"])
            let tree = builder.finish()
            #expect(tree.errors.count == 1)
            #expect(tree.root.childNodes.isEmpty, "no empty error node for \(text.debugDescription)")
            #expect(leafText(tree.root) == text)
        }
    }

    @Test func recoverStopsAtAMultiCharacterToken() {
        let builder = Self.builder("a b -> c")
        builder.recover("bad", until: ["->"])
        #expect(builder.at("->"))
        builder.bump("->")
        builder.bump()
        #expect(sExpression(builder.finish().root) == "root(error(a b) - > c)")
    }

    /// A parser loop that forgets to advance used to hang; now the builder reads as at the end.
    @Test func aStuckParserStops() {
        let text = String(repeating: "a ", count: 100)
        let builder = Self.builder(text)
        builder.bump()
        var spins = 0
        while !builder.isAtEnd { spins += 1 }
        #expect(spins == TreeBuilder.maxStall)
        #expect(!builder.at("a"))
        builder.bump()
        builder.startNode(SyntaxKind("late"))
        builder.finishNode()
        let tree = builder.finish()
        #expect(leafText(tree.root) == text, "everything left goes into the root")
        #expect(tree.errors == [SyntaxError(message: "the parser stopped making progress here", range: NSRange(location: 2, length: 1))])
        #expect(tree.root.childNodes.map(\.range) == [NSRange(location: 2, length: 0)], "a node started after the stop takes nothing")
    }

    /// Taking what a lookahead just found is not more lookahead: with one call to spare, the rest of
    /// a multi-token operator and the token an error wraps are still consumed.
    @Test func consumingWithTheLastLookaheadToSpareStillConsumes() {
        let operatorBuilder = Self.builder("a -> b")
        operatorBuilder.bump()
        for _ in 0..<(TreeBuilder.maxStall - 1) { _ = operatorBuilder.at("x") }
        operatorBuilder.startNode(SyntaxKind("arrow"))
        #expect(operatorBuilder.bump("->"))
        operatorBuilder.finishNode()
        let arrow = operatorBuilder.finish()
        #expect(sExpression(arrow.root) == "root(a arrow(- >) b)")
        #expect(arrow.errors.isEmpty)

        let errorBuilder = Self.builder("a ; b")
        errorBuilder.bump()
        for _ in 0..<(TreeBuilder.maxStall - 1) { _ = errorBuilder.at("x") }
        errorBuilder.errorAndBump("unexpected `;`")
        let wrapped = errorBuilder.finish()
        #expect(sExpression(wrapped.root) == "root(a error(;) b)")
        #expect(wrapped.errors.map(\.message) == ["unexpected `;`"])

        let skipBuilder = Self.builder("a ; b")
        for _ in 0..<(TreeBuilder.maxStall - 1) { _ = skipBuilder.at("x") }
        skipBuilder.recover("bad", until: [])
        let skipped = skipBuilder.finish()
        #expect(sExpression(skipped.root) == "root(error(a ; b))")
        #expect(skipped.errors.map(\.message) == ["bad"])
    }

    /// Lookahead that keeps consuming never counts as stuck, however much of it there is.
    @Test func progressResetsTheStallCount() {
        let builder = Self.builder(String(repeating: "a ", count: 20_000))
        while !builder.isAtEnd {
            for _ in 0..<(TreeBuilder.maxStall - 2) { _ = builder.at("a") }
            builder.bump()
        }
        #expect(builder.finish().errors.isEmpty)
    }

    /// A wrapper started at a checkpoint before anything was consumed: the trivia waiting in front of
    /// the checkpoint stays outside it, as it does for `startNode(_:)`.
    @Test func anEmptyCheckpointWrapLeavesTheTriviaOutside() {
        let builder = Self.builder("x  y")
        builder.bump()
        let checkpoint = builder.checkpoint()
        builder.startNode(SyntaxKind("wrap"), at: checkpoint)
        builder.bump()
        builder.finishNode()
        let tree = builder.finish()
        #expect(sExpression(tree.root) == "root(x wrap(y))")
        #expect(tree.root.childNodes.map(\.range) == [NSRange(location: 3, length: 1)])
    }

    @Test func depthCountsOpenNodes() {
        let builder = Self.builder("a")
        #expect(builder.depth == 0)
        builder.startNode(SyntaxKind("x"))
        builder.startNode(SyntaxKind("y"))
        #expect(builder.depth == 2)
        builder.finishNode()
        builder.finishNode()
        #expect(builder.depth == 0)
        _ = builder.finish()
    }
}

@Suite struct RelexTests {
    @Test func divisionBecomesARegex() {
        let text = "f(a) /x y/ ;"
        let highlighter = Highlighter(grammar: relexGrammar, text: text)
        let builder = TreeBuilder(highlighter: highlighter)
        #expect(significant(builder.tokens, in: text) == ["f", "(:punctuation", "a", "):punctuation", "/", "x", "y", "/", ";:punctuation"])
        for _ in 0..<4 { builder.bump() }
        #expect(builder.relex(as: "regexStart"))
        #expect(builder.current.map(builder.text(of:)) == "/x y/")
        builder.bump()
        #expect(builder.expect(";"))
        let tree = builder.finish()
        #expect(significant(tree.tokens, in: text) == ["f", "(:punctuation", "a", "):punctuation", "/x y/:string.regexp", ";:punctuation"])
        #expect(leafText(tree.root) == text)
    }

    @Test func aRegexBecomesDivision() {
        let text = "x = 4\n  /2/ 1"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        for _ in 0..<3 { builder.bump() }
        #expect(builder.at(scope: "string.regexp"))
        #expect(builder.relex(as: "divide"))
        #expect(significant(builder.tokens, in: text) == ["x", "=", "4", "/:keyword.operator", "2", "/", "1"],
                "the re-scan reads on: the second `/` follows a `2`, so the lexer takes it for division")
        let tree = builder.finish()
        #expect(leafText(tree.root) == text)
    }

    /// The second request lands right after the first re-lexed token, with the same scope: the two
    /// must stay separate tokens, or the second one's start is lost inside the first.
    @Test func adjacentRelexedTokensStaySeparate() {
        let text = "(a)//"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        for _ in 0..<3 { builder.bump() }
        #expect(builder.relex(as: "divide"))
        builder.bump()
        #expect(builder.at(scope: "string.regexp"), "after a `/` the lexer guesses regex")
        #expect(builder.relex(as: "divide"))
        builder.bump()
        let tree = builder.finish()
        #expect(significant(tree.tokens, in: text) == ["(:punctuation", "a", "):punctuation", "/:keyword.operator", "/:keyword.operator"])
    }

    /// A checkpoint taken before a token that a re-lex then turns into a comment: the comment is
    /// trivia in front of the wrapper, so it stays outside it.
    @Test func aCheckpointBeforeARelexToTriviaKeepsItOutside() {
        let text = "{ c } x y"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        let checkpoint = builder.checkpoint()
        #expect(builder.relex(as: "blockStart"))
        builder.bump()
        builder.startNode(SyntaxKind("pair"), at: checkpoint)
        builder.bump()
        builder.finishNode()
        let tree = builder.finish()
        let pair = tree.root.childNodes[0]
        #expect(pair.range.location == 6, "the node starts at `x`, not at the comment the re-lex made")
        #expect(pair.text == "x y")
        #expect(leafText(tree.root) == text)
    }

    @Test func refusedRequestsChangeNothing() {
        let text = "f(a) /x/"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        let before = builder.tokens
        #expect(!builder.relex(as: "noSuchState"))
        #expect(!builder.relex(as: "blockStart"), "no rule of the state matches an `f`")
        #expect(builder.tokens == before)

        // `=>` is one lexer step, split into two parser tokens: the lexer never starts a step at the `>`.
        let run = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: "a =>"))
        run.bump()
        run.bump()
        #expect(run.at(">"))
        let runBefore = run.tokens
        #expect(!run.relex(as: "greater"))
        #expect(run.tokens == runBefore)

        let plain = TreeBuilder(tokens: before, text: text)
        #expect(!plain.relex(as: "regexStart"), "a builder without a highlighter can't re-lex")
        while !builder.isAtEnd { builder.bump() }
        #expect(!builder.relex(as: "regexStart"))
        _ = builder.finish()
        _ = run.finish()
        _ = plain.finish()
    }

    /// Re-lexing as a multi-line state re-scans the following lines, until the lexer state matches again.
    @Test func relexRescansUntilTheStateConverges() {
        let text = "a {\nb\n} c\nd"
        let highlighter = Highlighter(grammar: relexGrammar, text: text)
        let builder = TreeBuilder(highlighter: highlighter)
        builder.bump()
        #expect(builder.relex(as: "blockStart"))
        #expect(builder.current.map(builder.text(of:)) == "c", "the block comment is trivia, so the cursor skips it")
        let tree = builder.finish()
        #expect(significant(tree.tokens, in: text) == ["a", "c", "d"])
        #expect(highlighter.applyRelexing(of: tree) == [NSRange(location: 0, length: 10)])
        #expect(scoped(highlighter) == ["{:comment.block", "b:comment.block", "}:comment.block"])
        #expect(highlighter.syntaxTokens == tree.tokens)
    }

    @Test func applyingMakesTheHighlightMatchTheTree() {
        let text = "x\nf(a) /re/\ny"
        let highlighter = Highlighter(grammar: relexGrammar, text: text)
        let before = scoped(highlighter)
        let builder = TreeBuilder(highlighter: highlighter)
        for _ in 0..<5 { builder.bump() }
        #expect(builder.relex(as: "regexStart"))
        let tree = builder.finish()
        #expect(highlighter.applyRelexing(of: tree) == [NSRange(location: 2, length: 10)], "only the line that changed")
        #expect(scoped(highlighter) == ["(:punctuation", "):punctuation", "/re/:string.regexp"])
        #expect(highlighter.syntaxTokens == tree.tokens)

        // A parse that no longer asks for it puts the lexer's reading back.
        let next = TreeBuilder(highlighter: highlighter).finish()
        #expect(highlighter.applyRelexing(of: next) == [NSRange(location: 2, length: 10)])
        #expect(scoped(highlighter) == before)

        // And one that asks again restores it; applying the same tree twice changes nothing more.
        let again = TreeBuilder(highlighter: highlighter)
        for _ in 0..<5 { again.bump() }
        #expect(again.relex(as: "regexStart"))
        let third = again.finish()
        #expect(highlighter.applyRelexing(of: third)?.count == 1)
        #expect(highlighter.applyRelexing(of: third) == [])
    }

    /// Two parses of one text, the second begun before the first was applied: it never saw what the
    /// first changed, so applying it puts that back, and must say where.
    @Test func applyingAnotherTreeOfTheSameTextReportsWhatItUndoes() {
        let highlighter = Highlighter(grammar: relexGrammar, text: "x\nf(a) /re/\ny")
        let before = scoped(highlighter)
        let first = TreeBuilder(highlighter: highlighter)
        let second = TreeBuilder(highlighter: highlighter)
        for _ in 0..<5 { first.bump() }
        #expect(first.relex(as: "regexStart"))
        #expect(highlighter.applyRelexing(of: first.finish()) == [NSRange(location: 2, length: 10)])
        #expect(scoped(highlighter) != before)

        #expect(highlighter.applyRelexing(of: second.finish()) == [NSRange(location: 2, length: 10)])
        #expect(scoped(highlighter) == before)
    }

    @Test func aTreeFromAnOlderTextIsNotApplied() {
        let highlighter = Highlighter(grammar: relexGrammar, text: "f(a) /re/")
        let builder = TreeBuilder(highlighter: highlighter)
        for _ in 0..<4 { builder.bump() }
        #expect(builder.relex(as: "regexStart"))
        let tree = builder.finish()
        highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "g")
        let before = scoped(highlighter)
        #expect(highlighter.applyRelexing(of: tree) == nil)
        #expect(scoped(highlighter) == before)
        #expect(Highlighter(grammar: relexGrammar, text: "x").applyRelexing(of: tree) == nil, "nor to another highlighter")
        let plain = TreeBuilder(tokens: highlighter.syntaxTokens, text: highlighter.text).finish()
        #expect(highlighter.applyRelexing(of: plain) == nil)
    }

    /// A re-lexed token moves with its text through edits, and goes when the edit replaces it.
    @Test func editsCarryRelexedTokens() {
        let highlighter = Highlighter(grammar: relexGrammar, text: "f(a) /re/\nz")
        let builder = TreeBuilder(highlighter: highlighter)
        for _ in 0..<4 { builder.bump() }
        #expect(builder.relex(as: "regexStart"))
        _ = highlighter.applyRelexing(of: builder.finish())

        highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "gg")
        #expect(scoped(highlighter) == ["(:punctuation", "):punctuation", "/re/:string.regexp"], "an edit before it shifts it")
        highlighter.replaceCharacters(in: NSRange(location: 13, length: 0), with: "q")
        #expect(scoped(highlighter) == ["(:punctuation", "):punctuation", "/re/:string.regexp"], "an edit after it leaves it")
        highlighter.replaceCharacters(in: NSRange(location: 7, length: 1), with: "/")
        #expect(scoped(highlighter) == ["(:punctuation", "):punctuation"], "replacing its `/` drops it")
        #expect(highlighter.lexing.overrides.isEmpty)
    }

    /// Re-lexing as a state that never closes re-scans to the end of the text each time, so the
    /// builder caps the re-scanning: past about four times the text, it refuses.
    @Test func relexWorkStaysLinear() {
        let lines = 2_000
        let text = String(repeating: "{\n", count: lines)
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        var accepted = 0
        var refused = 0
        while !builder.isAtEnd {
            if builder.relex(as: "nestStart") { accepted += 1 } else { refused += 1 }
            builder.bump()
        }
        #expect(refused > 0, "the budget ran out")
        #expect(builder.relexBudget > -text.utf16.count, "it stops within one re-scan of the budget")
        #expect(accepted + refused == lines)
        let tree = builder.finish()
        #expect(leafText(tree.root) == text)
    }

    /// A refused request puts back the request already at that token, not just the lexer's own reading.
    @Test func aRefusedRequestKeepsTheEarlierOne() {
        let text = "f(a) /re/"
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        for _ in 0..<4 { builder.bump() }
        #expect(builder.relex(as: "divide"))
        let divided = builder.tokens
        #expect(!builder.relex(as: "greater"), "no rule of `greater` matches a `/`")
        #expect(builder.tokens == divided)
        #expect(builder.relex(as: "divide"), "the earlier request still stands")
        #expect(builder.relex(as: "regexStart"), "and can be replaced")
        #expect(builder.current.map(builder.text(of:)) == "/re/")
        _ = builder.finish()
    }

    /// A request the lexer refuses has still re-scanned the line to find out, so it spends budget too:
    /// a parser that asks at every token of one long line must not re-scan it once per token.
    @Test func refusedRelexWorkStaysLinear() {
        let text = String(repeating: "a ", count: 500)
        let builder = TreeBuilder(highlighter: Highlighter(grammar: relexGrammar, text: text))
        let budget = builder.relexBudget
        var asked = 0
        while !builder.isAtEnd {
            #expect(!builder.relex(as: "blockStart"), "no rule of the state matches an `a`")
            asked += 1
            builder.bump()
        }
        #expect(asked == 500)
        #expect(builder.relexBudget <= 0, "refused re-scans were charged: \(budget) left \(builder.relexBudget)")
        #expect(builder.relexBudget > -text.utf16.count, "it stops within one re-scan of the budget")
        #expect(leafText(builder.finish().root) == text)
    }

    /// After any mix of edits and re-parses, the highlight is what a fresh highlighter and parse give.
    @Test func editingThenReparsingConverges() {
        let highlighter = Highlighter(grammar: relexGrammar, text: "f(a) /re/\nx")
        func parse(_ highlighter: Highlighter) {
            let builder = TreeBuilder(highlighter: highlighter)
            while let token = builder.current {
                if builder.text(of: token) == "/" { builder.relex(as: "regexStart") }
                builder.bump()
            }
            _ = highlighter.applyRelexing(of: builder.finish())
        }
        parse(highlighter)
        for (location, text) in [(0, "(b) /x/ "), (5, "\n"), (2, ""), (11, "q(c) /"), (0, "")] {
            highlighter.replaceCharacters(in: NSRange(location: location, length: text.isEmpty ? 1 : 0), with: text)
            parse(highlighter)
            let fresh = Highlighter(grammar: relexGrammar, text: highlighter.text)
            parse(fresh)
            #expect(scoped(highlighter) == scoped(fresh), "after editing to \(highlighter.text.debugDescription)")
            #expect(highlighter.syntaxTokens == fresh.syntaxTokens)
        }
    }

    @Test func aSnapshotParsesOffTheMainThread() async {
        let highlighter = Highlighter(grammar: relexGrammar, text: "f(a) /re/")
        let snapshot = highlighter.snapshot
        let tree = await Task.detached {
            let builder = TreeBuilder(snapshot: snapshot)
            for _ in 0..<4 { builder.bump() }
            _ = builder.relex(as: "regexStart")
            return builder.finish()
        }.value
        #expect(snapshot.text == "f(a) /re/")
        #expect(highlighter.applyRelexing(of: tree) == [NSRange(location: 0, length: 9)])
    }
}
