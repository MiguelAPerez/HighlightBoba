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
/// _ = builder.bump(":")
/// parseValue(builder)
/// builder.finishNode()
/// ```
public final class TreeBuilder {
    public let tokens: [SyntaxToken]
    private let units: [UInt16]
    /// The next token not yet in the tree, trivia included.
    private var position = 0
    private var frames: [Frame]
    private var nodes: [SyntaxTree.RawNode] = []
    private var pool: [Int32] = []
    /// Indices of the significant tokens, ascending, so lookahead never walks trivia.
    private let significant: [Int]
    /// Index into `significant` of the first entry at or after `position`.
    private var cursor = 0
    private var nextFrameID = 1
    /// Tokens examined by lookahead, for the linearity tests.
    private(set) var lookaheadSteps = 0

    private struct Frame {
        var kind: SyntaxKind
        var start: Int
        var children: [Int32] = []
        var id = 0
    }

    /// Where a node may later be started, to wrap what is parsed from here on (`a - b` becoming
    /// the left side of `a - b - c`).
    public struct Checkpoint: Sendable {
        /// The node it was taken in; a checkpoint is only good there.
        let frameID: Int
        let childIndex: Int
        /// Where the cursor was, and how much trivia was waiting in front of the next significant token.
        let position: Int
        let pendingTrivia: Int
        let start: Int
    }

    /// `tokens` must tile `text`, as `Highlighter.syntaxTokens` does: in order, no gaps, none empty.
    public init(tokens: [SyntaxToken], text: String) {
        self.tokens = tokens
        units = Array(text.utf16)
        var expected = 0
        for token in tokens {
            precondition(token.location == expected && token.length > 0, "tokens must tile the text: gap, overlap or empty token at \(expected)")
            expected = token.end
        }
        precondition(expected == units.count, "tokens must tile the text: they end at \(expected), the text at \(units.count)")
        significant = tokens.indices.filter { !tokens[$0].isTrivia }
        frames = [Frame(kind: .root, start: 0)]
    }

    /// Parses `highlighter`'s current text.
    public convenience init(highlighter: Highlighter) {
        self.init(tokens: highlighter.syntaxTokens, text: highlighter.text)
    }

    // MARK: Reading

    /// The index of the `offset`-th significant token from `position`.
    private func significantIndex(_ offset: Int = 0) -> Int? {
        let slot = cursor + offset
        lookaheadSteps += 1
        return offset >= 0 && slot < significant.count ? significant[slot] : nil
    }

    /// The next significant token, or `nil` at the end.
    public var current: SyntaxToken? { peek() }
    public var isAtEnd: Bool { current == nil }

    /// The significant token `offset` places ahead of `current`.
    public func peek(_ offset: Int = 0) -> SyntaxToken? { significantIndex(offset).map { tokens[$0] } }

    public func text(of token: SyntaxToken) -> String {
        String(decoding: units[token.location..<token.end], as: UTF16.self)
    }

    /// Whether the next significant token is `text`, or a run of adjacent tokens with no trivia
    /// between them spells it: `->` and `===` arrive as one-character symbols.
    public func at(_ text: String) -> Bool { tokenCount(spelling: text) != nil }

    /// Whether the next significant token is a lexeme with this scope.
    public func at(scope: String) -> Bool { current?.scope == scope }

    private func tokenCount(spelling text: String) -> Int? {
        let wanted = Array(text.utf16)
        guard !wanted.isEmpty, var index = significantIndex() else { return nil }
        var matched = 0
        var count = 0
        while matched < wanted.count {
            guard index < tokens.count, !tokens[index].isTrivia || count == 0 else { return nil }
            let token = tokens[index]
            lookaheadSteps += 1
            guard matched + token.length <= wanted.count,
                  units[token.location..<token.end].elementsEqual(wanted[matched..<(matched + token.length)]) else { return nil }
            matched += token.length
            count += 1
            index += 1
        }
        return count
    }

    // MARK: Building

    /// Adds the next significant token, and any trivia before it, to the open node.
    public func bump() {
        guard let index = significantIndex() else { return }
        attach(upTo: index + 1)
    }

    /// Adds the tokens spelling `text` if they come next. Returns whether they did.
    @discardableResult
    public func bump(_ text: String) -> Bool {
        guard let count = tokenCount(spelling: text) else { return false }
        for _ in 0..<count { bump() }
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
        return Checkpoint(frameID: top.id, childIndex: top.children.count, position: position,
                          pendingTrivia: (significantIndex() ?? tokens.count) - position, start: nextLocation)
    }

    /// Starts a node holding everything added to the open node since `checkpoint`.
    public func startNode(_ kind: SyntaxKind, at checkpoint: Checkpoint) {
        let top = frames.count - 1
        precondition(checkpoint.frameID == frames[top].id, "a checkpoint must be used in the node it was taken in, while that node is open")
        // Trivia that was waiting when the checkpoint was taken goes in front of the wrapper, not into it.
        let first = checkpoint.childIndex + (position == checkpoint.position ? 0 : checkpoint.pendingTrivia)
        precondition(first <= frames[top].children.count, "a checkpoint was used twice, or after its children were wrapped")
        let wrapped = Array(frames[top].children[first...])
        frames[top].children.removeSubrange(first...)
        frames.append(makeFrame(kind, start: checkpoint.start, children: wrapped))
    }

    /// Ends parsing: every token left goes into the root.
    public func finish() -> SyntaxTree {
        precondition(frames.count == 1, "finish() with \(frames.count - 1) node(s) still open")
        attach(upTo: tokens.count)
        let root = frames.removeLast()
        _ = makeNode(Frame(kind: root.kind, start: 0, children: root.children), end: units.count)
        return SyntaxTree(tokens: tokens, units: units, nodes: nodes, children: pool)
    }

    // MARK: Internals

    private func makeFrame(_ kind: SyntaxKind, start: Int, children: [Int32] = []) -> Frame {
        defer { nextFrameID += 1 }
        return Frame(kind: kind, start: start, children: children, id: nextFrameID)
    }

    /// Where the next significant token starts: trivia in front of it is not part of a node.
    private var nextLocation: Int { significantIndex().map { tokens[$0].location } ?? units.count }

    private func attachTrivia() {
        attach(upTo: significantIndex() ?? tokens.count)
    }

    private func attach(upTo end: Int) {
        while position < end {
            frames[frames.count - 1].children.append(Int32(position))
            position += 1
        }
        while cursor < significant.count && significant[cursor] < position { cursor += 1 }
    }

    private func makeNode(_ frame: Frame, end explicitEnd: Int? = nil) -> Int {
        let index = nodes.count
        var start = frame.start
        var end = frame.start
        if let first = frame.children.first { start = startOf(first) }
        if let last = frame.children.last { end = endOf(last) }
        nodes.append(SyntaxTree.RawNode(kind: frame.kind, start: start, end: explicitEnd ?? end,
                                        childStart: pool.count, childCount: frame.children.count, parent: -1))
        pool.append(contentsOf: frame.children)
        for child in frame.children where child < 0 { nodes[Int(~child)].parent = index }
        return index
    }

    private func startOf(_ child: Int32) -> Int { child >= 0 ? tokens[Int(child)].location : nodes[Int(~child)].start }
    private func endOf(_ child: Int32) -> Int { child >= 0 ? tokens[Int(child)].end : nodes[Int(~child)].end }
}
