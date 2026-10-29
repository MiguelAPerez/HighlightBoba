import Foundation

/// A grammar failed to load. The message names the state and rule at fault.
public struct GrammarError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// The closed set of matchers. None of them backtracks, so a scan is linear in the input.
indirect enum Matcher: Sendable {
    case literal([UInt16])
    case oneOf(Int)
    case repeated(Int, min: Int, max: Int)
    case sequence([Matcher])
    case optional(Matcher)
    case endOfLine
    case words(Set<[UInt16]>, maxLength: Int)
    case wordStarting(Int)
}

struct Rule: Sendable {
    let matcher: Matcher
    let scope: Int?
    let push: Int?
    let pop: Int
    let notAfterWord: Bool
}

struct GrammarState: Sendable {
    let name: String
    let scope: Int?
    let endsAtEOL: Bool
    let rules: [Rule]
}

/// A compiled language grammar: named states, each an ordered list of rules that emit a scope and
/// push, pop or stay. See `docs/GRAMMAR.md` for the file format.
public final class Grammar: Sendable {
    public let name: String
    public let fileExtensions: [String]
    /// Every scope name the grammar can emit, indexed by the ids tokens carry internally.
    public let scopes: [String]
    let states: [GrammarState]
    let initial: Int
    let classes: [CharClass]
    let wordClass: Int

    /// The deepest the state stack may grow; deeper pushes are ignored so hostile nesting stays bounded.
    static let maxDepth = 128

    public convenience init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GrammarError("grammar is not valid JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else { throw GrammarError("grammar must be a JSON object") }
        try self.init(root: root)
    }

    /// Loads one of the grammars shipped in the package, e.g. `Grammar.bundled("swift")`.
    public static func bundled(_ name: String) throws -> Grammar {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Grammars") else {
            throw GrammarError("no bundled grammar named \(name.debugDescription)")
        }
        return try Grammar(data: Data(contentsOf: url))
    }

    /// The names of every grammar shipped in the package.
    public static var bundledNames: [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Grammars") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private init(root: [String: Any]) throws {
        try Self.checkKeys(root, allowed: ["name", "fileExtensions", "initial", "wordCharacters", "states"], at: "grammar")
        guard let name = root["name"] as? String, !name.isEmpty else { throw GrammarError("grammar needs a \"name\"") }
        guard let rawStates = root["states"] as? [String: Any], !rawStates.isEmpty else {
            throw GrammarError("grammar \(name) needs a non-empty \"states\" object")
        }
        guard let initialName = root["initial"] as? String else { throw GrammarError("grammar \(name) needs an \"initial\" state") }

        var builder = Builder()
        builder.wordClass = try builder.internClass(root["wordCharacters"] as? String ?? "[A-Za-z0-9_]")

        let stateNames = rawStates.keys.sorted()
        let stateIDs = Dictionary(uniqueKeysWithValues: stateNames.enumerated().map { ($1, $0) })
        guard let initial = stateIDs[initialName] else {
            throw GrammarError("grammar \(name): initial state \(initialName.debugDescription) is not defined")
        }

        enum RawRule { case rule(Rule), include(String) }
        var headers: [(scope: Int?, endsAtEOL: Bool)] = []
        var rawRules: [[RawRule]] = []
        for stateName in stateNames {
            let at = "state \(stateName)"
            guard let state = rawStates[stateName] as? [String: Any] else { throw GrammarError("\(at) must be an object") }
            try Self.checkKeys(state, allowed: ["scope", "endsAtEOL", "rules"], at: at)
            guard let rules = state["rules"] as? [Any] else { throw GrammarError("\(at) needs a \"rules\" array") }
            let scope = try (state["scope"] as? String).map { try builder.internScope($0, at: at) }
            headers.append((scope, state["endsAtEOL"] as? Bool ?? false))
            var parsed: [RawRule] = []
            for (index, any) in rules.enumerated() {
                let at = "\(at), rule \(index)"
                guard let rule = any as? [String: Any] else { throw GrammarError("\(at) must be an object") }
                if let include = rule["include"] as? String {
                    try Self.checkKeys(rule, allowed: ["include"], at: at)
                    guard stateIDs[include] != nil else { throw GrammarError("\(at) includes unknown state \(include.debugDescription)") }
                    parsed.append(.include(include))
                    continue
                }
                try Self.checkKeys(rule, allowed: ["match", "scope", "push", "pop", "notAfterWord"], at: at)
                guard let match = rule["match"] else { throw GrammarError("\(at) needs \"match\" or \"include\"") }
                let matcher = try builder.matcher(match, at: at)
                var push: Int?
                if let target = rule["push"] {
                    guard let target = target as? String, let id = stateIDs[target] else {
                        throw GrammarError("\(at) pushes unknown state \(String(describing: rule["push"]!))")
                    }
                    push = id
                }
                var pop = 0
                if let value = rule["pop"] {
                    guard let count = value as? Int, count >= 0 else { throw GrammarError("\(at): \"pop\" must be true or a count") }
                    pop = count
                }
                let scope = try (rule["scope"] as? String).map { try builder.internScope($0, at: at) }
                parsed.append(.rule(Rule(matcher: matcher, scope: scope, push: push, pop: pop,
                                         notAfterWord: rule["notAfterWord"] as? Bool ?? false)))
            }
            rawRules.append(parsed)
        }

        func flatten(_ id: Int, visiting: [Int]) throws -> [Rule] {
            guard !visiting.contains(id) else {
                let cycle = (visiting + [id]).map { stateNames[$0] }.joined(separator: " → ")
                throw GrammarError("grammar \(name): include cycle \(cycle)")
            }
            return try rawRules[id].flatMap { raw -> [Rule] in
                switch raw {
                case .rule(let rule): return [rule]
                case .include(let other): return try flatten(stateIDs[other]!, visiting: visiting + [id])
                }
            }
        }

        self.states = try stateNames.indices.map { id in
            GrammarState(name: stateNames[id], scope: headers[id].scope, endsAtEOL: headers[id].endsAtEOL,
                         rules: try flatten(id, visiting: []))
        }
        self.name = name
        self.fileExtensions = root["fileExtensions"] as? [String] ?? []
        self.initial = initial
        self.scopes = builder.scopes
        self.classes = builder.classes
        self.wordClass = builder.wordClass
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>, at: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw GrammarError("\(at): unknown key \(unknown.debugDescription)")
        }
    }

    private struct Builder {
        var scopes: [String] = []
        var scopeIDs: [String: Int] = [:]
        var classes: [CharClass] = []
        var classIDs: [String: Int] = [:]
        var wordClass = 0

        mutating func internScope(_ scope: String, at: String) throws -> Int {
            guard !scope.isEmpty else { throw GrammarError("\(at): empty scope") }
            if let id = scopeIDs[scope] { return id }
            scopes.append(scope)
            scopeIDs[scope] = scopes.count - 1
            return scopes.count - 1
        }

        mutating func internClass(_ source: String) throws -> Int {
            if let id = classIDs[source] { return id }
            classes.append(try CharClass.parse(source))
            classIDs[source] = classes.count - 1
            return classes.count - 1
        }

        mutating func matcher(_ any: Any, at: String) throws -> Matcher {
            guard let object = any as? [String: Any] else { throw GrammarError("\(at): a matcher must be an object") }
            if let literal = object["literal"] as? String {
                try Grammar.checkKeys(object, allowed: ["literal"], at: at)
                guard !literal.isEmpty else { throw GrammarError("\(at): empty literal") }
                return .literal(Array(literal.utf16))
            }
            if let words = object["words"] as? [String] {
                try Grammar.checkKeys(object, allowed: ["words"], at: at)
                guard !words.isEmpty, !words.contains("") else { throw GrammarError("\(at): \"words\" needs non-empty words") }
                let units = words.map { Array($0.utf16) }
                return .words(Set(units), maxLength: units.map(\.count).max()!)
            }
            if let source = object["class"] as? String {
                try Grammar.checkKeys(object, allowed: ["class"], at: at)
                return .oneOf(try internClass(source))
            }
            if let source = object["repeat"] as? String {
                try Grammar.checkKeys(object, allowed: ["repeat", "min", "max"], at: at)
                let min = object["min"] as? Int ?? 0
                let max = object["max"] as? Int ?? Int.max
                guard min >= 0, max >= 1, max >= min else { throw GrammarError("\(at): bad repeat bounds") }
                return .repeated(try internClass(source), min: min, max: max)
            }
            if let parts = object["seq"] as? [Any] {
                try Grammar.checkKeys(object, allowed: ["seq"], at: at)
                guard !parts.isEmpty else { throw GrammarError("\(at): empty seq") }
                return .sequence(try parts.map { try matcher($0, at: at) })
            }
            if let inner = object["opt"] {
                try Grammar.checkKeys(object, allowed: ["opt"], at: at)
                return .optional(try matcher(inner, at: at))
            }
            if object["eol"] as? Bool == true {
                try Grammar.checkKeys(object, allowed: ["eol"], at: at)
                return .endOfLine
            }
            if let source = object["wordStarting"] as? String {
                try Grammar.checkKeys(object, allowed: ["wordStarting"], at: at)
                return .wordStarting(try internClass(source))
            }
            throw GrammarError("\(at): unknown matcher \(object.keys.sorted())")
        }
    }
}
