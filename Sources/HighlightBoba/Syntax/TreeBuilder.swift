import Foundation

/// The cursor a hand-written recursive-descent parser reads tokens through, and the builder it
/// makes the tree with.
///
/// The parser only ever sees significant tokens; trivia (spaces, line breaks, comments) is
/// attached for it: whatever sits before a token goes into the node that is open when the token
/// is consumed, and a node starts at its first significant token, so the trivia in front of it
/// stays with its parent. `finish()` puts every token the parser didn't consume into the root,
/// so the tree is lossless even when parsing stops early.
///
/// ```swift
/// builder.startNode(member)
/// builder.bump()            // "key"
/// builder.expect(":")
/// parseValue(builder)
/// builder.finishNode()
/// ```
public final class TreeBuilder {
    private let units: [UInt16]
    /// Tokens already in the tree, in order.
    private var head: [SyntaxToken] = []
    /// Tokens not yet in the tree, last one first, so re-lexing the next token rewrites the end of
    /// the array rather than shifting everything after it.
    private var tail: [SyntaxToken]
    /// Indices into `tail` of its significant tokens, ascending: the last is the next significant
    /// token, so lookahead never walks trivia.
    private var tailSignificant: [Int]
    private var frames: [Frame]
    private var nodes: [SyntaxTree.RawNode] = []
    private var pool: [Int32] = []
    private var nextFrameID = 1
    /// Tokens examined by lookahead, for the linearity tests.
    private(set) var lookaheadSteps = 0
    private var errors: [SyntaxError] = []
    /// Lookahead since a significant token was last consumed.
    private var stall = 0
    private var stalled = false
    /// The most `stall` reached, for an incremental reparse to bound the stall at a block's start.
    private(set) var maxStall = 0
    /// `maxStall` when the first significant token was consumed.
    private var stallBeforeFirstConsume: Int?
    /// Where lookahead has read to so far (a UTF-16 offset), recorded on each node started.
    private var lookedTo = 0
    /// The task this parse runs in was cancelled: the builder reads as at the end.
    private(set) var isCancelled = false
    private var cancellationChecks = 0
    /// Set when reparsing one block: its tokens are all the builder has.
    private let window: Window?
    /// The window parse read past its end, or re-lexed beyond its last line: its tree can't be used.
    private(set) var leftWindow = false
    /// `depth` of the block being reparsed, so a parser's nesting limit sees what a full parse would.
    private let depthBase: Int
    private var relexLog: [SyntaxTree.RelexRequest] = []
    /// `maxStall`, raised by tests that look ahead a long way on purpose.
    var stallLimit = TreeBuilder.maxStall
    private var lexing: Lexing?
    private let highlighter: UUID?
    private let revision: Int
    /// UTF-16 units re-lexing may still re-scan, so a hostile file can't make a parse quadratic.
    private(set) var relexBudget: Int

    /// Lookahead without consuming anything after which the parser is taken to be stuck: from
    /// then on the builder reads as at the end, so a loop that never advances still terminates.
    public static let maxStall = 4096

    private struct Frame {
        var kind: SyntaxKind
        var start: Int
        var children: [Int32] = []
        var id = 0
        var depth = 0
        var lookedTo = 0
        var firstError = 0
        var firstRelex = 0
    }

    /// The block a reparse covers, `start..<end` in the new text, and where its last line ends.
    struct Window {
        let start: Int
        let end: Int
        let lastLineEnd: Int
    }

    /// Where a node may later be started, to wrap what is parsed from here on (`a - b` becoming
    /// the left side of `a - b - c`).
    public struct Checkpoint: Sendable {
        /// The node it was taken in; a checkpoint is only good there.
        let frameID: Int
        let childIndex: Int
        /// Where the cursor was.
        let position: Int
        let start: Int
        /// Where lookahead had read to, which the wrapper records as its own.
        let lookedTo: Int
    }

    /// `tokens` must tile `text`, as `Highlighter.syntaxTokens` does: in order, no gaps, none empty.
    /// A builder made this way can't re-lex.
    public convenience init(tokens: [SyntaxToken], text: String) {
        self.init(tokens: tokens, units: Array(text.utf16), lexing: nil, highlighter: nil, revision: 0, window: nil)
    }

    /// Parses a snapshot of a highlighter's text, on any thread. Re-lex requests the last parse
    /// made are dropped first, so this parse makes its own: see `Highlighter.applyRelexing(of:)`.
    public convenience init(snapshot: Highlighter.Snapshot) {
        var lexing = snapshot.lexing
        lexing.clearOverrides()
        self.init(tokens: lexing.syntaxTokens(of: lexing.lines), units: lexing.units, lexing: lexing,
                  highlighter: snapshot.highlighter, revision: snapshot.revision, window: nil)
    }

    /// Reparses one block: `tokens` tile `window.start..<window.end` of `lexing`'s text. Lookahead
    /// past the window's end reads as the end and sets `leftWindow`.
    convenience init(window: Window, tokens: [SyntaxToken], lexing: Lexing, highlighter: UUID, revision: Int,
                     depth: Int, lookedTo: Int, relexBudget: Int) {
        self.init(tokens: tokens, units: lexing.units, lexing: lexing, highlighter: highlighter, revision: revision,
                  window: window, depthBase: depth)
        self.lookedTo = lookedTo
        self.relexBudget = relexBudget
    }

    /// Parses `highlighter`'s current text.
    public convenience init(highlighter: Highlighter) {
        self.init(snapshot: highlighter.snapshot)
    }

    private init(tokens: [SyntaxToken], units: [UInt16], lexing: Lexing?, highlighter: UUID?, revision: Int,
                 window: Window?, depthBase: Int = 0) {
        self.units = units
        var expected = window?.start ?? 0
        for token in tokens {
            precondition(token.location == expected && token.length > 0, "tokens must tile the text: gap, overlap or empty token at \(expected)")
            expected = token.end
        }
        let end = window?.end ?? units.count
        precondition(expected == end, "tokens must tile the text: they end at \(expected), the text at \(end)")
        self.window = window
        self.depthBase = depthBase
        let reversed = Array(tokens.reversed())
        tail = reversed
        tailSignificant = reversed.indices.filter { !reversed[$0].isTrivia }
        frames = [Frame(kind: .root, start: 0)]
        self.lexing = lexing
        self.highlighter = highlighter
        self.revision = revision
        relexBudget = Self.relexBudget(forLength: units.count)
    }

    /// The re-lex budget of a whole parse of a text this long.
    static func relexBudget(forLength length: Int) -> Int { 4 * length + 4096 }

    /// Every token in order, as re-lexing has left them. Builds the array: O(tokens).
    public var tokens: [SyntaxToken] { head + tail.reversed() }

    /// How many nodes are open below the root. A recursive parser checks it to stop nesting
    /// before its own stack runs out.
    public var depth: Int { frames.count - 1 + depthBase }

    // MARK: Reading

    private var tokenCount: Int { head.count + tail.count }

    private func token(at index: Int) -> SyntaxToken {
        index < head.count ? head[index] : tail[tail.count - 1 - (index - head.count)]
    }

    /// The index of the `offset`-th significant token not yet in the tree.
    private func nextSignificant(_ offset: Int = 0) -> Int? {
        lookaheadSteps += 1
        let slot = tailSignificant.count - 1 - offset
        guard offset >= 0 else { return nil }
        guard slot >= 0 else {
            if window != nil { leftWindow = true }
            return nil
        }
        let index = head.count + (tail.count - 1 - tailSignificant[slot])
        lookedTo = max(lookedTo, token(at: index).end)
        return index
    }

    /// `nextSignificant` on the parser's behalf, which reads as the end once the parser is stuck.
    private func lookahead(_ offset: Int = 0) -> Int? {
        cancellationChecks += 1
        if cancellationChecks & 1023 == 0 && Task.isCancelled { isCancelled = true }
        guard !stalled, !isCancelled else { return nil }
        stall += 1
        maxStall = max(maxStall, stall)
        guard stall <= stallLimit else {
            error("the parser stopped making progress here")
            stalled = true
            return nil
        }
        return nextSignificant(offset)
    }

    /// The next significant token, or `nil` at the end.
    public var current: SyntaxToken? { peek() }
    public var isAtEnd: Bool { current == nil }

    /// The significant token `offset` places ahead of `current`.
    public func peek(_ offset: Int = 0) -> SyntaxToken? { lookahead(offset).map(token(at:)) }

    public func text(of token: SyntaxToken) -> String {
        String(decoding: units[token.location..<token.end], as: UTF16.self)
    }

    // MARK: Lines

    /// The spaces and tabs in front of `token` on its line, when `token` starts a fresh line: it is
    /// the first thing on its line, and the line doesn't continue a token from the line before (a
    /// multi-line string). `nil` otherwise. For languages where line breaks and indentation are
    /// syntax: trivia never reaches a parser, so this is how it sees them. It reads the text, so
    /// it works for a block reparse's first token too.
    public func indentation(of token: SyntaxToken) -> Substring? {
        var start = token.location
        while start > 0, units[start - 1] == 32 || units[start - 1] == 9 { start -= 1 }
        guard start == 0 || units[start - 1] == 10 || units[start - 1] == 13 else { return nil }
        if let lexing, start > 0, lexing.startStack(ofLine: lexing.lineIndex(containing: start)) != lexing.initialStack {
            return nil
        }
        return Substring(String(decoding: units[start..<token.location], as: UTF16.self))
    }

    /// The last significant token added to the tree, if any: what the line before the next token ended with.
    public var previous: SyntaxToken? { head.last { !$0.isTrivia } }

    /// In a block reparse, whether every token of the block has been consumed; `false` in a whole
    /// parse. A block that ends at a token outside it, as a Python suite ends at the next line
    /// indented less, can't look at that token in a reparse: lookahead past the block makes it
    /// fall back. When the parser is where only that token's line decides whether the block goes
    /// on, it asks this first. The reparse only stands if the block ends exactly where it did
    /// before, and the text from there on is unchanged, so that line ends the block again.
    public var isAtBlockEnd: Bool { window != nil && tailSignificant.isEmpty }

    /// Whether the next significant token is `text`, or a run of adjacent tokens with no trivia
    /// between them spells it: `->` and `===` arrive as one-character symbols.
    public func at(_ text: String) -> Bool { end(ofSpelling: text) != nil }

    /// Whether the next significant token is a lexeme with this scope.
    public func at(scope: String) -> Bool { current?.scope == scope }

    /// Where the tokens spelling `text` end (an index past the last), if they come next.
    private func end(ofSpelling text: String) -> Int? {
        let wanted = Array(text.utf16)
        guard !wanted.isEmpty, var index = lookahead() else { return nil }
        var matched = 0
        while matched < wanted.count {
            guard index < tokenCount else {
                if window != nil { leftWindow = true }
                return nil
            }
            let token = token(at: index)
            guard !token.isTrivia else { return nil }
            lookaheadSteps += 1
            lookedTo = max(lookedTo, token.end)
            guard matched + token.length <= wanted.count,
                  units[token.location..<token.end].elementsEqual(wanted[matched..<(matched + token.length)]) else { return nil }
            matched += token.length
            index += 1
        }
        return index
    }

    // MARK: Building

    /// Adds the next significant token, and any trivia before it, to the open node.
    public func bump() {
        guard let index = lookahead() else { return }
        attach(upTo: index + 1)
    }

    /// Adds the tokens spelling `text` if they come next. Returns whether they did.
    @discardableResult
    public func bump(_ text: String) -> Bool {
        guard let end = end(ofSpelling: text) else { return false }
        attach(upTo: end)
        return true
    }

    public func startNode(_ kind: SyntaxKind) {
        attachTrivia()
        frames.append(makeFrame(kind, start: nextLocation))
    }

    public func finishNode() {
        precondition(frames.count > 1, "finishNode() without a matching startNode()")
        let frame = frames.removeLast()
        let index = makeNode(frame)
        frames[frames.count - 1].children.append(~Int32(index))
    }

    /// Marks the spot a later `startNode(_:at:)` may wrap from. Trivia before it stays outside the
    /// wrapper, and taking a checkpoint adds nothing to the tree, so one that is never used changes nothing.
    public func checkpoint() -> Checkpoint {
        let top = frames[frames.count - 1]
        let start = nextLocation
        return Checkpoint(frameID: top.id, childIndex: top.children.count, position: head.count, start: start, lookedTo: lookedTo)
    }

    /// Starts a node holding everything added to the open node since `checkpoint`.
    public func startNode(_ kind: SyntaxKind, at checkpoint: Checkpoint) {
        let top = frames.count - 1
        precondition(checkpoint.frameID == frames[top].id, "a checkpoint must be used in the node it was taken in, while that node is open")
        precondition(checkpoint.childIndex <= frames[top].children.count, "a checkpoint was used twice, or after its children were wrapped")
        // Wrapping nothing yet: settle the waiting trivia into the open node first, as `startNode(_:)`
        // does, or the wrapper's first `bump` would take it in.
        if head.count == checkpoint.position { attachTrivia() }
        // Trivia added since the checkpoint, ahead of its first significant token, goes in front of the
        // wrapper, not into it. Counted now, not when the checkpoint was taken: a re-lex in between can
        // turn the next token into a comment.
        var first = checkpoint.childIndex
        var token = checkpoint.position
        while token < head.count, head[token].isTrivia, first < frames[top].children.count,
              frames[top].children[first] == Int32(token) {
            first += 1
            token += 1
        }
        let wrapped = Array(frames[top].children[first...])
        frames[top].children.removeSubrange(first...)
        var frame = makeFrame(kind, start: checkpoint.start, children: wrapped)
        // As far as lookahead had read at the checkpoint: what it read since belongs to the
        // wrapped children, so peeking at what follows them doesn't change the wrapper.
        frame.lookedTo = checkpoint.lookedTo
        // Its children were parsed before it was started, so it can't be reparsed as a block.
        frame.firstError = -1
        frame.firstRelex = -1
        frames.append(frame)
    }

    /// Ends parsing: every token left goes into the root.
    public func finish() -> SyntaxTree {
        precondition(frames.count == 1, "finish() with \(frames.count - 1) node(s) still open")
        attach(upTo: tokenCount)
        let root = frames.removeLast()
        _ = makeNode(Frame(kind: root.kind, start: 0, children: root.children), end: units.count)
        return SyntaxTree(tokens: head, units: units, nodes: nodes, children: pool, errors: errors,
                          lexing: lexing, highlighter: highlighter, revision: revision, relexLog: relexLog,
                          maxStall: maxStall)
    }

    /// What a window parse made, in the window builder's own numbering: node indices from 0, token
    /// indices from the window's first token, error indices from 0.
    struct WindowParse {
        let tokens: [SyntaxToken]
        let nodes: [SyntaxTree.RawNode]
        let children: [Int32]
        let errors: [SyntaxError]
        let lexing: Lexing
        let relexLog: [SyntaxTree.RelexRequest]
        let relexBudget: Int
        let maxStall: Int
        let stallBeforeFirstConsume: Int
    }

    /// Ends a window parse: `nil` unless the parser made exactly one `kind` node holding every token of
    /// the window, never read past it, and wasn't stopped or cancelled.
    func finishWindow(kind: SyntaxKind) -> WindowParse? {
        precondition(window != nil && frames.count == 1, "finishWindow() needs a window builder with no node open")
        guard !leftWindow, !stalled, !isCancelled, tail.isEmpty, frames[0].children.count == 1,
              let only = frames[0].children.first, only < 0, nodes[Int(~only)].kind == kind else { return nil }
        return WindowParse(tokens: head, nodes: nodes, children: pool, errors: errors, lexing: lexing!,
                           relexLog: relexLog, relexBudget: relexBudget, maxStall: maxStall,
                           stallBeforeFirstConsume: stallBeforeFirstConsume ?? maxStall)
    }

    // MARK: Recovering

    /// Records an error at the next significant token, or at the end of the text.
    public func error(_ message: String) {
        let range = nextSignificant().map { token(at: $0).range } ?? NSRange(location: units.count, length: 0)
        errors.append(SyntaxError(message: message, range: range))
    }

    /// Adds the tokens spelling `text` if they come next, or records "expected `text`".
    @discardableResult
    public func expect(_ text: String) -> Bool {
        if bump(text) { return true }
        error("expected `\(text)`")
        return false
    }

    /// Records an error and wraps the next significant token in an `error` node, so the parse moves on.
    public func errorAndBump(_ message: String) {
        error(message)
        guard let index = lookahead() else { return }
        startNode(.error)
        attach(upTo: index + 1)
        finishNode()
    }

    /// Records an error, then skips to the next token in `stop` and wraps what it skipped in an
    /// `error` node. It skips brackets whole, so a `stop` token inside `( )`, `[ ]` or `{ }` doesn't
    /// end it, and it never consumes a closing bracket it didn't open: that one belongs to an
    /// enclosing construct, so it ends the skipping, whatever is still open inside. A closer for
    /// an outer bracket it opened closes the ones inside it. At a `stop` token, a closing bracket
    /// or the end, it skips nothing.
    public func recover(_ message: String, until stop: Set<String>) {
        error(message)
        var open: [String] = []
        var started = false
        while let index = lookahead() {
            let text = text(of: token(at: index))
            if open.isEmpty && stop.contains(where: { at($0) }) { break }
            if let closer = Self.pairs[text] {
                open.append(closer)
            } else if Self.closers.contains(text) {
                guard let index = open.lastIndex(of: text) else { break }
                open.removeSubrange(index...)
            }
            if !started {
                startNode(.error)
                started = true
            }
            attach(upTo: index + 1)
        }
        if started { finishNode() }
    }

    private static let pairs = ["(": ")", "[": "]", "{": "}"]
    private static let closers: Set<String> = [")", "]", "}"]

    // MARK: Re-lexing

    /// Asks the lexer to read the next significant token, and what follows it, starting with the
    /// rules of the grammar state `stateName`: a JS `/` the lexer took for division, where the
    /// parser knows an expression starts, becomes a regex. The lexer re-scans from there until its
    /// state matches what it had before, and the tokens not yet in the tree are replaced.
    ///
    /// - Returns: whether the token now starts as `stateName` reads it. `false`, with nothing
    ///   changed, when the builder wasn't made from a highlighter, the grammar has no such state,
    ///   none of its rules match at the token, the lexer doesn't start a step there (the second
    ///   character of a punctuation run), or this parse has used its re-lex budget (about four
    ///   re-scans of the whole text).
    @discardableResult
    public func relex(as stateName: String) -> Bool {
        guard lexing != nil, relexBudget > 0, let state = lexing!.grammar.stateID(named: stateName),
              let index = lookahead() else { return false }
        let location = token(at: index).location
        let earlier = lexing!.override(at: location)
        if earlier == state { return true }
        let first = lexing!.lineIndex(containing: location)
        lexing!.setOverride(at: location, state: state)
        let scan = lexing!.rescan(fromLine: first)
        // A refused request has re-scanned too, so it spends budget like an accepted one.
        let end = scan.lines.last?.end ?? location
        let lineStart = lexing!.lines[first].start
        relexBudget -= end - lineStart
        relexLog.append(SyntaxTree.RelexRequest(location: location, lineStart: lineStart, scanEnd: end))
        // The re-scanned lines start at the same place, so their tokens up to `location` are the ones already here.
        var fresh = lexing!.syntaxTokens(of: scan.lines).drop { $0.location < location }
        if let window {
            // A re-lex whose effect runs past the block's last line changes what follows the block,
            // which a block reparse doesn't redo. Tokens on that line past the window are checked later.
            fresh = fresh.prefix { $0.location < window.end }
            if end > window.lastLineEnd || (end > window.end && fresh.last?.end != window.end) { leftWindow = true }
        }
        guard !leftWindow, scan.applied.contains(location), fresh.first?.location == location else {
            if let earlier { lexing!.setOverride(at: location, state: earlier) } else { lexing!.removeOverride(at: location) }
            return false
        }
        lexing!.lines.replaceSubrange(first..<(first + scan.lines.count), with: scan.lines)

        var replaced = 0
        while index + replaced < tokenCount && token(at: index + replaced).location < end { replaced += 1 }
        // In the reversed tail, text-order offset `k` (from the first token not in the tree) is at `tail.count - 1 - k`.
        let offset = index - head.count
        let low = tail.count - (offset + replaced)
        tail.replaceSubrange(low..<(tail.count - offset), with: fresh.reversed())
        // `index` was the next significant token, so every significant entry from `low` up was replaced.
        while let last = tailSignificant.last, last >= low { tailSignificant.removeLast() }
        for slot in low..<(low + fresh.count) where !tail[slot].isTrivia { tailSignificant.append(slot) }
        return true
    }

    // MARK: Internals

    private func makeFrame(_ kind: SyntaxKind, start: Int, children: [Int32] = []) -> Frame {
        defer { nextFrameID += 1 }
        return Frame(kind: kind, start: start, children: children, id: nextFrameID, depth: depth,
                     lookedTo: lookedTo, firstError: errors.count, firstRelex: relexLog.count)
    }

    /// Where the next significant token starts: trivia in front of it is not part of a node.
    private var nextLocation: Int { nextSignificant().map { token(at: $0).location } ?? units.count }

    private func attachTrivia() {
        attach(upTo: nextSignificant() ?? tokenCount)
    }

    private func attach(upTo end: Int) {
        while head.count < end {
            frames[frames.count - 1].children.append(Int32(head.count))
            head.append(tail.removeLast())
        }
        var consumed = false
        while let last = tailSignificant.last, last >= tail.count {
            tailSignificant.removeLast()
            consumed = true
        }
        if consumed {
            if stallBeforeFirstConsume == nil { stallBeforeFirstConsume = maxStall }
            stall = 0
        }
    }

    private func makeNode(_ frame: Frame, end explicitEnd: Int? = nil) -> Int {
        let index = nodes.count
        var start = frame.start
        var end = frame.start
        if let first = frame.children.first { start = startOf(first) }
        if let last = frame.children.last { end = endOf(last) }
        nodes.append(SyntaxTree.RawNode(kind: frame.kind, start: start, end: explicitEnd ?? end,
                                        childStart: pool.count, childCount: frame.children.count, parent: -1,
                                        depth: frame.depth, lookedTo: frame.lookedTo, firstError: frame.firstError,
                                        errorEnd: errors.count, firstRelex: frame.firstRelex, relexEnd: relexLog.count))
        pool.append(contentsOf: frame.children)
        for child in frame.children where child < 0 { nodes[Int(~child)].parent = index }
        return index
    }

    private func startOf(_ child: Int32) -> Int { child >= 0 ? head[Int(child)].location : nodes[Int(~child)].start }
    private func endOf(_ child: Int32) -> Int { child >= 0 ? head[Int(child)].end : nodes[Int(~child)].end }
}
