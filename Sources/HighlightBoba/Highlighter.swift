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
    private(set) var lexing: Lexing
    /// Scanner work done by the last full highlight or edit, for the linearity tests.
    private(set) var lastSteps = 0
    /// Counts edits, so a tree parsed from an older text is never applied to a newer one.
    public private(set) var revision = 0
    /// Tells this highlighter's snapshots from another's.
    let id = UUID()

    var units: [UInt16] { lexing.units }
    var lines: [Lexing.Line] { lexing.lines }

    public init(grammar: Grammar, text: String, registry: GrammarRegistry = .shared) {
        self.grammar = grammar
        self.registry = registry
        var steps = 0
        lexing = Lexing(grammar: grammar, registry: registry, units: Array(text.utf16), steps: &steps)
        lastSteps = steps
    }

    /// One-shot highlight of `text`.
    public static func highlight(_ text: String, grammar: Grammar, registry: GrammarRegistry = .shared) -> [HighlightToken] {
        Highlighter(grammar: grammar, text: text, registry: registry).tokens
    }

    public var text: String { String(decoding: units, as: UTF16.self) }

    public var tokens: [HighlightToken] {
        let names = Scopes.Table.shared.allNames
        return lines.flatMap { line in
            line.tokens.map {
                HighlightToken(range: NSRange(location: line.start + $0.offset, length: $0.length), scope: names[$0.scope])
            }
        }
    }

    /// The current text and its lexing, for a parser to read on any thread.
    public var snapshot: Snapshot { Snapshot(lexing: lexing, highlighter: id, revision: revision) }

    /// What a parser reads: a copy of the text and its tokens as they were at `revision`.
    public struct Snapshot: Sendable {
        let lexing: Lexing
        let highlighter: UUID
        public let revision: Int
        public var text: String { String(decoding: lexing.units, as: UTF16.self) }
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
        revision += 1
        lexing.units.replaceSubrange(range.location..<oldEditEnd, with: inserted)
        // A re-lex request moves with its text, and goes with it when the edit replaces that text.
        lexing.overrides = lexing.overrides.compactMap { override in
            if override.location >= oldEditEnd { return Lexing.Override(location: override.location + delta, state: override.state) }
            return override.location >= range.location ? nil : override
        }

        // Start one line early: joining "\r" and "\n" or deleting a line break changes the line before.
        let first = max(0, lexing.lineIndex(containing: range.location) - 1)
        let start = lines[first].start

        var resume: Int?
        let scan = lexing.scan(from: start, stack: lexing.startStack(ofLine: first)) { newStart, stack in
            let oldStart = newStart - delta
            guard oldStart >= oldEditEnd, let index = self.lexing.lineIndex(startingAt: oldStart), index >= first else { return false }
            guard self.lexing.startStack(ofLine: index) == stack else { return false }
            resume = index
            return true
        }
        lastSteps = scan.steps

        var rebuilt = Array(lines[..<first]) + scan.lines
        if let resume {
            rebuilt += lines[resume...].map { line in
                var line = line
                line.start += delta
                return line
            }
        }
        lexing.lines = rebuilt
        return NSRange(location: start, length: (scan.stoppedAt ?? units.count) - start)
    }

    /// Takes the re-lexing a parse asked for (`TreeBuilder.relex(as:)`), so the highlighting
    /// matches the tree. Re-lexing replaces earlier requests: a token the last parse re-lexed and
    /// this one didn't goes back to the lexer's own reading.
    /// - Returns: the UTF-16 ranges whose tokens changed, to re-colour; `nil`, with nothing applied,
    ///   if the text was edited since the parse's snapshot or the tree came from another highlighter's.
    public func applyRelexing(of tree: SyntaxTree) -> [NSRange]? {
        guard let parsed = tree.lexing, tree.highlighter == id, tree.revision == revision,
              parsed.lines.count == lines.count else { return nil }
        // Every line, not just the ones this parse re-lexed: a tree parsed alongside another that was
        // applied first never saw what that one changed, and applying it puts that back.
        var changed: [NSRange] = []
        for index in lines.indices where parsed.lines[index] != lines[index] {
            let line = parsed.lines[index]
            if let last = changed.last, NSMaxRange(last) == line.start {
                changed[changed.count - 1].length += line.end - line.start
            } else {
                changed.append(NSRange(location: line.start, length: line.end - line.start))
            }
        }
        lexing = parsed
        return changed
    }
}
