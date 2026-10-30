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
    case words(WordSet)
    case wordStarting(Int)
    case anyOf([Matcher])
    case followedBy(Matcher)
    case notFollowedBy(Matcher)
    case remembered
    case beginningOfLine
}

/// Whole words grouped by length, so a lookup compares a few same-length candidates in place
/// instead of allocating an array for the slice.
struct WordSet: Sendable {
    let byLength: [[[UInt16]]]

    init(_ words: [[UInt16]]) {
        var buckets = Array(repeating: [[UInt16]](), count: (words.map(\.count).max() ?? 0) + 1)
        for word in Set(words) { buckets[word.count].append(word) }
        byLength = buckets
    }

    func contains(_ units: [UInt16], from start: Int, to end: Int) -> Bool {
        let length = end - start
        guard length < byLength.count else { return false }
        candidates: for word in byLength[length] {
            for index in 0..<length where word[index] != units[start + index] { continue candidates }
            return true
        }
        return false
    }
}

/// A matcher compiled into a flat node table. Plain data, so the scanner reads it without any
/// reference counting; children live in `Grammar.children`, literal text in `Grammar.pool`.
struct Node: Sendable {
    enum Kind: UInt8, Sendable {
        case literal, oneOf, repeated, sequence, optional, endOfLine, words, wordStarting
        case anyOf, followedBy, notFollowedBy, remembered, beginningOfLine
    }
    var kind: Kind
    var a: Int32 = 0
    var b: Int32 = 0
    var c: Int32 = 0
}

/// A rule compiled to plain data. `-1` means absent throughout.
struct FlatRule: Sendable {
    var matcher: Int32
    var scope: Int32
    var push: Int32
    var pop: Int32
    var notAfter: Int32
    /// Range in `Grammar.capturePool`; a count of 0 means no captures. Entries are scope ids or -1.
    var capturesStart: Int32
    var capturesCount: Int32
    /// -2 none, -1 the whole match, otherwise a `seq` part index.
    var remember: Int32
    var embedPart: Int32
    /// Index in `Grammar.embedNames`.
    var embedName: Int32
    var notAfterWord: Bool
    var rememberIndent: Bool
    var needsParts: Bool
    /// The push takes effect at the end of the line (heredoc bodies start on the next line).
    var pushAtNextLine: Bool
    /// A match that reaches the line end keeps `endsAtEOL` states open (backslash continuation).
    var continuesLine: Bool
}

struct FlatState: Sendable {
    var scope: Int32
    var endsAtEOL: Bool
    /// Shields the states below it from `endsAtEOL` (Python f-string fields cross line breaks).
    var spansLines: Bool
    var endsAtDedent: Bool
    var ruleStart: Int32
    var ruleCount: Int32
}

/// What a push rule saves on the new stack entry: the whole match or one `seq` part.
enum MatchSlice: Sendable {
    case whole
    case part(Int)
}

/// Which grammar a push rule embeds: a fixed name, or the text of one `seq` part (a fence's language).
enum EmbedSource: Sendable {
    case named(String)
    case part(Int)
}

/// A parsed rule, before `Compiler` lowers it to a `FlatRule`.
final class Rule: Sendable {
    let matcher: Matcher
    let scope: Int?
    let push: Int?
    let pop: Int
    let notAfterWord: Bool
    /// The previous non-blank character on the line must not be in this class.
    let notAfter: Int?
    /// One scope per top-level `seq` part; `nil` parts take the rule's scope.
    let captures: [Int?]?
    let remember: MatchSlice?
    let rememberIndent: Bool
    let embed: EmbedSource?
    let pushAtNextLine: Bool
    let continuesLine: Bool
    /// Whether matching must record where each `seq` part ends.
    let needsParts: Bool

    init(matcher: Matcher, scope: Int?, push: Int?, pop: Int, notAfterWord: Bool, notAfter: Int?,
         captures: [Int?]?, remember: MatchSlice?, rememberIndent: Bool, embed: EmbedSource?, pushAtNextLine: Bool,
         continuesLine: Bool = false) {
        self.matcher = matcher
        self.scope = scope
        self.push = push
        self.pop = pop
        self.notAfterWord = notAfterWord
        self.notAfter = notAfter
        self.captures = captures
        self.remember = remember
        self.rememberIndent = rememberIndent
        self.embed = embed
        self.pushAtNextLine = pushAtNextLine
        self.continuesLine = continuesLine
        var parts = captures != nil
        if case .part = remember { parts = true }
        if case .part = embed { parts = true }
        needsParts = parts
    }
}

/// A compiled language grammar: named states, each an ordered list of rules that emit a scope and
/// push, pop or stay. See `docs/GRAMMAR.md` for the file format.
public final class Grammar: Sendable {
    public let name: String
    public let fileExtensions: [String]
    /// Every scope name the grammar can emit.
    public let scopes: [String]
    /// `scopes[i]`'s id in `Scopes.Table`.
    let scopeIDs: [Int]
    let stateNames: [String]
    let states: [FlatState]
    let rules: [FlatRule]
    let nodes: [Node]
    let children: [Int32]
    let pool: [UInt16]
    let wordSets: [WordSet]
    let capturePool: [Int32]
    let embedNames: [String]
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
        var headers: [(scope: Int?, endsAtEOL: Bool, spansLines: Bool, endsAtDedent: Bool)] = []
        var rawRules: [[RawRule]] = []
        for stateName in stateNames {
            let at = "state \(stateName)"
            guard let state = rawStates[stateName] as? [String: Any] else { throw GrammarError("\(at) must be an object") }
            try Self.checkKeys(state, allowed: ["scope", "endsAtEOL", "spansLines", "endsAtDedent", "rules"], at: at)
            guard let rules = state["rules"] as? [Any] else { throw GrammarError("\(at) needs a \"rules\" array") }
            let scope = try (state["scope"] as? String).map { try builder.internScope($0, at: at) }
            headers.append((scope, state["endsAtEOL"] as? Bool ?? false, state["spansLines"] as? Bool ?? false,
                            state["endsAtDedent"] as? Bool ?? false))
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
                try Self.checkKeys(rule, allowed: ["match", "scope", "push", "pop", "notAfterWord", "notAfter", "captures",
                                                   "remember", "rememberIndent", "embed", "embedPart", "pushAtNextLine",
                                                   "continuesLine"], at: at)
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
                var partCount: Int?
                if case .sequence(let parts) = matcher { partCount = parts.count }
                func partIndex(_ key: String) throws -> Int {
                    guard let index = rule[key] as? Int, let partCount, (0..<partCount).contains(index) else {
                        throw GrammarError("\(at): \"\(key)\" must index a part of a \"seq\" matcher")
                    }
                    return index
                }
                var captures: [Int?]?
                if let raw = rule["captures"] {
                    guard let list = raw as? [Any], list.count == partCount else {
                        throw GrammarError("\(at): \"captures\" needs one entry per part of a \"seq\" matcher")
                    }
                    captures = try list.map { entry in
                        if entry is NSNull { return nil }
                        guard let name = entry as? String else { throw GrammarError("\(at): a capture is a scope or null") }
                        return try builder.internScope(name, at: at)
                    }
                }
                var remember: MatchSlice?
                if let raw = rule["remember"] {
                    if Self.isJSONBool(raw) {
                        remember = raw as? Bool == true ? .whole : nil
                    } else {
                        remember = .part(try partIndex("remember"))
                    }
                }
                var embed: EmbedSource?
                if let name = rule["embed"] as? String {
                    embed = .named(name)
                } else if rule["embedPart"] != nil {
                    embed = .part(try partIndex("embedPart"))
                }
                let rememberIndent = rule["rememberIndent"] as? Bool ?? false
                let pushAtNextLine = rule["pushAtNextLine"] as? Bool ?? false
                if push == nil, remember != nil || embed != nil || rememberIndent || pushAtNextLine {
                    throw GrammarError("\(at): \"remember\", \"rememberIndent\", \"embed\" and \"pushAtNextLine\" act on the pushed state, so the rule needs \"push\"")
                }
                let notAfter = try (rule["notAfter"] as? String).map { try builder.internClass($0) }
                parsed.append(.rule(Rule(matcher: matcher, scope: scope, push: push, pop: pop,
                                         notAfterWord: rule["notAfterWord"] as? Bool ?? false, notAfter: notAfter,
                                         captures: captures, remember: remember, rememberIndent: rememberIndent, embed: embed,
                                         pushAtNextLine: pushAtNextLine,
                                         continuesLine: rule["continuesLine"] as? Bool ?? false)))
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

        var compiler = Compiler()
        var flatStates: [FlatState] = []
        for id in stateNames.indices {
            let rules = try flatten(id, visiting: [])
            let start = Int32(compiler.rules.count)
            for rule in rules { compiler.add(rule) }
            flatStates.append(FlatState(scope: Int32(headers[id].scope ?? -1), endsAtEOL: headers[id].endsAtEOL,
                                        spansLines: headers[id].spansLines, endsAtDedent: headers[id].endsAtDedent, ruleStart: start, ruleCount: Int32(rules.count)))
        }
        self.stateNames = stateNames
        self.states = flatStates
        self.rules = compiler.rules
        self.nodes = compiler.nodes
        self.children = compiler.children
        self.pool = compiler.pool
        self.wordSets = compiler.wordSets
        self.capturePool = compiler.capturePool
        self.embedNames = compiler.embedNames
        self.name = name
        self.fileExtensions = root["fileExtensions"] as? [String] ?? []
        self.initial = initial
        self.scopes = builder.scopes
        self.scopeIDs = builder.scopes.map { Scopes.Table.shared.id(for: $0) }
        self.classes = builder.classes
        self.wordClass = builder.wordClass
    }

    /// Lowers parsed rules and matchers into the flat tables the scanner reads.
    private struct Compiler {
        var rules: [FlatRule] = []
        var nodes: [Node] = []
        var children: [Int32] = []
        var pool: [UInt16] = []
        var wordSets: [WordSet] = []
        var capturePool: [Int32] = []
        var embedNames: [String] = []

        mutating func add(_ rule: Rule) {
            var flat = FlatRule(matcher: compile(rule.matcher), scope: Int32(rule.scope ?? -1), push: Int32(rule.push ?? -1),
                                pop: Int32(rule.pop), notAfter: Int32(rule.notAfter ?? -1), capturesStart: 0, capturesCount: 0,
                                remember: -2, embedPart: -1, embedName: -1, notAfterWord: rule.notAfterWord,
                                rememberIndent: rule.rememberIndent, needsParts: rule.needsParts,
                                pushAtNextLine: rule.pushAtNextLine, continuesLine: rule.continuesLine)
            if let captures = rule.captures {
                flat.capturesStart = Int32(capturePool.count)
                flat.capturesCount = Int32(captures.count)
                capturePool += captures.map { Int32($0 ?? -1) }
            }
            switch rule.remember {
            case .whole: flat.remember = -1
            case .part(let index): flat.remember = Int32(index)
            case nil: break
            }
            switch rule.embed {
            case .named(let name):
                flat.embedName = Int32(embedNames.count)
                embedNames.append(name)
            case .part(let index): flat.embedPart = Int32(index)
            case nil: break
            }
            rules.append(flat)
        }

        mutating func compile(_ matcher: Matcher) -> Int32 {
            func node(_ kind: Node.Kind, _ a: Int = 0, _ b: Int = 0, _ c: Int = 0) -> Int32 {
                nodes.append(Node(kind: kind, a: Int32(clamping: a), b: Int32(clamping: b), c: Int32(clamping: c)))
                return Int32(nodes.count - 1)
            }
            func list(_ matchers: [Matcher]) -> (start: Int, count: Int) {
                let compiled = matchers.map { compile($0) }
                let start = children.count
                children += compiled
                return (start, compiled.count)
            }
            switch matcher {
            case .literal(let literal):
                pool += literal
                return node(.literal, pool.count - literal.count, literal.count)
            case .oneOf(let classID): return node(.oneOf, classID)
            case .repeated(let classID, let minimum, let maximum): return node(.repeated, classID, minimum, maximum)
            case .sequence(let parts):
                let (start, count) = list(parts)
                return node(.sequence, start, count)
            case .optional(let inner):
                let child = compile(inner)
                return node(.optional, Int(child))
            case .endOfLine: return node(.endOfLine)
            case .words(let words):
                wordSets.append(words)
                return node(.words, wordSets.count - 1)
            case .wordStarting(let classID): return node(.wordStarting, classID)
            case .anyOf(let options):
                let (start, count) = list(options)
                return node(.anyOf, start, count)
            case .followedBy(let inner):
                let child = compile(inner)
                return node(.followedBy, Int(child))
            case .notFollowedBy(let inner):
                let child = compile(inner)
                return node(.notFollowedBy, Int(child))
            case .remembered: return node(.remembered)
            case .beginningOfLine: return node(.beginningOfLine)
            }
        }
    }

    /// `true` and `1` both bridge to `NSNumber`; only a JSON boolean has the boolean type id.
    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
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
                return .words(WordSet(words.map { Array($0.utf16) }))
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
            if let options = object["anyOf"] as? [Any] {
                try Grammar.checkKeys(object, allowed: ["anyOf"], at: at)
                guard !options.isEmpty else { throw GrammarError("\(at): empty anyOf") }
                return .anyOf(try options.map { try matcher($0, at: at) })
            }
            if let inner = object["followedBy"] {
                try Grammar.checkKeys(object, allowed: ["followedBy"], at: at)
                return .followedBy(try matcher(inner, at: at))
            }
            if let inner = object["notFollowedBy"] {
                try Grammar.checkKeys(object, allowed: ["notFollowedBy"], at: at)
                return .notFollowedBy(try matcher(inner, at: at))
            }
            if object["remembered"] as? Bool == true {
                try Grammar.checkKeys(object, allowed: ["remembered"], at: at)
                return .remembered
            }
            if object["bol"] as? Bool == true {
                try Grammar.checkKeys(object, allowed: ["bol"], at: at)
                return .beginningOfLine
            }
            throw GrammarError("\(at): unknown matcher \(object.keys.sorted())")
        }
    }
}
