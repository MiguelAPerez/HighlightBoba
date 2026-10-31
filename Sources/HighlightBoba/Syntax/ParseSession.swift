import Foundation

/// Keeps a syntax tree for a highlighter's text, parsing off the main thread.
///
/// After each edit, call `textDidChange()`. The session takes a `Sendable` snapshot, reparses on a
/// background task (just the edited block when it can) and publishes the tree on the main actor.
/// An edit that arrives while a parse runs cancels it; the next parse covers every edit since the
/// last published tree. A result is published only if the text is still the one it was parsed
/// from, so a tree never lands over newer text.
///
/// Cancelling is cooperative: the parse checks between tokens and stops within a bounded amount
/// of work. `cancel()` stops it without publishing, and so does releasing the session.
@MainActor
public final class ParseSession<Parser: IncrementalParser> {
    public let highlighter: Highlighter
    public let parser: Parser
    /// The last tree published, or `nil` before the first parse finishes.
    public private(set) var tree: SyntaxTree?
    /// Called with each published tree.
    public var onUpdate: ((Update) -> Void)?

    /// A published tree and what changed.
    public struct Update {
        public let tree: SyntaxTree
        /// The node rebuilt: the reparsed block, or the root. Highlight queries need to re-run only on it.
        public let changed: SyntaxNode
        /// The ranges whose highlighting re-lexing changed (`Highlighter.applyRelexing(of:)`), to re-colour.
        public let relexed: [NSRange]
    }

    /// The parse running off the main thread, and the task that publishes its result.
    private var parsing: Task<Reparse?, Never>?
    private var running: Task<Void, Never>?
    /// Bumped by every parse started, so only the newest one publishes.
    private var generation = 0
    /// Results dropped because the text changed while they were parsing, for the tests.
    private(set) var droppedStale = 0

    public init(highlighter: Highlighter, parser: Parser) {
        self.highlighter = highlighter
        self.parser = parser
    }

    // The task is `Sendable` and cancelling it is thread-safe, so the nonisolated deinit may.
    deinit { parsing?.cancel() }

    /// Stops the parse that is running, if any, and publishes nothing from it. The tree stays the
    /// last one published; the next `textDidChange()` parses every edit since it.
    public func cancel() {
        parsing?.cancel()
        // Whatever it returns is no longer the newest parse, so it can't publish.
        generation += 1
    }

    /// Starts a parse of the current text, cancelling one that is running.
    public func textDidChange() {
        // Cancelled here, not through `running`, so it is cancelled before this returns.
        parsing?.cancel()
        generation += 1
        let generation = generation
        let snapshot = highlighter.snapshot
        let base = tree
        let edit = base.flatMap { highlighter.edit(since: $0.revision) }
        let parser = parser
        let work = Task.detached(priority: .userInitiated) { () -> Reparse? in
            let result: Reparse
            if let base, base.revision == snapshot.revision {
                return nil
            } else if let base, let edit {
                result = parser.reparse(base, after: edit, in: snapshot)
            } else {
                result = parser.parse(snapshot)
            }
            return Task.isCancelled ? nil : result
        }
        parsing = work
        running = Task { [weak self] in
            let result = await work.value
            self?.publish(result, generation: generation)
        }
    }

    /// Waits until no parse is running.
    public func waitUntilIdle() async {
        while let running {
            await running.value
            if self.running == running { self.running = nil }
        }
    }

    private func publish(_ result: Reparse?, generation: Int) {
        let newest = generation == self.generation
        if newest {
            running = nil
            parsing = nil
        }
        guard let result else { return }
        // Parsed from text that has changed since: a newer parse covers it.
        guard newest, result.tree.revision == highlighter.revision else {
            droppedStale += 1
            return
        }
        tree = result.tree
        let relexed = highlighter.applyRelexing(of: result.tree) ?? []
        onUpdate?(Update(tree: result.tree, changed: result.changed, relexed: relexed))
    }
}
