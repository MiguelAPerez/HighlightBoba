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
    private var parents: [Int] = []

    private struct Frame {
        var kind: SyntaxKind
        var start: Int
        var children: [Int32] = []
    }

    /// Where a node may later be started, to wrap what is parsed from here on (`a - b` becoming
    /// the left side of `a - b - c`).
    public struct Checkpoint: Sendable {
        let depth: Int
        let childIndex: Int
        let start: Int
    }

    public init(tokens: [SyntaxToken], text: String) {
        self.tokens = tokens
        units = Array(text.utf16)
        frames = [Frame(kind: .root, start: 0)]
    }

    /// Parses `highlighter`'s current text.
    public convenience init(highlighter: Highlighter) {
        self.init(tokens: highlighter.syntaxTokens, text: highlighter.text)
    }

    // MARK: Reading

    /// The index of the `offset`-th significant token from `position`.
    private func significantIndex(_ offset: Int = 0) -> Int? {
        var index = position
        var remaining = offset
        while index < tokens.count {
            if !tokens[index].isTrivia {
                if remaining == 0 { return index }
                remaining -= 1
            }
            index += 1
        }
        return nil
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
        frames.append(Frame(kind: kind, start: nextLocation))
    }

    public func finishNode() {
        precondition(frames.count > 1, "finishNode() without a matching startNode()")
        let frame = frames.removeLast()
        let index = makeNode(frame)
        frames[frames.count - 1].children.append(~Int32(index))
    }

    /// Marks the spot a later `startNode(_:at:)` may wrap from. Trivia before it stays outside.
    public func checkpoint() -> Checkpoint {
        attachTrivia()
        return Checkpoint(depth: frames.count, childIndex: frames[frames.count - 1].children.count, start: nextLocation)
    }

    /// Starts a node holding everything added to the open node since `checkpoint`.
    public func startNode(_ kind: SyntaxKind, at checkpoint: Checkpoint) {
        precondition(checkpoint.depth == frames.count, "a checkpoint must be used in the node it was taken in")
        let wrapped = Array(frames[frames.count - 1].children[checkpoint.childIndex...])
        frames[frames.count - 1].children.removeSubrange(checkpoint.childIndex...)
        frames.append(Frame(kind: kind, start: checkpoint.start, children: wrapped))
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

    private var nextLocation: Int { position < tokens.count ? tokens[position].location : units.count }

    private func attachTrivia() {
        attach(upTo: significantIndex() ?? tokens.count)
    }

    private func attach(upTo end: Int) {
        while position < end {
            frames[frames.count - 1].children.append(Int32(position))
            position += 1
        }
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
