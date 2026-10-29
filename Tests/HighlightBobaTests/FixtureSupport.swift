import Foundation
import Testing
@testable import HighlightBoba

/// One fixture: `Fixtures/<language>/<name>.input` and its expected tokens in `<name>.expected`.
struct Fixture: CustomTestStringConvertible, Sendable {
    let language: String
    let name: String
    let inputURL: URL

    var expectedURL: URL { inputURL.deletingPathExtension().appendingPathExtension("expected") }
    var testDescription: String { "\(language)/\(name)" }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func all() -> [Fixture] {
        let files = FileManager.default
        let languages = (try? files.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        return languages.flatMap { language -> [Fixture] in
            let folder = root.appendingPathComponent(language)
            let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".input") }.sorted().map {
                Fixture(language: language, name: String($0.dropLast(".input".count)),
                        inputURL: folder.appendingPathComponent($0))
            }
        }
    }

    func input() throws -> String { try String(contentsOf: inputURL, encoding: .utf8) }
    func expected() -> String? { try? String(contentsOf: expectedURL, encoding: .utf8) }
}

/// Renders tokens as the fixture format: each source line, then one caret line per token on it.
///
/// Columns count `Character`s, so carets line up under emoji in an editor; ranges are still checked
/// in UTF-16 because a grapheme boundary is where a wrong UTF-16 offset shows up as a shifted caret.
enum CaretRenderer {
    static func render(_ text: String, tokens: [HighlightToken]) -> String {
        var output: [String] = []
        var remaining = tokens[...]
        for line in lines(of: text) {
            output.append(line.content)
            let columns = columnMap(line.content)
            while let token = remaining.first, token.range.location < line.end {
                remaining = remaining.dropFirst()
                let start = max(token.range.location, line.start) - line.start
                let end = min(NSMaxRange(token.range), line.start + line.utf16Length) - line.start
                guard end > start else { continue }
                let column = columns[start]
                let width = max(1, columns[end] - column)
                output.append(String(repeating: " ", count: column) + String(repeating: "^", count: width) + " " + token.scope)
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    struct SourceLine {
        let content: String
        let start: Int
        let utf16Length: Int
        let end: Int
    }

    static func lines(of text: String) -> [SourceLine] {
        let units = Array(text.utf16)
        var result: [SourceLine] = []
        var position = 0
        while true {
            var end = position
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            let content = String(decoding: units[position..<end], as: UTF16.self)
            var next = end
            if end < units.count { next += units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1 }
            result.append(SourceLine(content: content, start: position, utf16Length: end - position, end: next))
            if end == units.count { return result }
            position = next
        }
    }

    /// Maps each UTF-16 offset in `line` (0...count) to the column of the character containing it.
    static func columnMap(_ line: String) -> [Int] {
        var map: [Int] = []
        var column = 0
        for character in line {
            map += Array(repeating: column, count: character.utf16.count)
            column += 1
        }
        map.append(column)
        return map
    }
}

/// Writes `index.html`: every fixture coloured by scope, with expected vs actual for mismatches.
enum FixtureReport {
    struct Entry {
        let fixture: Fixture
        let input: String
        let tokens: [HighlightToken]
        let actual: String
        let expected: String?
        var passed: Bool { actual == expected }
    }

    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["HIGHLIGHT_REPORT_DIR"] { return URL(fileURLWithPath: path) }
        return Fixture.packageRoot.appendingPathComponent(".build/fixture-report")
    }

    static func write(_ entries: [Entry]) throws -> URL {
        let failures = entries.filter { !$0.passed }.count
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>HighlightBoba fixtures</title><style>
        body{font:14px -apple-system,system-ui,sans-serif;margin:24px;background:#fff;color:#1d1d1f}
        pre{font:13px ui-monospace,Menlo,monospace;background:#f6f6f8;padding:12px;border-radius:8px;overflow-x:auto}
        h2{font-size:15px;margin-top:28px}.pass{color:#1a7f37}.fail{color:#cf222e}
        .cols{display:grid;grid-template-columns:1fr 1fr;gap:12px}.diff{background:#ffebe9}
        .comment{color:#6e7781;font-style:italic}.string{color:#0a3069}.constant{color:#0550ae}
        .keyword{color:#cf222e;font-weight:600}.variable{color:#953800}.entity{color:#8250df}
        .meta{color:#116329}.support{color:#6639ba}.punctuation{color:#57606a}.invalid{background:#ffcecb}
        .escape{color:#0550ae;font-weight:600}.embedded{color:#bc4c00}
        </style></head><body>
        <h1>HighlightBoba fixtures</h1>
        <p>\(entries.count) fixtures, <span class="\(failures == 0 ? "pass" : "fail")">\(failures) failing</span></p>
        """
        for entry in entries {
            let status = entry.passed ? "<span class=pass>pass</span>" : "<span class=fail>FAIL</span>"
            html += "<h2>\(escape(entry.fixture.testDescription)) — \(status)</h2><pre>\(colour(entry.input, entry.tokens))</pre>"
            if !entry.passed {
                html += "<div class=cols><div><b>expected</b><pre>\(diffMarked(entry.expected ?? "(missing .expected file)", against: entry.actual))</pre></div>"
                html += "<div><b>actual</b><pre>\(diffMarked(entry.actual, against: entry.expected ?? ""))</pre></div></div>"
            }
        }
        html += "</body></html>\n"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func cssClasses(_ scope: String) -> String {
        var classes = [String(scope.split(separator: ".").first ?? "")]
        if scope.hasSuffix(".escape") { classes.append("escape") }
        if scope.hasSuffix(".embedded") { classes.append("embedded") }
        return classes.joined(separator: " ")
    }

    static func colour(_ text: String, _ tokens: [HighlightToken]) -> String {
        let units = Array(text.utf16)
        var html = ""
        var position = 0
        for token in tokens {
            html += escape(String(decoding: units[position..<token.range.location], as: UTF16.self))
            let body = String(decoding: units[token.range.location..<NSMaxRange(token.range)], as: UTF16.self)
            html += "<span class=\"\(cssClasses(token.scope))\" title=\"\(token.scope)\">\(escape(body))</span>"
            position = NSMaxRange(token.range)
        }
        return html + escape(String(decoding: units[position...], as: UTF16.self))
    }

    static func diffMarked(_ text: String, against other: String) -> String {
        let others = other.components(separatedBy: "\n")
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            index < others.count && others[index] == line ? escape(line) : "<span class=diff>\(escape(line))</span>"
        }.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
