import Foundation

/// Resolves the grammars a host grammar embeds, by name or file extension (`swift`, `py`, `JSON`).
public final class GrammarRegistry: @unchecked Sendable {
    /// The bundled grammars, plus anything registered on it.
    public static let shared = GrammarRegistry(loadsBundled: true)

    private let loadsBundled: Bool
    private let lock = NSLock()
    private var byName: [String: Grammar] = [:]
    private var bundledLoaded = false

    /// A registry with only the grammars you register, for tests and custom setups.
    public convenience init() { self.init(loadsBundled: false) }

    private init(loadsBundled: Bool) { self.loadsBundled = loadsBundled }

    /// Makes `grammar` resolvable by its name and each of its file extensions.
    public func register(_ grammar: Grammar) {
        lock.withLock { add(grammar) }
    }

    public func grammar(named name: String) -> Grammar? {
        let key = name.lowercased()
        guard !key.isEmpty else { return nil }
        return lock.withLock {
            if let grammar = byName[key] { return grammar }
            if loadsBundled && !bundledLoaded {
                bundledLoaded = true
                for bundled in Grammar.bundledNames {
                    if let grammar = try? Grammar.bundled(bundled), byName[grammar.name.lowercased()] == nil { add(grammar) }
                }
            }
            return byName[key]
        }
    }

    private func add(_ grammar: Grammar) {
        byName[grammar.name.lowercased()] = grammar
        for ext in grammar.fileExtensions where byName[ext.lowercased()] == nil {
            byName[ext.lowercased()] = grammar
        }
    }
}
