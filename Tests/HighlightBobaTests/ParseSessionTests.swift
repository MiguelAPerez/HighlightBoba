import Foundation
import Testing
@testable import HighlightBoba

/// Holds parses until the test opens it, so a test can edit while a parse is in flight.
///
/// A held parse blocks a thread of the cooperative pool, which a CI runner may have only three of.
/// So a parse whose task is cancelled goes through at once, as a real one stops early, and a test
/// holds no more than the one parse it waits for. A parse is never held past `limit`, so a test
/// that never opens the gate fails instead of hanging the run.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = true
    private var waitingCount = 0
    private var cancelledCount = 0
    /// Well past `ParseSessionTests.waitFor`'s, so a slow runner times a test out before a held parse
    /// is let through uncancelled: on a loaded CI runner a parse can wait a minute for a thread.
    static let limit: TimeInterval = 180

    /// Parses waiting at the gate now.
    var waiting: Int { condition.withLock { waitingCount } }
    /// Parses that found their task cancelled once let through.
    var cancelled: Int { condition.withLock { cancelledCount } }

    func pass() {
        condition.withLock {
            waitingCount += 1
            let deadline = Date().addingTimeInterval(Self.limit)
            // Cancelling a task doesn't signal the condition, so it's polled.
            while closed && !Task.isCancelled && Date() < deadline {
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.005)))
            }
            waitingCount -= 1
            if Task.isCancelled { cancelledCount += 1 }
        }
    }

    func open() {
        condition.withLock {
            closed = false
            condition.broadcast()
        }
    }

    func close() { condition.withLock { closed = true } }
}

/// `ToyBlocks`, held at a gate before each parse.
struct GatedBlocks: IncrementalParser {
    let gate: Gate
    var reparseBoundaries: Set<SyntaxKind> { ToyBlocks().reparseBoundaries }
    func parse(_ builder: TreeBuilder) {
        gate.pass()
        ToyBlocks().parse(builder)
    }
    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) {
        gate.pass()
        ToyBlocks().parseBlock(kind, builder)
    }
}

@MainActor
@Suite(.serialized) struct ParseSessionTests {
    /// Waits up to a minute: a loaded CI runner's pool can keep a parse from starting for that long.
    static func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "timed out")
    }

    static func makeSession(_ text: String, gate: Gate) async -> (ParseSession<GatedBlocks>, [ParseSession<GatedBlocks>.Update]) {
        let session = ParseSession(highlighter: Highlighter(grammar: relexGrammar, text: text), parser: GatedBlocks(gate: gate))
        gate.open()
        session.textDidChange()
        await session.waitUntilIdle()
        return (session, [])
    }

    @Test func publishesTheFirstParseAndThenBlockReparses() async {
        let gate = Gate()
        let (session, _) = await Self.makeSession("a;\n{ b; [ c ] }\n", gate: gate)
        var updates: [ParseSession<GatedBlocks>.Update] = []
        session.onUpdate = { updates.append($0) }
        #expect(session.tree?.revision == session.highlighter.revision)
        let at = (session.highlighter.text as NSString).range(of: "c").location
        session.highlighter.replaceCharacters(in: NSRange(location: at, length: 0), with: "x + ")
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(updates.count == 1)
        #expect(updates.first?.changed.kind == ToyBlocks.list, "the parse off the main thread reparsed just the list")
        #expect(updates.first?.changed.text == "[ x + c ]")
        #expect(sameParse(session.tree!, ToyBlocks().parse(session.highlighter.snapshot).tree))
    }

    @Test func editsWhileAParseRunsAreCoalescedIntoOneReparse() async {
        let gate = Gate()
        let (session, _) = await Self.makeSession("a;\n{ b; [ c ] }\n{ d; }\n", gate: gate)
        var updates: [ParseSession<GatedBlocks>.Update] = []
        session.onUpdate = { updates.append($0) }
        let highlighter = session.highlighter
        gate.close()
        func type(_ string: String, after anchor: String) {
            let at = (highlighter.text as NSString).range(of: anchor).location + (anchor as NSString).length
            highlighter.replaceCharacters(in: NSRange(location: at, length: 0), with: string)
            session.textDidChange()
        }
        type("1", after: "[ c")
        await Self.waitFor { gate.waiting == 1 }
        type("2", after: "[ c1")
        type("3", after: "[ c12")
        // The cancelled parses go through; the newest waits. The second can be cancelled before it
        // starts, and then it never reaches the gate: a cancelled parse doesn't start the parser.
        await Self.waitFor { gate.cancelled >= 1 && gate.waiting == 1 }
        gate.open()
        await session.waitUntilIdle()
        #expect(updates.count == 1, "only the newest parse publishes")
        #expect(updates.first?.changed.text == "[ c123 ]", "it covers all three edits, and only the list")
        #expect((1...2).contains(gate.cancelled), "the older parses were cancelled, each once")
        #expect(session.tree?.revision == highlighter.revision)
        #expect(sameParse(session.tree!, ToyBlocks().parse(highlighter.snapshot).tree))
    }

    @Test func aResultForOlderTextIsNotApplied() async {
        let gate = Gate()
        let (session, _) = await Self.makeSession("{ a; }", gate: gate)
        let published = session.tree!
        var updates = 0
        session.onUpdate = { _ in updates += 1 }
        gate.close()
        session.highlighter.replaceCharacters(in: NSRange(location: 2, length: 0), with: "b ")
        session.textDidChange()
        await Self.waitFor { gate.waiting == 1 }
        // Edited again before the parse ends, and the host hasn't asked for a parse yet.
        session.highlighter.replaceCharacters(in: NSRange(location: 2, length: 0), with: "c ")
        gate.open()
        await session.waitUntilIdle()
        #expect(updates == 0 && session.droppedStale == 1)
        #expect(session.tree === published, "the tree for the older text was dropped")
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(updates == 1 && session.tree?.revision == session.highlighter.revision)
        #expect(sExpression(session.tree!.root) == "root(statement(block({ statement(c b a ;) })))")
    }

    @Test func publishingAppliesTheTreesRelexing() async {
        let session = ParseSession(highlighter: Highlighter(grammar: relexGrammar, text: "{ x / y; }"), parser: ToyBlocks(relexes: true))
        var relexed: [NSRange] = []
        session.onUpdate = { relexed = $0.relexed }
        session.textDidChange()
        await session.waitUntilIdle()
        session.highlighter.replaceCharacters(in: NSRange(location: 2, length: 1), with: "return")
        session.textDidChange()
        await session.waitUntilIdle()
        #expect(relexed == [NSRange(location: 0, length: 15)])
        #expect(scoped(session.highlighter).contains("/ y; }:string.regexp"))
    }

    @Test func aCancelledParseStopsEarly() async {
        let text = Array(repeating: "{ a; [ b c ] }", count: 5_000).joined(separator: "\n")
        let snapshot = Highlighter(grammar: relexGrammar, text: text).snapshot
        let gate = Gate()
        let task = Task.detached { () -> (Bool, Int) in
            gate.pass()
            let builder = TreeBuilder(snapshot: snapshot)
            ToyBlocks().parse(builder)
            let tree = builder.finish()
            #expect(leafText(tree.root) == text, "a cancelled parse still finishes a lossless tree")
            return (builder.isCancelled, builder.lookaheadSteps)
        }
        await Self.waitFor { gate.waiting == 1 }
        task.cancel()
        gate.open()
        let (cancelled, steps) = await task.value
        let full = TreeBuilder(snapshot: snapshot)
        ToyBlocks().parse(full)
        #expect(cancelled && steps * 10 < full.lookaheadSteps, "\(steps) steps after cancelling, \(full.lookaheadSteps) for the file")
    }

    /// A cancelled parse isn't held, so held parses can't fill the cooperative pool.
    @Test func aClosedGateLetsACancelledParseThrough() async {
        let gate = Gate()
        let task = Task.detached { gate.pass() }
        await Self.waitFor { gate.waiting == 1 }
        let start = Date()
        task.cancel()
        await task.value
        #expect(Date().timeIntervalSince(start) < Gate.limit / 2, "the gate held a cancelled parse")
        #expect(gate.cancelled == 1 && gate.waiting == 0)
    }
}
