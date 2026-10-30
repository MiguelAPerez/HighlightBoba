import Foundation

/// The parser and highlight queries of each language that has them. Languages without a parser
/// (JSON, YAML, Markdown, Go) have neither and highlight from the lexer alone.
public enum LanguageParsers {
    /// The parser for a grammar, by the grammar's name.
    public static func parser(for language: String) -> (any IncrementalParser)? {
        switch language {
        case "javascript": JSParser(dialect: .javascript)
        case "typescript": JSParser(dialect: .typescript)
        default: nil
        }
    }

    /// The bundled highlight queries for a grammar (`Queries/<name>.json`), compiled once.
    public static func queries(for language: String) -> HighlightQueries? {
        cache.withLock { loaded in
            if let queries = loaded[language] { return queries }
            guard let url = Bundle.module.url(forResource: language, withExtension: "json", subdirectory: "Queries"),
                  let data = try? Data(contentsOf: url) else { return nil }
            let queries = try? HighlightQueries(data: data)
            loaded[language] = queries
            return queries
        }
    }

    /// The names of every bundled query file.
    public static var bundledQueryNames: [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Queries") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private static let cache = Locked<[String: HighlightQueries?]>([:])
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
