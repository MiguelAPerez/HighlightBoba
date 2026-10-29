/// A token inside one line, at a UTF-16 offset from the line's start.
struct LineToken: Equatable, Sendable {
    var offset: Int
    var length: Int
    var scope: Int
}

/// Scans one line's content (no terminator) and advances the state stack.
///
/// Every matcher is deterministic: a repeat takes the whole run of its class and never gives any
/// back, and runs are cached per class, so each code unit is examined a bounded number of times.
struct LineScanner {
    let grammar: Grammar
    let units: [UInt16]
    let lineStart: Int
    let limit: Int
    private var runFrom: [Int]
    private var runTo: [Int]
    /// Work done, for the linearity tests.
    private(set) var steps = 0

    init(grammar: Grammar, units: [UInt16], lineStart: Int, limit: Int) {
        self.grammar = grammar
        self.units = units
        self.lineStart = lineStart
        self.limit = limit
        runFrom = Array(repeating: Int.max, count: grammar.classes.count)
        runTo = Array(repeating: Int.max, count: grammar.classes.count)
    }

    mutating func scan(stack: inout [Int]) -> [LineToken] {
        var tokens: [LineToken] = []
        func emit(_ start: Int, _ end: Int, _ scope: Int?) {
            guard let scope, end > start else { return }
            let offset = start - lineStart
            if let last = tokens.last, last.scope == scope, last.offset + last.length == offset {
                tokens[tokens.count - 1].length += end - start
            } else {
                tokens.append(LineToken(offset: offset, length: end - start, scope: scope))
            }
        }

        var position = lineStart
        while position < limit {
            let state = grammar.states[stack[stack.count - 1]]
            var advanced = false
            for rule in state.rules {
                if rule.notAfterWord && !notAfterWord(position) { continue }
                guard let end = match(rule.matcher, at: position) else { continue }
                // An empty match may only pop, and only when there is something to pop, so it can't loop.
                if end == position && (rule.pop == 0 || rule.push != nil || stack.count == 1) { continue }
                emit(position, end, rule.scope ?? state.scope)
                apply(rule, to: &stack)
                position = end
                advanced = true
                break
            }
            if !advanced {
                var end = position + 1
                if UTF16.isLeadSurrogate(units[position]), end < limit, UTF16.isTrailSurrogate(units[end]) { end += 1 }
                emit(position, end, state.scope)
                position = end
            }
        }

        // End of line: let `eol` rules pop, then drop states that never cross a line break.
        endOfLine: while stack.count > 1 {
            for rule in grammar.states[stack[stack.count - 1]].rules where rule.pop > 0 && rule.push == nil {
                if match(rule.matcher, at: limit) == limit {
                    apply(rule, to: &stack)
                    continue endOfLine
                }
            }
            break
        }
        while stack.count > 1, grammar.states[stack[stack.count - 1]].endsAtEOL {
            stack.removeLast()
        }
        return tokens
    }

    private func apply(_ rule: Rule, to stack: inout [Int]) {
        if rule.pop > 0 { stack.removeLast(min(rule.pop, stack.count - 1)) }
        if let push = rule.push, stack.count < Grammar.maxDepth { stack.append(push) }
    }

    @inline(__always)
    private func notAfterWord(_ position: Int) -> Bool {
        position == lineStart || !grammar.classes[grammar.wordClass].contains(units[position - 1])
    }

    /// The end of the run of `classID` members starting at `position`.
    private mutating func run(_ classID: Int, from position: Int) -> Int {
        if runFrom[classID] <= position && position <= runTo[classID] { return runTo[classID] }
        let members = grammar.classes[classID]
        var end = position
        while end < limit && members.contains(units[end]) { end += 1 }
        steps += end - position + 1
        runFrom[classID] = position
        runTo[classID] = end
        return end
    }

    private mutating func match(_ matcher: Matcher, at position: Int) -> Int? {
        steps += 1
        switch matcher {
        case .literal(let literal):
            guard position + literal.count <= limit else { return nil }
            for index in literal.indices where units[position + index] != literal[index] { return nil }
            return position + literal.count
        case .oneOf(let classID):
            return position < limit && grammar.classes[classID].contains(units[position]) ? position + 1 : nil
        case .repeated(let classID, let minimum, let maximum):
            let count = run(classID, from: position) - position
            return count >= minimum ? position + min(count, maximum) : nil
        case .sequence(let parts):
            var cursor = position
            for part in parts {
                guard let end = match(part, at: cursor) else { return nil }
                cursor = end
            }
            return cursor
        case .optional(let inner):
            return match(inner, at: position) ?? position
        case .endOfLine:
            return position == limit ? position : nil
        case .words(let words, let maxLength):
            guard notAfterWord(position) else { return nil }
            let end = run(grammar.wordClass, from: position)
            guard end > position, end - position <= maxLength, words.contains(Array(units[position..<end])) else { return nil }
            return end
        case .wordStarting(let classID):
            guard position < limit, notAfterWord(position), grammar.classes[classID].contains(units[position]) else { return nil }
            return max(run(grammar.wordClass, from: position), position + 1)
        }
    }
}
