import Foundation

/// The lexer's view of a text: its code units, each line's tokens and end-of-line stack, and the
/// places a parser asked for a token to be lexed another way. A value, so a parser can take a copy
/// off the main thread while the highlighter keeps editing its own.
struct Lexing: Sendable {
    let grammar: Grammar
    let registry: GrammarRegistry
    var units: [UInt16]
    var lines: [Line] = []
    /// Where the lexer steps with another state's rules, ascending by location.
    var overrides: [Override] = []

    struct Line: Equatable, Sendable {
        var start: Int
        var contentLength: Int
        var terminatorLength: Int
        var tokens: [LineToken]
        var endStack: [Frame]

        var end: Int { start + contentLength + terminatorLength }
    }

    /// At `location`, the lexer tries `state`'s rules before the current state's.
    struct Override: Equatable, Sendable {
        var location: Int
        var state: Int
    }

    struct Scan {
        var lines: [Line]
        /// Where the stop condition accepted a line start, or `nil` if the text ran out first.
        var stoppedAt: Int?
        var steps: Int
        /// The override locations whose state had a rule that matched.
        var applied: [Int]
    }

    /// Lexes all of `units`; `steps` is the scanner work it took.
    init(grammar: Grammar, registry: GrammarRegistry, units: [UInt16], steps: inout Int) {
        self.grammar = grammar
        self.registry = registry
        self.units = units
        let scan = scan(from: 0, stack: initialStack) { _, _ in false }
        lines = scan.lines
        steps = scan.steps
    }

    var initialStack: [Frame] { [Frame(state: grammar.initial)] }

    func startStack(ofLine index: Int) -> [Frame] { index == 0 ? initialStack : lines[index - 1].endStack }

    func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func lineIndex(startingAt location: Int) -> Int? {
        let index = lineIndex(containing: location)
        return lines[index].start == location ? index : nil
    }

    // MARK: Overrides

    /// The first override at or after `location`.
    private func overrideSlot(atOrAfter location: Int) -> Int {
        var low = 0
        var high = overrides.count
        while low < high {
            let mid = (low + high) / 2
            if overrides[mid].location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func override(at location: Int) -> Int? {
        let slot = overrideSlot(atOrAfter: location)
        return slot < overrides.count && overrides[slot].location == location ? overrides[slot].state : nil
    }

    mutating func setOverride(at location: Int, state: Int) {
        let slot = overrideSlot(atOrAfter: location)
        if slot < overrides.count && overrides[slot].location == location {
            overrides[slot].state = state
        } else {
            overrides.insert(Override(location: location, state: state), at: slot)
        }
    }

    mutating func removeOverride(at location: Int) {
        let slot = overrideSlot(atOrAfter: location)
        if slot < overrides.count && overrides[slot].location == location { overrides.remove(at: slot) }
    }

    /// Drops every override and re-scans the lines that had one.
    mutating func clearOverrides() {
        let old = overrides
        overrides = []
        var scannedTo = 0
        for override in old {
            let first = lineIndex(containing: override.location)
            if first < scannedTo { continue }
            let scanned = rescan(fromLine: first).lines
            lines.replaceSubrange(first..<(first + scanned.count), with: scanned)
            scannedTo = first + scanned.count
        }
    }

    /// Lines from `first` scanned again under the current overrides, as far as the stack differs
    /// from the old snapshot: up to the first later line start where they match again. The text is
    /// unchanged, so the result replaces `lines[first..<(first + count)]`.
    func rescan(fromLine first: Int) -> Scan {
        scan(from: lines[first].start, stack: startStack(ofLine: first)) { start, stack in
            guard let index = lineIndex(startingAt: start) else { return false }
            return stack == startStack(ofLine: index)
        }
    }

    // MARK: Scanning

    /// Scans lines from `start` until the text ends or `shouldStop` accepts a line start.
    func scan(from start: Int, stack initial: [Frame], until shouldStop: (Int, [Frame]) -> Bool) -> Scan {
        var result = Scan(lines: [], stoppedAt: nil, steps: 0, applied: [])
        var stack = initial
        var position = start
        var nextOverride = overrideSlot(atOrAfter: start)
        while true {
            var end = position
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            var terminator = 0
            if end < units.count {
                terminator = units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1
            }
            let firstOverride = nextOverride
            while nextOverride < overrides.count && overrides[nextOverride].location < end { nextOverride += 1 }
            var scanner = LineScanner(units: units, lineStart: position, limit: end, registry: registry,
                                      overrides: overrides[firstOverride..<nextOverride])
            let tokens = scanner.scan(grammar, stack: &stack)
            result.steps += scanner.steps + (end - position) + 1
            result.applied += scanner.applied
            result.lines.append(Line(start: position, contentLength: end - position, terminatorLength: terminator,
                                     tokens: tokens, endStack: stack))
            if terminator == 0 { return result }
            position = end + terminator
            while nextOverride < overrides.count && overrides[nextOverride].location < position { nextOverride += 1 }
            if shouldStop(position, stack) {
                result.stoppedAt = position
                return result
            }
        }
    }
}
