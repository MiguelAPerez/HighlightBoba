import Foundation

/// One token of the stream a parser reads. Every UTF-16 unit of the text is in exactly one token,
/// in order, so a tree built from them is lossless.
///
/// The stream is the lexer's own tokens, with the gaps between them split up: parsers never run a
/// second tokenizer. Punctuation-scoped lexer tokens are split into one token per character, since
/// the lexer merges a run like `]}],` into one span.
public struct SyntaxToken: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// A token the lexer scoped: a keyword, string piece, number, comment, punctuation…
        case lexeme
        /// An unscoped run of the grammar's word characters (or any non-ASCII character): identifiers.
        case word
        /// One unscoped character that is neither a word character nor a space: operators, brackets.
        case symbol
        /// A run of spaces and tabs.
        case space
        /// A line break: `\n`, `\r` or `\r\n`.
        case newline
    }

    public let kind: Kind
    /// UTF-16 offset of the first unit.
    public let location: Int
    /// Length in UTF-16 units; never zero.
    public let length: Int
    /// The lexer's scope, for a `lexeme`.
    public let scope: String?

    public init(kind: Kind, location: Int, length: Int, scope: String? = nil) {
        self.kind = kind
        self.location = location
        self.length = length
        self.scope = scope
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    public var end: Int { location + length }

    /// Spaces, line breaks and comments: a parser skips them, the tree keeps them.
    public var isTrivia: Bool {
        switch kind {
        case .space, .newline: return true
        case .lexeme: return scope?.hasPrefix("comment") == true
        case .word, .symbol: return false
        }
    }
}

extension Highlighter {
    /// The current text as parser tokens. Kept in step with `replaceCharacters`, since it is
    /// built from the same per-line lexer state.
    public var syntaxTokens: [SyntaxToken] { lexing.syntaxTokens(of: lexing.lines) }
}

extension Lexing {
    /// `lines` (some of this text's) as parser tokens.
    func syntaxTokens(of lines: some Collection<Line>) -> [SyntaxToken] {
        let names = Scopes.Table.shared.allNames
        let word = grammar.classes[grammar.wordClass]
        var result: [SyntaxToken] = []
        for line in lines {
            var position = line.start
            for token in line.tokens {
                let start = line.start + token.offset
                appendGap(from: position, to: start, word: word, into: &result)
                let scope = names[token.scope]
                if scope.hasPrefix("punctuation") {
                    var unit = start
                    while unit < start + token.length {
                        let length = characterLength(at: unit, limit: start + token.length)
                        result.append(SyntaxToken(kind: .lexeme, location: unit, length: length, scope: scope))
                        unit += length
                    }
                } else {
                    result.append(SyntaxToken(kind: .lexeme, location: start, length: token.length, scope: scope))
                }
                position = start + token.length
            }
            appendGap(from: position, to: line.start + line.contentLength, word: word, into: &result)
            if line.terminatorLength > 0 {
                result.append(SyntaxToken(kind: .newline, location: line.start + line.contentLength,
                                          length: line.terminatorLength))
            }
        }
        return result
    }

    private func appendGap(from start: Int, to end: Int, word: CharClass, into result: inout [SyntaxToken]) {
        func isWord(_ unit: UInt16) -> Bool { unit >= 0x80 || word.contains(unit) }
        func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
        var position = start
        while position < end {
            let unit = units[position]
            var next = position + 1
            let kind: SyntaxToken.Kind
            if isSpace(unit) {
                while next < end && isSpace(units[next]) { next += 1 }
                kind = .space
            } else if isWord(unit) {
                while next < end && isWord(units[next]) { next += 1 }
                kind = .word
            } else {
                kind = .symbol
            }
            result.append(SyntaxToken(kind: kind, location: position, length: next - position))
            position = next
        }
    }

    /// 2 for a surrogate pair, else 1, so a token never splits a character.
    private func characterLength(at position: Int, limit: Int) -> Int {
        UTF16.isLeadSurrogate(units[position]) && position + 1 < limit && UTF16.isTrailSurrogate(units[position + 1]) ? 2 : 1
    }
}
