/// A token inside one line, at a UTF-16 offset from the line's start.
struct LineToken: Equatable, Sendable {
    var offset: Int
    var length: Int
    /// An id in `Scopes.Table`.
    var scope: Int
}

/// One entry on the state stack. Besides the state it can carry what its push rule saved: a
/// delimiter to close on, the line's indentation, or an embedded grammar with its own stack.
/// Line-end snapshots compare all of it, so incremental re-scans stop only when it all matches.
struct Frame: Equatable, Sendable {
    var state: Int
    var remembered: [UInt16]?
    var indent: Int?
    var guest: Guest?

    init(state: Int, remembered: [UInt16]? = nil, indent: Int? = nil, guest: Guest? = nil) {
        self.state = state
        self.remembered = remembered
        self.indent = indent
        self.guest = guest
    }
}

/// An embedded grammar's own stack, e.g. Swift inside a Markdown fence.
struct Guest: Equatable, Sendable {
    let grammar: Grammar
    var stack: [Frame]

    static func == (lhs: Guest, rhs: Guest) -> Bool { lhs.grammar === rhs.grammar && lhs.stack == rhs.stack }
}

/// Scans one line's content (no terminator) and advances the state stack.
///
/// Every matcher is deterministic: a repeat takes the whole run of its class and never gives any
/// back, `anyOf` commits to its first match, and runs are cached per class, so each code unit is
/// examined a bounded number of times. Grammars are read from flat plain-data tables, so the hot
/// loop does no reference counting.
struct LineScanner {
    let units: [UInt16]
    let lineStart: Int
    let limit: Int
    let registry: GrammarRegistry
    /// Run caches as plain structs addressed by slot (0 is the host grammar), so the hot `run`
    /// path gets static exclusivity checks instead of a class's dynamic ones.
    private var caches: [RunCache] = []
    private var cacheSlots: [ObjectIdentifier: Int] = [:]
    private(set) var tokens: [LineToken] = []
    /// Work done, for the linearity tests.
    private(set) var steps = 0

    /// Deeper embedding (a fence inside a fence inside…) is highlighted by the host only.
    static let maxEmbedDepth = 4
    /// The longest delimiter a push rule may remember.
    static let maxRemembered = 256

    struct RunCache {
        var from: [Int]
        var to: [Int]
        init(count: Int) {
            from = Array(repeating: Int.max, count: count)
            to = Array(repeating: Int.max, count: count)
        }
    }

    init(units: [UInt16], lineStart: Int, limit: Int, registry: GrammarRegistry) {
        self.units = units
        self.lineStart = lineStart
        self.limit = limit
        self.registry = registry
    }

    mutating func scan(_ grammar: Grammar, stack: inout [Frame]) -> [LineToken] {
        caches = [RunCache(count: grammar.classes.count)]
        cacheSlots = [ObjectIdentifier(grammar): 0]
        let indent = lineIndent()
        if indent < limit - lineStart { dedent(grammar, &stack, indent: indent) }

        var position = lineStart
        while position < limit {
            position = step(grammar, &stack, at: position, depth: 0)
        }
        endLine(grammar, &stack, depth: 0)
        return tokens
    }

    // MARK: Line boundaries

    private func lineIndent() -> Int {
        var end = lineStart
        while end < limit && (units[end] == 32 || units[end] == 9) { end += 1 }
        return end - lineStart
    }

    /// Before a non-blank line: pop `endsAtDedent` states the line is not indented past.
    private func dedent(_ grammar: Grammar, _ stack: inout [Frame], indent: Int) {
        while stack.count > 1, let saved = stack[stack.count - 1].indent,
              grammar.states[stack[stack.count - 1].state].endsAtDedent, indent <= saved {
            stack.removeLast()
        }
        if var guest = stack[stack.count - 1].guest {
            stack[stack.count - 1].guest = nil
            dedent(guest.grammar, &guest.stack, indent: indent)
            stack[stack.count - 1].guest = guest
        }
    }

    /// At the line end: embedded grammars first, then `eol` rules pop, then states that never cross a line break.
    private mutating func endLine(_ grammar: Grammar, _ stack: inout [Frame], depth: Int) {
        if var guest = stack[stack.count - 1].guest {
            stack[stack.count - 1].guest = nil
            endLine(guest.grammar, &guest.stack, depth: depth + 1)
            stack[stack.count - 1].guest = guest
        }
        let cache = slot(for: grammar, depth: depth)
        endOfLine: while stack.count > 1 {
            let state = grammar.states[stack[stack.count - 1].state]
            let remembered = stack[stack.count - 1].remembered
            for index in Int(state.ruleStart)..<Int(state.ruleStart + state.ruleCount) {
                let rule = grammar.rules[index]
                guard rule.pop > 0 && rule.push < 0 else { continue }
                if match(rule.matcher, grammar, cache, remembered, at: limit) == limit {
                    stack.removeLast(min(Int(rule.pop), stack.count - 1))
                    continue endOfLine
                }
            }
            break
        }
        while stack.count > 1, grammar.states[stack[stack.count - 1].state].endsAtEOL {
            stack.removeLast()
        }
    }

    // MARK: Stepping

    /// Takes one step at `position` and returns where the next starts: past the first rule that
    /// matched, past one character if none did, or at `position` after an empty pop.
    private mutating func step(_ grammar: Grammar, _ stack: inout [Frame], at position: Int, depth: Int) -> Int {
        let top = stack.count - 1
        let state = grammar.states[stack[top].state]
        let remembered = stack[top].remembered
        let cache = slot(for: grammar, depth: depth)
        for index in Int(state.ruleStart)..<Int(state.ruleStart + state.ruleCount) {
            let rule = grammar.rules[index]
            if rule.notAfterWord && !notAfterWord(position, grammar) { continue }
            if rule.notAfter >= 0 && !notAfter(position, grammar.classes[Int(rule.notAfter)]) { continue }
            var bounds: [Int]?
            let end: Int
            if rule.needsParts {
                guard let found = matchParts(rule.matcher, grammar, cache, remembered, at: position) else { continue }
                bounds = found
                end = found[found.count - 1]
            } else {
                guard let found = match(rule.matcher, grammar, cache, remembered, at: position) else { continue }
                end = found
            }
            // An empty match may only pop, and only when there is something to pop, so it can't loop.
            if end == position && (rule.pop == 0 || rule.push >= 0 || stack.count == 1) { continue }
            let base = rule.scope >= 0 ? rule.scope : state.scope
            if rule.capturesCount > 0, let bounds {
                for part in 0..<Int(rule.capturesCount) {
                    let capture = grammar.capturePool[Int(rule.capturesStart) + part]
                    emit(bounds[part], bounds[part + 1], capture >= 0 ? capture : base, grammar)
                }
            } else {
                emit(position, end, base, grammar)
            }
            apply(rule, grammar, &stack, from: position, to: end, bounds: bounds, depth: depth)
            return end
        }
        if var guest = stack[top].guest {
            stack[top].guest = nil
            let end = step(guest.grammar, &guest.stack, at: position, depth: depth + 1)
            stack[top].guest = guest
            return end
        }
        var end = position + 1
        if UTF16.isLeadSurrogate(units[position]), end < limit, UTF16.isTrailSurrogate(units[end]) { end += 1 }
        emit(position, end, state.scope, grammar)
        return end
    }

    private func apply(_ rule: FlatRule, _ grammar: Grammar, _ stack: inout [Frame],
                       from start: Int, to end: Int, bounds: [Int]?, depth: Int) {
        if rule.pop > 0 { stack.removeLast(min(Int(rule.pop), stack.count - 1)) }
        guard rule.push >= 0, stack.count < Grammar.maxDepth else { return }
        func text(part: Int32) -> [UInt16] {
            part < 0 ? Array(units[start..<end]) : Array(units[bounds![Int(part)]..<bounds![Int(part) + 1]])
        }
        var frame = Frame(state: Int(rule.push))
        if rule.remember > -2 { frame.remembered = Array(text(part: rule.remember).prefix(Self.maxRemembered)) }
        if rule.rememberIndent { frame.indent = lineIndent() }
        if depth < Self.maxEmbedDepth, rule.embedName >= 0 || rule.embedPart >= 0 {
            let name = rule.embedName >= 0
                ? grammar.embedNames[Int(rule.embedName)]
                : String(decoding: text(part: rule.embedPart), as: UTF16.self)
            if let guest = registry.grammar(named: name) {
                frame.guest = Guest(grammar: guest, stack: [Frame(state: guest.initial)])
            }
        }
        stack.append(frame)
    }

    private mutating func emit(_ start: Int, _ end: Int, _ scope: Int32, _ grammar: Grammar) {
        guard scope >= 0, end > start else { return }
        let id = grammar.scopeIDs[Int(scope)]
        let offset = start - lineStart
        if let last = tokens.last, last.scope == id, last.offset + last.length == offset {
            tokens[tokens.count - 1].length += end - start
        } else {
            tokens.append(LineToken(offset: offset, length: end - start, scope: id))
        }
    }

    // MARK: Matching

    private mutating func slot(for grammar: Grammar, depth: Int) -> Int {
        if depth == 0 { return 0 }
        let key = ObjectIdentifier(grammar)
        if let slot = cacheSlots[key] { return slot }
        caches.append(RunCache(count: grammar.classes.count))
        cacheSlots[key] = caches.count - 1
        return caches.count - 1
    }

    @inline(__always)
    private func notAfterWord(_ position: Int, _ grammar: Grammar) -> Bool {
        position == lineStart || !grammar.classes[grammar.wordClass].contains(units[position - 1])
    }

    /// The previous non-blank character on this line is not in `members`; the line start counts as not-after.
    private func notAfter(_ position: Int, _ members: CharClass) -> Bool {
        var index = position - 1
        while index >= lineStart && (units[index] == 32 || units[index] == 9) { index -= 1 }
        return index < lineStart || !members.contains(units[index])
    }

    /// The end of the run of `classID` members starting at `position`.
    private mutating func run(_ classID: Int, _ grammar: Grammar, _ cache: Int, from position: Int) -> Int {
        if caches[cache].from[classID] <= position && position <= caches[cache].to[classID] { return caches[cache].to[classID] }
        var end = position
        while end < limit && grammar.classes[classID].contains(units[end]) { end += 1 }
        steps += end - position + 1
        caches[cache].from[classID] = position
        caches[cache].to[classID] = end
        return end
    }

    /// Matches a top-level `seq` and returns where each part starts, plus the end. Most attempts
    /// fail, so the parts are matched once without allocating before any bounds are recorded.
    private mutating func matchParts(_ index: Int32, _ grammar: Grammar, _ cache: Int,
                                     _ remembered: [UInt16]?, at position: Int) -> [Int]? {
        guard match(index, grammar, cache, remembered, at: position) != nil else { return nil }
        let node = grammar.nodes[Int(index)]
        var bounds = [position]
        bounds.reserveCapacity(Int(node.b) + 1)
        for part in 0..<Int(node.b) {
            guard let end = match(grammar.children[Int(node.a) + part], grammar, cache, remembered,
                                  at: bounds[bounds.count - 1]) else { return nil }
            bounds.append(end)
        }
        return bounds
    }

    private mutating func match(_ index: Int32, _ grammar: Grammar, _ cache: Int,
                                _ remembered: [UInt16]?, at position: Int) -> Int? {
        steps += 1
        let node = grammar.nodes[Int(index)]
        switch node.kind {
        case .literal:
            let length = Int(node.b)
            guard position + length <= limit else { return nil }
            for offset in 0..<length where units[position + offset] != grammar.pool[Int(node.a) + offset] { return nil }
            return position + length
        case .oneOf:
            return position < limit && grammar.classes[Int(node.a)].contains(units[position]) ? position + 1 : nil
        case .repeated:
            let count = run(Int(node.a), grammar, cache, from: position) - position
            return count >= Int(node.b) ? position + min(count, Int(node.c)) : nil
        case .sequence:
            var cursor = position
            for part in 0..<Int(node.b) {
                guard let end = match(grammar.children[Int(node.a) + part], grammar, cache, remembered, at: cursor) else { return nil }
                cursor = end
            }
            return cursor
        case .optional:
            return match(node.a, grammar, cache, remembered, at: position) ?? position
        case .endOfLine:
            return position == limit ? position : nil
        case .words:
            guard notAfterWord(position, grammar) else { return nil }
            let end = run(grammar.wordClass, grammar, cache, from: position)
            guard end > position, grammar.wordSets[Int(node.a)].contains(units, from: position, to: end) else { return nil }
            return end
        case .wordStarting:
            guard position < limit, notAfterWord(position, grammar), grammar.classes[Int(node.a)].contains(units[position]) else { return nil }
            return max(run(grammar.wordClass, grammar, cache, from: position), position + 1)
        case .anyOf:
            for option in 0..<Int(node.b) {
                if let end = match(grammar.children[Int(node.a) + option], grammar, cache, remembered, at: position) { return end }
            }
            return nil
        case .followedBy:
            return match(node.a, grammar, cache, remembered, at: position) == nil ? nil : position
        case .notFollowedBy:
            return match(node.a, grammar, cache, remembered, at: position) == nil ? position : nil
        case .remembered:
            guard let remembered, !remembered.isEmpty, position + remembered.count <= limit else { return nil }
            for offset in remembered.indices where units[position + offset] != remembered[offset] { return nil }
            return position + remembered.count
        case .beginningOfLine:
            return position == lineStart ? position : nil
        }
    }
}
