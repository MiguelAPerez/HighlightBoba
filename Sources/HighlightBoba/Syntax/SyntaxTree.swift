import Foundation

/// What a node is. Each language's parser declares its own (`SyntaxKind("call")`); highlight
/// queries match on the name.
public struct SyntaxKind: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { name }

    /// The node every tree has at the top, covering the whole text.
    public static let root = SyntaxKind("root")
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

    struct RawNode: Sendable {
        var kind: SyntaxKind
        var start: Int
        var end: Int
        var childStart: Int
        var childCount: Int
        var parent: Int
    }

    init(tokens: [SyntaxToken], units: [UInt16], nodes: [RawNode], children: [Int32]) {
        self.tokens = tokens
        self.units = units
        self.nodes = nodes
        self.children = children
    }

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

    /// Every token under this node, in order.
    public var tokens: [SyntaxToken] {
        children.flatMap { child -> [SyntaxToken] in
            switch child {
            case .token(let token): [token]
            case .node(let node): node.tokens
            }
        }
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
