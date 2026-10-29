import Foundation
import Testing
@testable import HighlightBoba

/// Every fixture's tokens must match its `.expected` file exactly.
///
/// To draft the expected file for a new fixture, run with `HIGHLIGHT_RECORD=1`, then read every
/// caret line before committing: a recorded file asserts whatever the engine did, right or wrong.
@Suite struct FixtureTests {
    static let fixtures = Fixture.all()
    static let record = ProcessInfo.processInfo.environment["HIGHLIGHT_RECORD"] == "1"

    static func entry(for fixture: Fixture) throws -> FixtureReport.Entry {
        let grammar = try Grammar.bundled(fixture.language)
        let input = try fixture.input()
        let tokens = Highlighter.highlight(input, grammar: grammar)
        return FixtureReport.Entry(fixture: fixture, input: input, tokens: tokens,
                                   actual: CaretRenderer.render(input, tokens: tokens), expected: fixture.expected())
    }

    @Test func everyBundledGrammarHasFixtures() {
        let covered = Set(Self.fixtures.map(\.language))
        for name in Grammar.bundledNames {
            #expect(covered.contains(name), "grammar \(name) has no fixtures in Tests/HighlightBobaTests/Fixtures/\(name)")
        }
    }

    @Test(arguments: fixtures)
    func fixtureMatches(_ fixture: Fixture) throws {
        let entry = try Self.entry(for: fixture)
        if Self.record && !entry.passed {
            try entry.actual.write(to: fixture.expectedURL, atomically: true, encoding: .utf8)
            return
        }
        #expect(entry.expected != nil, "missing \(fixture.expectedURL.lastPathComponent); draft it with HIGHLIGHT_RECORD=1")
        #expect(entry.passed, """
            \(fixture.testDescription) tokens differ.
            --- expected
            \(entry.expected ?? "")
            --- actual
            \(entry.actual)
            """)
    }

    @Test func writesHTMLReport() throws {
        let entries = try Self.fixtures.map(Self.entry(for:))
        let url = try FixtureReport.write(entries)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
