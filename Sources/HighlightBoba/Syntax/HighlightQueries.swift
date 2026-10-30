import Foundation

/// A query file failed to load. The message names the query at fault.
public struct QueryError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One token's new scope, from a highlight query. `range` is always exactly one token of the tree.
public struct ScopeOverride: Hashable, Sendable {
    public let range: NSRange
    public let scope: String

    public init(range: NSRange, scope: String) {
        self.range = range
        self.scope = scope
    }
}

/// What running highlight queries over a tree, or one node of it, found: a new scope for some of
/// its tokens. Tokens are never split, merged or added, so applying it changes the scope of the
/// override ranges and nothing else.
public struct ScopeRefinement: Sendable {
    /// The text the run covered: the node it ran on.
    public let range: NSRange
    /// In text order, never overlapping. A token whose query gives it the scope it already has is left out.
    public let overrides: [ScopeOverride]
    let highlighter: UUID?
    let revision: Int
    /// Work done, for the linearity tests.
    let steps: Int

    /// `tokens` (sorted, not overlapping, as `Highlighter.tokens` gives them) with the overrides on
    /// top. A lexer span is cut only where an override starts or ends; an override over text the
    /// lexer left unscoped (an identifier) becomes a span of its own.
    public func apply(to tokens: [HighlightToken]) -> [HighlightToken] {
        var result: [HighlightToken] = []
        result.reserveCapacity(tokens.count + overrides.count)
        var next = 0
        // Where the overrides emitted so far end: a lexer span starting before that is clipped.
        var covered = 0
        for token in tokens {
            var from = max(token.range.location, covered)
            let end = NSMaxRange(token.range)
            while next < overrides.count && overrides[next].range.location < end {
                let override = overrides[next]
                if override.range.location > from {
                    result.append(HighlightToken(range: NSRange(location: from, length: override.range.location - from), scope: token.scope))
                }
                result.append(HighlightToken(range: override.range, scope: override.scope))
                covered = NSMaxRange(override.range)
                from = max(from, covered)
                next += 1
            }
            if from < end { result.append(HighlightToken(range: NSRange(location: from, length: end - from), scope: token.scope)) }
        }
        for override in overrides[next...] { result.append(HighlightToken(range: override.range, scope: override.scope)) }
        return result
    }
}

/// Highlight queries, format v1: data that maps tree patterns to scopes. See docs/QUERIES.md.
///
/// Compiled once, then run over any number of trees. A run is linear in the tree's size: each
/// significant token is checked against the queries for its token kind, and every check costs a
/// fixed amount, whatever the depth of the tree.
public final class HighlightQueries: Sendable {
    public let language: String
    let queries: [Query]
    /// Every node kind a query names, numbered.
    let kindIDs: [String: Int]
    /// Query indices that can match each `SyntaxToken.Kind`, in file order.
    let candidates: [[Int]]
    let errorKind: Int

    static let anyKind = -1
    static let unnamedKind = -2

    struct Query: Sendable {
        var scope: String
        var texts: [[UInt16]]?
        var tokenKind: SyntaxToken.Kind?
        var lexerScope: String?
        /// Kind ids from the token's parent outward; `anyKind` matches any node.
        var path: [Int]
        var index: Int?
        var after: [UInt16]?
        var before: [UInt16]?
        var inside: [Int]
        var notInside: [Int]
        /// Names `error` in `in` or `inside`, so it may match inside an error node.
        var matchesErrors: Bool
    }

    public convenience init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QueryError("queries are not valid JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else { throw QueryError("queries must be a JSON object") }
        try self.init(root: root)
    }

    private init(root: [String: Any]) throws {
        try Self.checkKeys(root, allowed: ["format", "language", "queries"], at: "queries")
        guard let format = root["format"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID(), format == 1 else {
            throw QueryError("queries need \"format\": 1 (got \(root["format"].map { "\($0)" } ?? "none"))")
        }
        guard let language = root["language"] as? String, !language.isEmpty else { throw QueryError("queries need a \"language\"") }
        guard let rawQueries = root["queries"] as? [Any] else { throw QueryError("queries for \(language) need a \"queries\" array") }

        var kindIDs = [SyntaxKind.error.name: 0]
        func kindID(_ name: String, at: String) throws -> Int {
            if name == "*" { return Self.anyKind }
            guard !name.isEmpty else { throw QueryError("\(at): empty node kind") }
            if let id = kindIDs[name] { return id }
            kindIDs[name] = kindIDs.count
            return kindIDs.count - 1
        }
        func kinds(_ any: Any?, key: String, at: String) throws -> [Int] {
            guard let any else { return [] }
            let names: [String]
            if let name = any as? String {
                names = [name]
            } else if let list = any as? [String], !list.isEmpty {
                names = list
            } else {
                throw QueryError("\(at): \"\(key)\" must be a node kind or a non-empty array of them")
            }
            let ids = try names.map { try kindID($0, at: at) }
            if key != "in" && ids.contains(Self.anyKind) { throw QueryError("\(at): \"*\" only stands for a node in \"in\"") }
            return ids
        }
        func text(_ any: Any?, key: String, at: String) throws -> [UInt16]? {
            guard let any else { return nil }
            guard let text = any as? String, !text.isEmpty else { throw QueryError("\(at): \"\(key)\" must be non-empty text") }
            return Array(text.utf16)
        }

        var queries: [Query] = []
        for (number, any) in rawQueries.enumerated() {
            let at = "\(language) query \(number)"
            guard let raw = any as? [String: Any] else { throw QueryError("\(at) must be an object") }
            try Self.checkKeys(raw, allowed: ["scope", "text", "kind", "lexerScope", "in", "index", "after", "before", "inside", "notInside"], at: at)
            guard let scope = raw["scope"] as? String, !scope.isEmpty else { throw QueryError("\(at) needs a \"scope\"") }

            var texts: [[UInt16]]?
            if let any = raw["text"] {
                if let one = any as? String, !one.isEmpty {
                    texts = [Array(one.utf16)]
                } else if let list = any as? [String], !list.isEmpty, !list.contains("") {
                    texts = list.map { Array($0.utf16) }
                } else {
                    throw QueryError("\(at): \"text\" must be non-empty text or a non-empty array of it")
                }
            }
            var tokenKind: SyntaxToken.Kind?
            if let any = raw["kind"] {
                switch any as? String {
                case "lexeme": tokenKind = .lexeme
                case "word": tokenKind = .word
                case "symbol": tokenKind = .symbol
                default: throw QueryError("\(at): \"kind\" must be \"lexeme\", \"word\" or \"symbol\"")
                }
            }
            var lexerScope: String?
            if let any = raw["lexerScope"] {
                guard let name = any as? String, !name.isEmpty else { throw QueryError("\(at): \"lexerScope\" must be a scope") }
                if tokenKind != nil && tokenKind != .lexeme { throw QueryError("\(at): only a lexeme has a lexer scope") }
                lexerScope = name
            }
            var index: Int?
            if let any = raw["index"] {
                guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let value = any as? Int else { throw QueryError("\(at): \"index\" must be an integer") }
                index = value
            }
            let path = try kinds(raw["in"], key: "in", at: at)
            let inside = try kinds(raw["inside"], key: "inside", at: at)
            let notInside = try kinds(raw["notInside"], key: "notInside", at: at)
            // `notInside` and an all-`*` path only rule tokens out, so alone they match nearly every token.
            guard texts != nil || tokenKind != nil || lexerScope != nil || index != nil || raw["after"] != nil
                    || raw["before"] != nil || !inside.isEmpty || path.contains(where: { $0 != Self.anyKind }) else {
                throw QueryError("\(at) needs a condition that narrows it (\"notInside\" or a path of \"*\" alone match nearly every token)")
            }
            queries.append(Query(scope: scope, texts: texts, tokenKind: tokenKind, lexerScope: lexerScope, path: path,
                                 index: index, after: try text(raw["after"], key: "after", at: at),
                                 before: try text(raw["before"], key: "before", at: at), inside: inside, notInside: notInside,
                                 matchesErrors: path.contains(0) || inside.contains(0)))
        }

        let kinds: [SyntaxToken.Kind] = [.lexeme, .word, .symbol]
        var candidates = Array(repeating: [Int](), count: Int(SyntaxToken.Kind.newline.rawValue) + 1)
        for kind in kinds {
            candidates[Int(kind.rawValue)] = queries.indices.filter { index in
                let query = queries[index]
                if let wanted = query.tokenKind, wanted != kind { return false }
                return query.lexerScope == nil || kind == .lexeme
            }
        }
        self.language = language
        self.queries = queries
        self.kindIDs = kindIDs
        self.candidates = candidates
        errorKind = 0
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>, at: String) throws {
        if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw QueryError("\(at): unknown key \(unknown.debugDescription)")
        }
    }

    // MARK: Running

    public func run(on tree: SyntaxTree) -> ScopeRefinement { run(on: tree.root) }

    /// Runs over `node` and everything under it. The nodes above it still count as context, so
    /// the result equals the whole-tree run's overrides inside `node.range`.
    public func run(on node: SyntaxNode) -> ScopeRefinement {
        let tree = node.tree
        var steps = 0
        // How many open nodes of each named kind enclose the current token: `inside` in O(1).
        var open = Array(repeating: 0, count: kindIDs.count)
        // The kinds of the open nodes, outermost first.
        var path: [Int] = []
        func kind(of index: Int) -> Int { kindIDs[tree.nodes[index].kind.name] ?? Self.unnamedKind }
        func enter(_ index: Int) {
            let id = kind(of: index)
            path.append(id)
            if id >= 0 { open[id] += 1 }
        }

        var above: [Int] = []
        var parent = tree.nodes[node.index].parent
        while parent >= 0 {
            above.append(parent)
            parent = tree.nodes[parent].parent
        }
        for index in above.reversed() { enter(index) }

        struct Frame {
            /// The node's children that aren't trivia, as in `SyntaxTree.children`.
            var significant: [Int32]
            var next = 0
        }
        func frame(_ index: Int) -> Frame {
            let raw = tree.nodes[index]
            var significant: [Int32] = []
            for child in tree.children[raw.childStart..<(raw.childStart + raw.childCount)]
            where child < 0 || !tree.tokens[Int(child)].isTrivia {
                significant.append(child)
            }
            steps += raw.childCount
            return Frame(significant: significant)
        }
        func isToken(_ child: Int32?, spelling text: [UInt16]?) -> Bool {
            guard let text else { return true }
            guard let child, child >= 0 else { return false }
            let token = tree.tokens[Int(child)]
            return tree.units[token.location..<token.end].elementsEqual(text)
        }

        var overrides: [ScopeOverride] = []
        enter(node.index)
        var stack = [frame(node.index)]
        while let top = stack.last {
            guard top.next < top.significant.count else {
                stack.removeLast()
                if let id = path.popLast(), id >= 0 { open[id] -= 1 }
                continue
            }
            let position = top.next
            stack[stack.count - 1].next += 1
            let child = top.significant[position]
            guard child >= 0 else {
                enter(Int(~child))
                stack.append(frame(Int(~child)))
                continue
            }
            let token = tree.tokens[Int(child)]
            let inError = open[errorKind] > 0
            queries: for index in candidates[Int(token.kind.rawValue)] {
                steps += 1
                let query = queries[index]
                if inError && !query.matchesErrors { continue }
                if let wanted = query.lexerScope?.utf16 {
                    // Compared in UTF-16 units throughout: `string` matches `string` and `string.quoted`, not `stringy`.
                    guard let scope = token.scope?.utf16, scope.starts(with: wanted),
                          scope.count == wanted.count || scope.dropFirst(wanted.count).first == 46
                    else { continue }
                }
                if let texts = query.texts {
                    let units = tree.units[token.location..<token.end]
                    guard texts.contains(where: { units.elementsEqual($0) }) else { continue }
                }
                if let wanted = query.index {
                    guard (wanted >= 0 ? wanted : top.significant.count + wanted) == position else { continue }
                }
                if query.path.count > path.count { continue }
                for (offset, wanted) in query.path.enumerated() where wanted != Self.anyKind && path[path.count - 1 - offset] != wanted {
                    continue queries
                }
                guard isToken(position > 0 ? top.significant[position - 1] : nil, spelling: query.after),
                      isToken(position + 1 < top.significant.count ? top.significant[position + 1] : nil, spelling: query.before)
                else { continue }
                for id in query.inside where open[id] == 0 { continue queries }
                for id in query.notInside where open[id] > 0 { continue queries }
                if query.scope != token.scope { overrides.append(ScopeOverride(range: token.range, scope: query.scope)) }
                break
            }
        }
        return ScopeRefinement(range: node.range, overrides: overrides, highlighter: tree.highlighter,
                               revision: tree.revision, steps: steps)
    }
}

extension Highlighter {
    /// The highlight with `refinement`'s overrides on top. Apply the tree's re-lexing first
    /// (`applyRelexing(of:)`), so the lexer's spans are the ones the tree was parsed from.
    /// - Returns: `nil` if the text was edited since the parse, or the tree came from another highlighter.
    public func tokens(refinedBy refinement: ScopeRefinement) -> [HighlightToken]? {
        guard refinement.highlighter == id, refinement.revision == revision else { return nil }
        return refinement.apply(to: tokens)
    }
}
