import Foundation

/// A highlighted span. `range` is in UTF-16 code units, ready for `NSAttributedString`.
public struct HighlightToken: Hashable, Sendable {
    public var range: NSRange
    public var scope: String

    public init(range: NSRange, scope: String) {
        self.range = range
        self.scope = scope
    }
}

/// Highlights a document and keeps it highlighted across edits.
///
/// The state stack is snapshotted at every line end. After an edit, scanning restarts one line
/// before the edit and stops at the first line past it whose end stack matches the old snapshot,
/// so typing inside a function re-scans a line or two, not the file.
public final class Highlighter {
    public let grammar: Grammar
    /// Where embedded grammars (a Markdown fence's language) are looked up.
    public let registry: GrammarRegistry
    private(set) var units: [UInt16]
    private var lines: [Line]
    /// Scanner work done by the last full highlight or edit, for the linearity tests.
    private(set) var lastSteps = 0

    struct Line: Equatable {
        var start: Int
        var contentLength: Int
        var terminatorLength: Int
        var tokens: [LineToken]
        var endStack: [Frame]
    }

    public init(grammar: Grammar, text: String, registry: GrammarRegistry = .shared) {
        self.grammar = grammar
        self.registry = registry
        units = Array(text.utf16)
        lines = []
        lines = scan(from: 0, stack: initialStack) { _, _ in false }.lines
    }

    /// One-shot highlight of `text`.
    public static func highlight(_ text: String, grammar: Grammar, registry: GrammarRegistry = .shared) -> [HighlightToken] {
        Highlighter(grammar: grammar, text: text, registry: registry).tokens
    }

    private var initialStack: [Frame] { [Frame(state: grammar.initial)] }

    public var text: String { String(decoding: units, as: UTF16.self) }

    public var tokens: [HighlightToken] {
        let names = Scopes.Table.shared.allNames
        return lines.flatMap { line in
            line.tokens.map {
                HighlightToken(range: NSRange(location: line.start + $0.offset, length: $0.length), scope: names[$0.scope])
            }
        }
    }

    /// Applies an edit and re-highlights only what it affects.
    /// - Returns: the UTF-16 range of the new text whose tokens may have changed.
    @discardableResult
    public func replaceCharacters(in range: NSRange, with string: String) -> NSRange {
        precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= units.count,
                     "edit range \(range) is outside the text (length \(units.count))")
        let inserted = Array(string.utf16)
        let delta = inserted.count - range.length
        let oldEditEnd = NSMaxRange(range)
        units.replaceSubrange(range.location..<oldEditEnd, with: inserted)

        // Start one line early: joining "\r" and "\n" or deleting a line break changes the line before.
        let first = max(0, lineIndex(containing: range.location) - 1)
        let start = lines[first].start
        let startStack = first == 0 ? initialStack : lines[first - 1].endStack

        var resume: Int?
        let (scanned, stoppedAt) = scan(from: start, stack: startStack) { newStart, stack in
            let oldStart = newStart - delta
            guard oldStart >= oldEditEnd, let index = self.lineIndex(startingAt: oldStart), index >= first else { return false }
            let oldStack = index == 0 ? self.initialStack : self.lines[index - 1].endStack
            guard oldStack == stack else { return false }
            resume = index
            return true
        }

        var rebuilt = Array(lines[..<first]) + scanned
        if let resume {
            rebuilt += lines[resume...].map { line in
                var line = line
                line.start += delta
                return line
            }
        }
        lines = rebuilt
        return NSRange(location: start, length: (stoppedAt ?? units.count) - start)
    }

    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func lineIndex(startingAt location: Int) -> Int? {
        let index = lineIndex(containing: location)
        return lines[index].start == location ? index : nil
    }

    /// Scans lines from `start` until the text ends or `shouldStop` accepts a line start.
    private func scan(from start: Int, stack initial: [Frame],
                      until shouldStop: (Int, [Frame]) -> Bool) -> (lines: [Line], stoppedAt: Int?) {
        var result: [Line] = []
        var stack = initial
        var position = start
        var steps = 0
        defer { lastSteps = steps }
        while true {
            var end = position
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            var terminator = 0
            if end < units.count {
                terminator = units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1
            }
            var scanner = LineScanner(units: units, lineStart: position, limit: end, registry: registry)
            let tokens = scanner.scan(grammar, stack: &stack)
            steps += scanner.steps + (end - position) + 1
            result.append(Line(start: position, contentLength: end - position, terminatorLength: terminator,
                               tokens: tokens, endStack: stack))
            if terminator == 0 { return (result, nil) }
            position = end + terminator
            if shouldStop(position, stack) { return (result, position) }
        }
    }
}
