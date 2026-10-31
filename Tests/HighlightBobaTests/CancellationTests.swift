import Foundation
import Testing
@testable import HighlightBoba

/// A large file of a language: its fixtures, repeated to about 20,000 lookahead steps of parsing
/// (Swift's fixtures are mostly comments and strings, so it takes more text).
func largeText(_ language: String, length: Int? = nil) throws -> String {
    let inputs = try Fixture.all().filter { $0.language == language }.map { try $0.input() }
    let chunk = inputs.joined(separator: "\n")
    let length = length ?? ["swift": 100_000, "shell": 50_000][language] ?? 25_000
    return Array(repeating: chunk, count: max(1, length / max(1, chunk.utf16.count))).joined(separator: "\n")
}

/// What the parses a `Recorded` parser ran saw at the end: whether they were cancelled, and the work they did.
final class ParseLog: @unchecked Sendable {
    struct Entry {
        let cancelled: Bool
        let steps: Int
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var entries: [Entry] { lock.withLock { recorded } }

    func record(_ builder: TreeBuilder) {
        lock.withLock { recorded.append(Entry(cancelled: builder.isCancelled, steps: builder.lookaheadSteps)) }
    }
}

/// A real parser, held at a gate before each parse and logged after it.
struct Recorded: IncrementalParser {
    let inner: any IncrementalParser
    let gate: Gate
    let log: ParseLog
    var reparseBoundaries: Set<SyntaxKind> { inner.reparseBoundaries }
    func parse(_ builder: TreeBuilder) {
        gate.pass()
        inner.parse(builder)
        log.record(builder)
    }
    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) {
        gate.pass()
        inner.parseBlock(kind, builder)
        log.record(builder)
    }
}

/// One test at a time: they're heavy, and a CI runner's cooperative pool may have only three
/// threads, which the session tests' parses need too.
@Suite(.serialized) struct CancellationTests {
    static let languages = ["swift", "javascript", "typescript", "jsx", "tsx", "python", "shell"]

    static func builder(_ language: String) throws -> (TreeBuilder, String, any IncrementalParser) {
        let text = try largeText(language)
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        return (TreeBuilder(snapshot: highlighter.snapshot), text, LanguageSupport.bundledParsers[language]!)
    }

    /// Cancelled halfway, every bundled parser stops within the check interval, plus what it takes
    /// to unwind, and still leaves a lossless tree.
    @Test(arguments: languages)
    func aParseCancelledPartWayStopsWithinABoundedAmountOfWork(_ language: String) throws {
        let (full, text, parser) = try Self.builder(language)
        parser.parse(full)
        _ = full.finish()
        #expect(full.lookaheadSteps > 16 * TreeBuilder.cancellationInterval, "the file is large enough to measure")

        let half = full.lookaheadSteps / 2
        let (builder, _, _) = try Self.builder(language)
        builder.cancellation = { [unowned builder] in builder.lookaheadSteps >= half }
        parser.parse(builder)
        let tree = builder.finish()
        let noticed = try #require(builder.stepsWhenCancelled)
        #expect(builder.isCancelled)
        // A lookahead call takes one step, or one per token of an operator it matches.
        #expect(noticed - half < 8 * TreeBuilder.cancellationInterval, "noticed \(noticed - half) steps late")
        #expect(builder.lookaheadSteps - noticed < TreeBuilder.cancellationInterval,
                "\(builder.lookaheadSteps - noticed) steps to unwind")
        #expect(leafText(tree.root) == text, "a cancelled parse still finishes a lossless tree")
    }

    /// A parse whose task is cancelled before it starts does next to nothing, whole or incremental.
    @Test(arguments: languages)
    func aParseInACancelledTaskStopsAtOnce(_ language: String) async throws {
        let text = try largeText(language)
        let highlighter = Highlighter(grammar: try Grammar.bundled(language), text: text)
        let parser = LanguageSupport.bundledParsers[language]!
        let old = parser.parse(highlighter.snapshot)
        highlighter.replaceCharacters(in: NSRange(location: text.utf16.count / 2, length: 0), with: "\n")
        let edit = highlighter.edit(since: old.tree.revision)!
        let snapshot = highlighter.snapshot
        let (whole, reparse) = await Task.detached { () -> (Reparse, Reparse) in
            withUnsafeCurrentTask { $0?.cancel() }
            return (parser.parse(snapshot), parser.reparse(old.tree, after: edit, in: snapshot))
        }.value
        #expect(whole.steps < 64 && reparse.steps < 64, "\(whole.steps) and \(reparse.steps) steps")
        #expect(leafText(whole.tree.root) == highlighter.text && leafText(reparse.tree.root) == highlighter.text)
    }
}

/// `ParseSession` cancelling a real parse of a large file. In `ParseSessionTests`, which runs one
/// test at a time, so no more than one held parse blocks a thread of the cooperative pool.
extension ParseSessionTests {
    func makeSession(gate: Gate, log: ParseLog) throws -> ParseSession<Recorded> {
        let highlighter = Highlighter(grammar: try Grammar.bundled("swift"), text: try largeText("swift", length: 8_000))
        return ParseSession(highlighter: highlighter, parser: Recorded(inner: SwiftParser(), gate: gate, log: log))
    }

    /// The parse the session would have published: a whole parse of its text now.
    func fullParse(_ session: ParseSession<Recorded>) -> SyntaxTree {
        SwiftParser().parse(session.highlighter.snapshot).tree
    }

    @Test func aSupersededParseStops() async throws {
        let gate = Gate(), log = ParseLog()
        let session = try makeSession(gate: gate, log: log)
        var updates = 0
        session.onUpdate = { _ in updates += 1 }
        gate.close()
        session.textDidChange()
        await Self.waitFor { gate.waiting == 1 }
        session.highlighter.replaceCharacters(in: NSRange(location: 0, length: 0), with: "let x = 1\n")
        session.textDidChange()
        await Self.waitFor { log.entries.count == 1 }
        let first = try #require(log.entries.first)
        #expect(first.cancelled && first.steps < TreeBuilder.cancellationInterval, "the superseded parse took \(first.steps) steps")
        gate.open()
        await session.waitUntilIdle()
        #expect(updates == 1, "only the newest parse publishes")
        #expect(sameParse(try #require(session.tree), fullParse(session)))
    }

    @Test func releasingTheSessionCancelsItsParse() async throws {
        let gate = Gate(), log = ParseLog()
        var session: ParseSession<Recorded>? = try makeSession(gate: gate, log: log)
        var updates = 0
        session?.onUpdate = { _ in updates += 1 }
        gate.close()
        session?.textDidChange()
        await Self.waitFor { gate.waiting == 1 }
        session = nil
        await Self.waitFor { log.entries.count == 1 }
        let entry = try #require(log.entries.first)
        #expect(entry.cancelled && entry.steps < TreeBuilder.cancellationInterval)
        #expect(updates == 0)
        gate.open()
    }

    @Test func aCancelledParseNeverPublishes() async throws {
        let gate = Gate(), log = ParseLog()
        let session = try makeSession(gate: gate, log: log)
        var updates = 0
        session.onUpdate = { _ in updates += 1 }
        gate.close()
        session.textDidChange()
        await Self.waitFor { gate.waiting == 1 }
        session.cancel()
        await Self.waitFor { log.entries.count == 1 }
        gate.open()
        await session.waitUntilIdle()
        #expect(try #require(log.entries.first).cancelled && updates == 0 && session.tree == nil)

        // Nothing was lost: the next parse covers the text.
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(updates == 1)
        #expect(sameParse(try #require(session.tree), fullParse(session)))
    }

    /// Cancelled after the parse ended but before its result reached the main actor: still dropped.
    @Test func aParseCancelledAsItFinishesDoesNotPublish() async throws {
        let gate = Gate(), log = ParseLog()
        let session = try makeSession(gate: gate, log: log)
        var updates = 0
        session.onUpdate = { _ in updates += 1 }
        gate.open()
        session.textDidChange()
        // Blocks the main actor, so the result can't be published before `cancel()`.
        let deadline = Date().addingTimeInterval(60)
        while log.entries.isEmpty && Date() < deadline { usleep(5_000) }
        #expect(log.entries.first?.cancelled == false, "the parse ran to the end")
        session.cancel()
        await session.waitUntilIdle()
        #expect(updates == 0 && session.tree == nil)
    }
}
