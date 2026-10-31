import Foundation

/// A language's parser and its highlight queries, for the languages that have a parser. The
/// others highlight with their lexer alone.
public struct LanguageSupport: Sendable {
    public let parser: any IncrementalParser
    public let queries: HighlightQueries

    public init(parser: any IncrementalParser, queries: HighlightQueries) {
        self.parser = parser
        self.queries = queries
    }

    /// The parsers shipped in the package, by grammar name. Their queries are `Queries/<name>.json`.
    static let bundledParsers: [String: any IncrementalParser] = [
        "swift": SwiftParser(),
        "javascript": JSParser(dialect: .javascript),
        "typescript": JSParser(dialect: .typescript)
    ]

    private static let cache = Cache()

    /// The bundled parser and queries for a grammar, or `nil` for a lexer-only language.
    public static func bundled(for grammarName: String) -> LanguageSupport? {
        let name = grammarName.lowercased()
        guard let parser = bundledParsers[name] else { return nil }
        return cache.support(named: name) {
            guard let queries = try? HighlightQueries.bundled(name) else { return nil }
            return LanguageSupport(parser: parser, queries: queries)
        }
    }

    /// The full highlight of `text`: lexed, parsed, re-lexed where the parse asked, then refined
    /// by the queries. A language without a parser gets the lexer's highlight.
    public static func highlight(_ text: String, grammar: Grammar, registry: GrammarRegistry = .shared) -> [HighlightToken] {
        let highlighter = Highlighter(grammar: grammar, text: text, registry: registry)
        guard let support = bundled(for: grammar.name) else { return highlighter.tokens }
        return support.highlight(highlighter)
    }

    /// `highlighter`'s current text, parsed and refined. Applies the parse's re-lexing to it.
    public func highlight(_ highlighter: Highlighter) -> [HighlightToken] {
        let tree = parser.parse(highlighter.snapshot).tree
        _ = highlighter.applyRelexing(of: tree)
        return highlighter.tokens(refinedBy: queries.run(on: tree)) ?? highlighter.tokens
    }

    /// Loaded queries, so each file is compiled once.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [String: LanguageSupport?] = [:]

        func support(named name: String, load: () -> LanguageSupport?) -> LanguageSupport? {
            lock.withLock {
                if let support = loaded[name] { return support }
                let support = load()
                loaded[name] = support
                return support
            }
        }
    }
}

extension HighlightQueries {
    /// Loads the queries shipped in the package for a grammar, e.g. `HighlightQueries.bundled("swift")`.
    public static func bundled(_ name: String) throws -> HighlightQueries {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Queries") else {
            throw QueryError("no bundled queries named \(name.debugDescription)")
        }
        return try HighlightQueries(data: Data(contentsOf: url))
    }
}
