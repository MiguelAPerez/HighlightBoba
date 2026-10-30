import Foundation

/// What a node is. Each language's parser declares its own (`SyntaxKind("call")`); highlight
/// queries match on the name.
public struct SyntaxKind: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { name }

    /// The node every tree has at the top, covering the whole text.
    public static let root = SyntaxKind("root")
    /// Tokens a parser couldn't fit anywhere, wrapped by `errorAndBump` and `recover`.
    public static let error = SyntaxKind("error")
}

/// Something a parser found wrong with the text.
public struct SyntaxError: Hashable, Sendable {
    public let message: String
    /// The significant token the parser was looking at, or an empty range at the end of the text.
    public let range: NSRange

    public init(message: String, range: NSRange) {
        self.message = message
        self.range = range
    }
}

/// A lossless syntax tree: every token of the text is a leaf of exactly one node, in order, so
/// walking the leaves reproduces the text unit for unit, trivia and errors included.
///
/// Immutable once built. Nodes live in flat tables; `SyntaxNode` is a cheap handle onto them.
public final class SyntaxTree: Sendable {
    public let tokens: [SyntaxToken]
    let units: [UInt16]
    let nodes: [RawNode]
    /// Each node's children, in order: `>= 0` a token index, `< 0` a node index as `~index`.
    let children: [Int32]
    /// What the parser found wrong, in the order it found it.
    public let errors: [SyntaxError]
    /// The lexing the parse ended with, re-lex requests included, when it came from a highlighter.
    let lexing: Lexing?
    /// The highlighter and revision the parse's snapshot came from.
    let highlighter: UUID?
    let revision: Int
    /// Every re-lex request that re-scanned, accepted or not, in the order made: an incremental
    /// reparse checks that none outside the block depended on the edited text.
    let relexLog: [RelexRequest]
    /// The most lookahead with nothing consumed at any point of the parse. Exact for a full parse,
    /// an upper bound after an incremental one.
    let maxStall: Int

    struct RawNode: Equatable, Sendable {
        var kind: SyntaxKind
        var start: Int
        var end: Int
        var childStart: Int
        var childCount: Int
        var parent: Int
        /// What a block reparse needs to rerun this node's parse alone: `depth` when it was started,
        /// how far lookahead had read by then, and the slices of `errors` and `relexLog` made while
        /// it was open (`firstError` is -1 for a node started at a checkpoint, which wraps earlier work).
        var depth: Int
        var lookedTo: Int
        var firstError: Int
        var errorEnd: Int
        var firstRelex: Int
        var relexEnd: Int
    }

    /// One `TreeBuilder.relex(as:)` that re-scanned: at `location`, from the start of its line to
    /// `scanEnd`, spending `scanEnd - lineStart` of the budget.
    struct RelexRequest: Equatable, Sendable {
        var location: Int
        var lineStart: Int
        var scanEnd: Int
        var cost: Int { scanEnd - lineStart }
    }

    init(tokens: [SyntaxToken], units: [UInt16], nodes: [RawNode], children: [Int32], errors: [SyntaxError],
         lexing: Lexing?, highlighter: UUID?, revision: Int, relexLog: [RelexRequest], maxStall: Int) {
        self.tokens = tokens
        self.units = units
        self.nodes = nodes
        self.children = children
        self.errors = errors
        self.lexing = lexing
        self.highlighter = highlighter
        self.revision = revision
        self.relexLog = relexLog
        self.maxStall = maxStall
    }

    /// Budget the parse's re-lex requests spent.
    var relexSpent: Int { relexLog.reduce(0) { $0 + $1.cost } }

    /// The first (or last) token under node `index`, if it has any.
    func leaf(of index: Int, last: Bool) -> Int? {
        var node = nodes[index]
        while node.childCount > 0 {
            let child = children[last ? node.childStart + node.childCount - 1 : node.childStart]
            if child >= 0 { return Int(child) }
            node = nodes[Int(~child)]
        }
        return nil
    }

    /// The text version this tree was parsed from: compare with `Highlighter.revision`.
    public var textRevision: Int { revision }

    /// Built bottom-up, so the root is the last node.
    public var root: SyntaxNode { SyntaxNode(tree: self, index: nodes.count - 1) }

    public var text: String { String(decoding: units, as: UTF16.self) }

    public func text(of token: SyntaxToken) -> String {
        String(decoding: units[token.location..<token.end], as: UTF16.self)
    }
}

/// A node of a `SyntaxTree`.
public struct SyntaxNode: Hashable, Sendable {
    public let tree: SyntaxTree
    let index: Int

    private var raw: SyntaxTree.RawNode { tree.nodes[index] }

    public var kind: SyntaxKind { raw.kind }
    /// The UTF-16 range from the node's first token to its last. A node with no tokens is empty at
    /// the position where it was started.
    public var range: NSRange { NSRange(location: raw.start, length: raw.end - raw.start) }
    public var text: String { String(decoding: tree.units[raw.start..<raw.end], as: UTF16.self) }

    public var parent: SyntaxNode? { raw.parent < 0 ? nil : SyntaxNode(tree: tree, index: raw.parent) }

    /// Tokens and nodes directly under this node, in text order.
    public var children: [SyntaxElement] {
        tree.children[raw.childStart..<(raw.childStart + raw.childCount)].map { child in
            child >= 0 ? .token(tree.tokens[Int(child)]) : .node(SyntaxNode(tree: tree, index: Int(~child)))
        }
    }

    public var childNodes: [SyntaxNode] {
        children.compactMap { if case .node(let node) = $0 { node } else { nil } }
    }

    /// Every token under this node, in order. Iterative: a tree can be as deep as the input nests.
    public var tokens: [SyntaxToken] {
        var result: [SyntaxToken] = []
        var stack = [(next: raw.childStart, end: raw.childStart + raw.childCount)]
        while let (next, end) = stack.last {
            guard next < end else {
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].next += 1
            let child = tree.children[next]
            if child >= 0 {
                result.append(tree.tokens[Int(child)])
            } else {
                let inner = tree.nodes[Int(~child)]
                stack.append((inner.childStart, inner.childStart + inner.childCount))
            }
        }
        return result
    }

    public static func == (lhs: SyntaxNode, rhs: SyntaxNode) -> Bool { lhs.tree === rhs.tree && lhs.index == rhs.index }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(tree))
        hasher.combine(index)
    }
}

public enum SyntaxElement: Hashable, Sendable {
    case token(SyntaxToken)
    case node(SyntaxNode)
}
