import Foundation

/// An edit as a reparse sees it: `range` of the old text became `replacementLength` UTF-16 units.
public struct TextEdit: Hashable, Sendable {
    public var range: NSRange
    public var replacementLength: Int

    public init(range: NSRange, replacementLength: Int) {
        self.range = range
        self.replacementLength = replacementLength
    }

    /// How much longer the text got.
    public var delta: Int { replacementLength - range.length }

    /// This edit, then `next` (whose range is in the text this one left), as one edit covering both.
    public func followed(by next: TextEdit) -> TextEdit {
        let start = min(range.location, next.range.location)
        // In the text between the two edits: the end of what either one touched.
        let end = max(range.location + replacementLength, NSMaxRange(next.range))
        return TextEdit(range: NSRange(location: start, length: end - delta - start),
                        replacementLength: end + next.delta - start)
    }
}

/// A language parser that can reparse one block alone, so an edit costs the block, not the file.
///
/// A reparse boundary is a node kind whose parse depends only on its own tokens: a `{ }` body, an
/// array literal. `parseBlock` must parse one such node with the builder at its first token, exactly
/// as `parse` would have parsed it there, whatever surrounds it.
public protocol IncrementalParser: Sendable {
    /// The node kinds `parseBlock` can parse alone.
    var reparseBoundaries: Set<SyntaxKind> { get }
    /// Parses the whole text. Leaves no node open.
    func parse(_ builder: TreeBuilder)
    /// Parses one `kind` node: starts it, consumes its tokens, finishes it.
    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder)
}

/// A parse, and the part of it that is new.
public struct Reparse: Sendable {
    public let tree: SyntaxTree
    let changedIndex: Int
    /// Parser lookahead it took, failed block attempts included: the work done.
    let steps: Int

    /// The node rebuilt: the reparsed block, or the root after a whole parse. Everything outside
    /// it is the old tree's, moved by the edit, so highlight queries need to re-run only on this.
    public var changed: SyntaxNode { SyntaxNode(tree: tree, index: changedIndex) }
    /// Whether only a block was reparsed.
    public var isIncremental: Bool { changedIndex != tree.nodes.count - 1 }
}

extension IncrementalParser {
    /// Parses all of `snapshot`.
    public func parse(_ snapshot: Highlighter.Snapshot) -> Reparse { parseWhole(snapshot, steps: 0) }

    /// Brings `tree` up to `snapshot`, which is `tree`'s text after `edit`, by reparsing the smallest
    /// block that covers the edit. The result is the tree a whole parse of `snapshot` gives; when no
    /// block can promise that, it is a whole parse.
    public func reparse(_ tree: SyntaxTree, after edit: TextEdit, in snapshot: Highlighter.Snapshot) -> Reparse {
        var block = BlockReparse(old: tree, edit: edit, snapshot: snapshot)
        if let result = block.run(using: self) { return result }
        return parseWhole(snapshot, steps: block.steps)
    }

    private func parseWhole(_ snapshot: Highlighter.Snapshot, steps: Int) -> Reparse {
        let builder = TreeBuilder(snapshot: snapshot)
        // Cancelled, as when a block attempt stopped for it, the parser isn't started: its tree, all
        // tokens in the root, is never published.
        if !Task.isCancelled { parse(builder) }
        let tree = builder.finish()
        return Reparse(tree: tree, changedIndex: tree.nodes.count - 1, steps: steps + builder.lookaheadSteps)
    }
}

/// Reparses the smallest enclosing block that can stand in for a whole parse, and splices it in.
///
/// A block's reparse equals what a whole parse would make there when the parse reaching it is the
/// same, which these checks make sure of:
/// - the edit is strictly inside the block, its first and last tokens unchanged,
/// - lookahead before the block started read no further than its first token,
/// - the block's parse reads nothing past its last token, and re-lexes nothing past its last line,
/// - the lexer state at the end of that line, and its tokens after the block, are unchanged,
/// - re-lex requests outside the block re-scanned none of the edited text, and the budget holds.
/// Then what follows the block parses as before, so the old tree's nodes after it are moved, not rebuilt.
struct BlockReparse {
    typealias RawNode = SyntaxTree.RawNode

    let old: SyntaxTree
    let edit: TextEdit
    let snapshot: Highlighter.Snapshot
    private(set) var steps = 0

    init(old: SyntaxTree, edit: TextEdit, snapshot: Highlighter.Snapshot) {
        self.old = old
        self.edit = edit
        self.snapshot = snapshot
    }

    mutating func run(using parser: some IncrementalParser) -> Reparse? {
        guard let oldLexing = old.lexing, old.highlighter == snapshot.highlighter,
              edit.range.location >= 0, edit.range.length >= 0, edit.replacementLength >= 0,
              NSMaxRange(edit.range) <= old.units.count,
              old.units.count + edit.delta == snapshot.lexing.units.count,
              // A parse that ran out of re-lex budget refused requests a reparse can't account for.
              old.relexSpent < TreeBuilder.relexBudget(forLength: old.units.count) else { return nil }
        for index in containers() {
            if Task.isCancelled { return nil }
            if let result = attempt(index, oldLexing: oldLexing, parser: parser) { return result }
        }
        return nil
    }

    /// The nodes below the root whose range covers the edit, innermost first.
    private func containers() -> [Int] {
        let low = edit.range.location, high = NSMaxRange(edit.range)
        var path: [Int] = []
        var node = old.nodes[old.nodes.count - 1]
        while true {
            let children = old.children[node.childStart..<(node.childStart + node.childCount)]
            // The last child starting at or before the edit.
            var lower = children.startIndex, upper = children.endIndex
            while lower < upper {
                let mid = (lower + upper) / 2
                if start(of: children[mid]) <= low { lower = mid + 1 } else { upper = mid }
            }
            guard lower > children.startIndex, children[lower - 1] < 0 else { break }
            let index = Int(~children[lower - 1])
            node = old.nodes[index]
            guard node.end >= high else { break }
            path.append(index)
        }
        return path.reversed()
    }

    private func start(of child: Int32) -> Int { child >= 0 ? old.tokens[Int(child)].location : old.nodes[Int(~child)].start }

    private mutating func attempt(_ index: Int, oldLexing: Lexing, parser: some IncrementalParser) -> Reparse? {
        let raw = old.nodes[index]
        guard parser.reparseBoundaries.contains(raw.kind), raw.firstError >= 0,
              let firstIndex = old.leaf(of: index, last: false), let lastIndex = old.leaf(of: index, last: true) else { return nil }
        let first = old.tokens[firstIndex], last = old.tokens[lastIndex]
        let editEnd = NSMaxRange(edit.range), delta = edit.delta
        guard !first.isTrivia, !last.isTrivia, raw.start == first.location, raw.end == last.end,
              edit.range.location >= first.end, editEnd <= last.location, raw.lookedTo <= first.end else { return nil }
        let start = first.location, oldEnd = last.end, end = oldEnd + delta

        // Requests before the block re-scanned only text before the edit, and requests after it only
        // text after: in a whole parse of the new text they re-scan, and cost, the same.
        for request in old.relexLog[..<raw.firstRelex] where request.scanEnd > edit.range.location { return nil }
        for request in old.relexLog[raw.relexEnd...] where request.lineStart < editEnd { return nil }

        // The lexing a whole parse would have when it reaches the block: the old parse's re-lexing
        // outside the block, none inside. One at the block's first token may be the outer parser's
        // or the block's own; that can't be told apart, so it is left to a bigger block.
        guard oldLexing.override(at: start) == nil else { return nil }
        var outside: [Lexing.Override] = []
        for override in oldLexing.overrides where override.location < start || override.location >= oldEnd {
            outside.append(override.location < start ? override
                           : Lexing.Override(location: override.location + delta, state: override.state))
        }
        var lexing = snapshot.lexing
        lexing.replaceOverrides(with: outside)

        let firstLine = lexing.lineIndex(containing: start), lastLine = lexing.lineIndex(containing: end - 1)
        let tokens = Array(lexing.syntaxTokens(of: lexing.lines[firstLine...lastLine])
            .drop { $0.location < start }.prefix { $0.location < end })
        guard tokens.first == first, tokens.last == last.moved(by: delta) else { return nil }

        let spentOutside = old.relexSpent - old.relexLog[raw.firstRelex..<raw.relexEnd].reduce(0) { $0 + $1.cost }
        let builder = TreeBuilder(window: TreeBuilder.Window(start: start, end: end, lastLineEnd: lexing.lines[lastLine].end),
                                  tokens: tokens, lexing: lexing, highlighter: snapshot.highlighter,
                                  revision: snapshot.revision, depth: raw.depth, lookedTo: raw.lookedTo,
                                  relexBudget: TreeBuilder.relexBudget(forLength: lexing.units.count) - spentOutside)
        parser.parseBlock(raw.kind, builder)
        steps += builder.lookaheadSteps
        // Budget left at the end means a whole parse refuses no request either. The stall at the block's
        // start is at most the old parse's most, so a whole parse doesn't stop inside the block either.
        guard let window = builder.finishWindow(kind: raw.kind), window.relexBudget > 0,
              old.maxStall + window.stallBeforeFirstConsume <= TreeBuilder.maxStall else { return nil }

        // What follows the block must lex as before: the rest of its last line, and the state that
        // line hands on. Re-lexing still to come on that line would read from a state this can't see.
        let final = window.lexing
        let line = final.lines[lastLine]
        let oldLine = oldLexing.lines[oldLexing.lineIndex(containing: oldEnd - 1)]
        guard line.endStack == oldLine.endStack else { return nil }
        let slot = final.overrideSlot(atOrAfter: end)
        guard slot == final.overrides.count || final.overrides[slot].location >= line.end else { return nil }
        var next = lastIndex + 1
        for token in final.syntaxTokens(of: [line]) where token.location >= end {
            guard next < old.tokens.count, old.tokens[next].moved(by: delta) == token else { return nil }
            next += 1
        }
        guard next == old.tokens.count || old.tokens[next].location >= oldLine.end else { return nil }

        return splice(window, at: index, tokens: firstIndex...lastIndex, oldEnd: oldEnd)
    }

    /// The old tree with node `index` (covering `tokens`, ending at `oldEnd`) replaced by `window`'s
    /// node. Nodes finish children first, so the replaced subtree, its child lists and its errors are
    /// each one contiguous run of the old tables; everything after a run moves by the change in size.
    private func splice(_ window: TreeBuilder.WindowParse, at index: Int, tokens: ClosedRange<Int>, oldEnd: Int) -> Reparse {
        let raw = old.nodes[index]
        let delta = edit.delta
        var descendants = 0
        var stack = [index]
        while let top = stack.popLast() {
            let node = old.nodes[top]
            for child in old.children[node.childStart..<(node.childStart + node.childCount)] where child < 0 {
                descendants += 1
                stack.append(Int(~child))
            }
        }
        let firstNode = index - descendants
        let poolStart = old.nodes[firstNode].childStart, poolEnd = raw.childStart + raw.childCount
        let tokenShift = window.tokens.count - tokens.count
        let nodeShift = window.nodes.count - (descendants + 1)
        let poolShift = window.children.count - (poolEnd - poolStart)
        let errorShift = window.errors.count - (raw.errorEnd - raw.firstError)
        let relexShift = window.relexLog.count - (raw.relexEnd - raw.firstRelex)
        func moved(_ location: Int) -> Int { location >= oldEnd ? location + delta : location }

        var nodes = Array(old.nodes[..<firstNode])
        nodes.reserveCapacity(old.nodes.count + nodeShift)
        for i in nodes.indices where nodes[i].parent > index { nodes[i].parent += nodeShift }
        for var node in window.nodes {
            node.childStart += poolStart
            node.parent = node.parent < 0 ? raw.parent + nodeShift : node.parent + firstNode
            if node.firstError >= 0 { node.firstError += raw.firstError }
            node.errorEnd += raw.firstError
            if node.firstRelex >= 0 { node.firstRelex += raw.firstRelex }
            node.relexEnd += raw.firstRelex
            nodes.append(node)
        }
        for var node in old.nodes[(index + 1)...] {
            // Finished after the block: an ancestor started before it, or a node started after it.
            let startedAfter = node.start >= oldEnd
            node.start = moved(node.start)
            node.end = moved(node.end)
            node.lookedTo = moved(node.lookedTo)
            node.childStart += poolShift
            if node.parent >= 0 { node.parent += nodeShift }
            if startedAfter && node.firstError >= 0 { node.firstError += errorShift }
            node.errorEnd += errorShift
            if startedAfter && node.firstRelex >= 0 { node.firstRelex += relexShift }
            node.relexEnd += relexShift
            nodes.append(node)
        }

        func movedChild(_ child: Int32) -> Int32 {
            if child >= 0 { return child > Int32(tokens.upperBound) ? child + Int32(tokenShift) : child }
            return Int(~child) >= index ? ~(~child + Int32(nodeShift)) : child
        }
        var children = Array(old.children[..<poolStart])
        children.reserveCapacity(old.children.count + poolShift)
        children += window.children.map { $0 >= 0 ? $0 + Int32(tokens.lowerBound) : ~(~$0 + Int32(firstNode)) }
        children += old.children[poolEnd...].map(movedChild)

        let allTokens = Array(old.tokens[..<tokens.lowerBound]) + window.tokens
            + old.tokens[(tokens.upperBound + 1)...].map { $0.moved(by: delta) }
        let errors = Array(old.errors[..<raw.firstError]) + window.errors + old.errors[raw.errorEnd...].map {
            SyntaxError(message: $0.message, range: NSRange(location: moved($0.range.location), length: $0.range.length))
        }
        let relexLog = Array(old.relexLog[..<raw.firstRelex]) + window.relexLog + old.relexLog[raw.relexEnd...].map {
            SyntaxTree.RelexRequest(location: $0.location + delta, lineStart: $0.lineStart + delta, scanEnd: $0.scanEnd + delta)
        }
        let tree = SyntaxTree(tokens: allTokens, units: window.lexing.units, nodes: nodes, children: children,
                              errors: errors, lexing: window.lexing, highlighter: snapshot.highlighter,
                              revision: snapshot.revision, relexLog: relexLog,
                              maxStall: max(old.maxStall + window.stallBeforeFirstConsume, window.maxStall))
        return Reparse(tree: tree, changedIndex: index + nodeShift, steps: steps)
    }
}

extension SyntaxToken {
    func moved(by delta: Int) -> SyntaxToken {
        SyntaxToken(kind: kind, location: location + delta, length: length, scope: scope)
    }
}
