import Foundation

/// One parse of a JavaScript or TypeScript text: the cursor helpers every part of the grammar uses.
///
/// Context never flows into a reparse boundary (a `{ }` body, an object literal…): each of those
/// parses the same wherever it sits, which is what lets `parseBlock` stand in for a whole parse.
/// Flags like `noIn` are arguments, reset inside brackets, not state on this object.
final class JSParse {
    let b: TreeBuilder
    let ts: Bool
    /// JSX elements are expressions (`.jsx` and `.tsx`); a TSX file has no `<T>value` assertions.
    let jsx: Bool
    /// Where the last consumed token ends, for ASI (`newlineBefore`) and for telling string pieces
    /// that belong together.
    private(set) var lastEnd = 0
    /// Significant tokens consumed, so a loop can tell whether an iteration made progress.
    private(set) var consumed = 0

    /// Node depth past which constructs stop nesting, so `((((…` can't overflow the stack, even on
    /// a background thread's 512 KB one. The worst nesting costs about 2 KB of stack a level in a
    /// debug build and 700 bytes in release, which is why the functions that recurse leave their
    /// token tests to small `@inline(never)` helpers: inlined, those made a level cost 5 KB.
    static let maxDepth = 200
    /// How far a lookahead scan (is this `(` an arrow's parameters? is this `<` type arguments?)
    /// reads before giving up. Scans are only for precision: past it, the parse still recovers.
    static let scanLimit = 256

    init(_ builder: TreeBuilder, dialect: JSParser.Dialect) {
        b = builder
        ts = dialect == .typescript || dialect == .tsx
        jsx = dialect == .jsx || dialect == .tsx
    }

    // MARK: Re-lexing

    /// What the parser asks the lexer to re-read the next token as. Each names a grammar state that
    /// exists only for these requests.
    enum Relex: String {
        /// A `/` the lexer read as division where an expression starts: a regex.
        case regex = "regexStart"
        /// A regex the lexer started where an operator belongs: division.
        case division = "divisionStart"
        /// A contextual keyword used as a name, read by the lexer together with a following `/` as
        /// a regex (`of / 2`): a plain word, so the `/` after it is division.
        case identifier = "identifierStart"
        /// A `<` where an expression starts, in JSX: the start of an element, lexed in JSX states.
        case jsx = "jsxStart"
        /// A `<` the lexer guessed opens an element where an operator or a type belongs: `a\n<b`,
        /// `type F = <T>(x: T) => T`.
        case lessThan = "jsxLessThan"
        /// A JSX attribute's quoted value that runs on past its line into what is clearly not
        /// one, as a half-typed `className="a` would: a string that ends at the line end.
        case jsxLineString = "jsxLineString"
    }

    @discardableResult
    func relex(_ request: Relex) -> Bool { b.relex(as: request.rawValue) }

    /// Where a `<` can't open an element (after an operand, in a type), one the lexer took for
    /// an element's is re-lexed as the operator.
    @inline(never)
    func angleIfNeeded() {
        if jsx && jsxPunctuation("<") { relex(.lessThan) }
    }

    /// The JSX states the lexer can be asked to leave at once (`jsxPop1`…).
    static let jsxPopLimit = 16

    /// Re-lexes the next token after popping `count` of the lexer's JSX states, to leave elements
    /// the parser has ended: a half-typed tag, or ones a stray `}` or an outer closing tag ends.
    @discardableResult
    func relexPopping(_ count: Int) -> Bool {
        guard count > 0, count <= Self.jsxPopLimit else { return false }
        return b.relex(as: "jsxPop\(count)")
    }

    // MARK: Reading

    var cur: SyntaxToken? { b.current }
    var isAtEnd: Bool { b.isAtEnd }

    /// The significant token `offset` places ahead.
    @inline(never)
    func tok(_ offset: Int) -> SyntaxToken? { offset == 0 ? b.current : b.peek(offset) }

    @inline(never)
    func text(_ token: SyntaxToken) -> String { b.text(of: token) }

    static let wordScopes: Set<String> = ["keyword", "entity.name.type", "entity.name.function", "constant.language", "variable.language"]

    /// Words that can never name a variable. Contextual keywords (`of`, `get`, `type`…) aren't here.
    static let reserved: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum",
        "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null",
        "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
        "yield", "await"
    ]

    /// A word, or a lexeme the lexer read as a keyword, a name or a constant: anything a property
    /// name may be.
    @inline(never)
    func isWordLike(_ token: SyntaxToken?) -> Bool {
        guard let token else { return false }
        switch token.kind {
        case .word: return true
        case .lexeme: return Self.wordScopes.contains(token.scope ?? "")
        default: return false
        }
    }

    /// The token's text if it is word-like.
    @inline(never)
    func word(_ offset: Int = 0) -> String? {
        guard let token = tok(offset), isWordLike(token) else { return nil }
        return text(token)
    }

    @inline(never)
    func atWord(_ name: String, _ offset: Int = 0) -> Bool { word(offset) == name }

    /// A token that can name a variable: a word or keyword lexeme that isn't reserved.
    @inline(never)
    func isIdentifier(_ offset: Int = 0) -> Bool {
        guard let token = tok(offset), isWordLike(token), token.scope != "constant.language",
              token.scope != "variable.language" else { return false }
        return !Self.reserved.contains(text(token))
    }

    /// A one-character symbol (`(`, `,`…) at `offset`.
    @inline(never)
    func sym(_ offset: Int = 0) -> String? {
        guard let token = tok(offset), token.kind == .symbol else { return nil }
        return text(token)
    }

    @inline(never)
    func atSym(_ symbol: String, _ offset: Int = 0) -> Bool { sym(offset) == symbol }

    static let operators: Set<String> = [
        "{", "}", "(", ")", "[", "]", ";", ",", "<", ">", "<=", ">=", "==", "!=", "===", "!==", "+", "-", "*", "/",
        "%", "**", "++", "--", "<<", ">>", ">>>", "&", "|", "^", "!", "~", "&&", "||", "??", "?", "?.", ":", "=",
        "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=", "=>",
        "...", ".", "@", "#"
    ]

    /// The longest operator spelled by adjacent symbols from `offset`: `>>>=` arrives as four symbols.
    @inline(never)
    func op(_ offset: Int = 0) -> String? {
        guard let first = tok(offset), first.kind == .symbol else { return nil }
        var spelled = text(first)
        var best = Self.operators.contains(spelled) ? spelled : nil
        var end = first.end
        var next = offset + 1
        while spelled.utf16.count < 4, let token = tok(next), token.kind == .symbol, token.location == end {
            spelled += text(token)
            if Self.operators.contains(spelled) { best = spelled }
            end = token.end
            next += 1
        }
        return best
    }

    @inline(never)
    func atOp(_ spelling: String) -> Bool { op() == spelling }

    @inline(never)
    func isLexeme(_ token: SyntaxToken?, _ scope: String) -> Bool { token?.kind == .lexeme && token?.scope == scope }

    @inline(never)
    func isStringStart(_ token: SyntaxToken?) -> Bool {
        guard let token, isLexeme(token, "string.quoted") else { return false }
        let first = text(token).utf16.first
        return first == 34 || first == 39
    }

    @inline(never)
    func isTemplateStart(_ token: SyntaxToken?) -> Bool {
        guard let token, isLexeme(token, "string.quoted") else { return false }
        return text(token).utf16.first == 96
    }

    @inline(never)
    func isEmbedded(_ token: SyntaxToken?, _ symbol: String) -> Bool {
        guard let token, isLexeme(token, "punctuation.section.embedded") else { return false }
        return text(token) == symbol
    }

    /// A `}` that ends something: a brace, or the end of a template substitution.
    var atCloseBrace: Bool { closeBrace() }

    @inline(never)
    private func closeBrace() -> Bool { atSym("}") || isEmbedded(cur, "}") }

    /// A token that closes a bracket some enclosing construct opened.
    var atCloser: Bool { closer() }

    @inline(never)
    private func closer() -> Bool {
        guard let token = cur else { return false }
        if isEmbedded(token, "}") { return true }
        guard token.kind == .symbol else { return false }
        let symbol = text(token)
        return symbol == ")" || symbol == "]" || symbol == "}"
    }

    /// Whether a line break (or a comment holding one) separates the next token from the last one.
    var newlineBefore: Bool { lineBreakBefore() }

    @inline(never)
    private func lineBreakBefore() -> Bool {
        guard let token = cur else { return true }
        return hasNewline(from: lastEnd, to: token.location)
    }

    @inline(never)
    func hasNewline(from start: Int, to end: Int) -> Bool {
        guard end > start else { return false }
        return text(SyntaxToken(kind: .space, location: start, length: end - start)).utf16.contains { $0 == 10 || $0 == 13 }
    }

    /// Where the token before `offset` ends.
    private func end(before offset: Int) -> Int {
        offset == 0 ? lastEnd : (tok(offset - 1)?.end ?? lastEnd)
    }

    // MARK: Building

    func start(_ kind: SyntaxKind) { b.startNode(kind) }
    func start(_ kind: SyntaxKind, at checkpoint: TreeBuilder.Checkpoint) { b.startNode(kind, at: checkpoint) }
    func finish() { b.finishNode() }
    func checkpoint() -> TreeBuilder.Checkpoint { b.checkpoint() }

    /// Consumes the next significant token.
    @inline(never)
    func bump() {
        guard let token = cur else { return }
        lastEnd = token.end
        consumed += 1
        b.bump()
    }

    /// Consumes the adjacent tokens spelling `spelling`, if they come next.
    @discardableResult
    @inline(never)
    func bump(_ spelling: String) -> Bool {
        guard let token = cur, b.bump(spelling) else { return false }
        lastEnd = token.location + spelling.utf16.count
        consumed += 1
        return true
    }

    /// Wraps the next token in a `kind` node.
    @inline(never)
    func wrap(_ kind: SyntaxKind) {
        start(kind)
        bump()
        finish()
    }

    /// Consumes `symbol` if it comes next as a symbol; otherwise records "expected `symbol`".
    @discardableResult
    @inline(never)
    func expect(_ symbol: String) -> Bool {
        if atSym(symbol) {
            bump()
            return true
        }
        b.error("expected `\(symbol)`")
        return false
    }

    @discardableResult
    @inline(never)
    func expectWord(_ name: String) -> Bool {
        if atWord(name) {
            bump()
            return true
        }
        b.error("expected `\(name)`")
        return false
    }

    @inline(never)
    func error(_ message: String) { b.error(message) }

    @inline(never)
    func errorAndBump(_ message: String) {
        guard let token = cur else { return b.error(message) }
        lastEnd = token.end
        consumed += 1
        b.errorAndBump(message)
    }

    /// `TreeBuilder.recover`, through this parse's own `bump` so `lastEnd` stays right: records an
    /// error, then wraps everything up to a `stop` token in an `error` node, skipping brackets whole
    /// and never consuming a closer it didn't open.
    @inline(never)
    func recover(_ message: String, until stop: Set<String>) {
        b.error(message)
        var open: [String] = []
        var started = false
        while let token = cur {
            let spelling = text(token)
            let bracket = token.kind == .symbol || isLexeme(token, "punctuation.section.embedded")
            if open.isEmpty && stop.contains(spelling) && (bracket || isWordLike(token)) { break }
            if bracket, let closer = Self.pairs[spelling] {
                open.append(closer)
            } else if bracket && Self.closers.contains(spelling) {
                guard let index = open.lastIndex(of: spelling) else { break }
                open.removeSubrange(index...)
            }
            if !started {
                start(.error)
                started = true
            }
            bump()
        }
        if started { finish() }
    }

    static let pairs = ["(": ")", "[": "]", "{": "}"]
    static let closers: Set<String> = [")", "]", "}"]

    /// Records an error and consumes one token when the tree is already too deep to nest further.
    @inline(never)
    func tooDeep() -> Bool {
        guard b.depth >= Self.maxDepth else { return false }
        errorAndBump("too deeply nested")
        return true
    }

    /// Ends a statement: a `;`, or automatic semicolon insertion before a line break, a `}` or the end.
    @inline(never)
    func semicolon() {
        if atSym(";") { return bump() }
        if cur == nil || atCloseBrace || newlineBefore { return }
        error("expected `;`")
    }

    // MARK: Lookahead scans

    /// After a balanced bracket group opened at `start`: the offset past its closer, or `nil` if it
    /// doesn't close before `limit`.
    @inline(never)
    func skipBalanced(_ start: Int, limit: Int) -> Int? {
        var stack: [String] = []
        var offset = start
        while offset < limit, let token = tok(offset) {
            if token.kind == .symbol || isLexeme(token, "punctuation.section.embedded") {
                let spelling = text(token)
                if let closer = Self.pairs[spelling] {
                    stack.append(closer)
                } else if Self.closers.contains(spelling) {
                    guard stack.last == spelling else { return nil }
                    stack.removeLast()
                    if stack.isEmpty { return offset + 1 }
                }
            }
            offset += 1
        }
        return nil
    }

    /// Whether `=>` starts at `offset`, on the line of the token before it.
    @inline(never)
    func arrow(at offset: Int) -> Bool {
        guard let equals = tok(offset), equals.kind == .symbol, text(equals) == "=",
              let greater = tok(offset + 1), greater.kind == .symbol, text(greater) == ">",
              greater.location == equals.end else { return false }
        return !hasNewline(from: end(before: offset), to: equals.location)
    }

    /// Whether the `(` at `start` opens an arrow function's parameters: they read as parameters
    /// and `=>` follows (in TypeScript, maybe after a return type).
    @inline(never)
    func arrowFollows(parenAt start: Int) -> Bool {
        guard let after = parameterListEnd(start) else { return false }
        if arrow(at: after) { return true }
        return ts && atSym(":", after) && arrowAfterReturnType(after + 1)
    }

    /// The offset past the `)` of the list opened at `start`, if what is inside can be parameters.
    /// Each parameter is a name or pattern, then maybe `?`, `: type` or `= default`.
    @inline(never)
    private func parameterListEnd(_ start: Int) -> Int? {
        enum Expecting { case parameter, separator, anything }
        var state = Expecting.parameter
        var angle = 0
        var offset = start + 1
        let limit = start + Self.scanLimit
        while offset < limit, let token = tok(offset) {
            let spelling = token.kind == .symbol ? text(token) : ""
            switch state {
            case .parameter:
                if spelling == ")" { return offset + 1 }
                if spelling == "{" || spelling == "[" {
                    guard let next = skipBalanced(offset, limit: limit) else { return nil }
                    offset = next
                    state = .separator
                    continue
                }
                if spelling == "." && op(offset) == "..." {
                    offset += 3
                    continue
                }
                if ts, let name = word(offset), ["public", "private", "protected", "readonly", "override", "this"].contains(name) {
                    offset += 1
                    state = name == "this" ? .separator : .parameter
                    continue
                }
                guard isIdentifier(offset) else { return nil }
                state = .separator
            case .separator:
                switch spelling {
                case ")": return offset + 1
                case ",": state = .parameter
                case "?" where ts: break
                case ":" where ts: state = .anything
                case "=":
                    guard op(offset) == "=" else { return nil }
                    state = .anything
                default: return nil
                }
            case .anything:
                switch spelling {
                case "(", "[", "{":
                    guard let next = skipBalanced(offset, limit: limit) else { return nil }
                    offset = next
                    continue
                case ")": return angle == 0 ? offset + 1 : nil
                case "]", "}", ";": return nil
                case ",": if angle == 0 { state = .parameter }
                case "<": angle += 1
                case ">": angle = max(0, angle - 1)
                case "=":
                    if arrow(at: offset) { offset += 2; continue }
                default: break
                }
            }
            offset += 1
        }
        return nil
    }

    /// Whether a return type starting at `start` ends in `=>`, before anything a type can't hold.
    @inline(never)
    private func arrowAfterReturnType(_ start: Int) -> Bool {
        var offset = start
        let limit = start + Self.scanLimit
        while offset < limit, let token = tok(offset) {
            if token.kind == .symbol {
                switch text(token) {
                case "(", "[", "{":
                    guard let next = skipBalanced(offset, limit: limit) else { return false }
                    offset = next
                    continue
                case ")", "]", "}", ";", ",": return false
                case "=":
                    guard arrow(at: offset) else { return false }
                    return true
                default: break
                }
            } else if isLexeme(token, "string.regexp") {
                return false
            }
            offset += 1
        }
        return false
    }

    /// The offset past the `>` closing the `<` at `start`, if what is between can be type arguments
    /// (or, with `defaults`, type parameters): no operator a type can't hold, no `;` or stray closer.
    @inline(never)
    func typeArgumentsEnd(_ start: Int, defaults: Bool = false) -> Int? {
        var angle = 0
        var offset = start
        let limit = start + Self.scanLimit
        while offset < limit, let token = tok(offset) {
            switch token.kind {
            case .symbol:
                let spelling = text(token)
                switch spelling {
                case "<": angle += 1
                case ">":
                    angle -= 1
                    if angle == 0 { return offset + 1 }
                case "(", "[", "{":
                    guard let next = skipBalanced(offset, limit: limit) else { return nil }
                    offset = next
                    continue
                case "=":
                    if arrow(at: offset) {
                        offset += 2
                        continue
                    }
                    guard defaults, op(offset) == "=" else { return nil }
                case "&", "|":
                    if let next = tok(offset + 1), next.kind == .symbol, next.location == token.end, text(next) == spelling { return nil }
                case ",", ".", "?", ":", "-": break
                default: return nil
                }
            case .lexeme:
                if token.scope == "string.regexp" { return nil }
            default: break
            }
            offset += 1
        }
        return nil
    }

    /// Whether the `<` at `start` opens type arguments of a call (`f<T>(x)`, `` tag<T>`…` ``).
    @inline(never)
    func typeArgumentsCall(at start: Int) -> Bool {
        guard ts, let after = typeArgumentsEnd(start) else { return false }
        return atSym("(", after) || isTemplateStart(tok(after))
    }

    /// Whether the `<` at `start` opens a generic arrow function's type parameters: `<T>(x: T) => x`.
    @inline(never)
    func genericArrow(at start: Int) -> Bool {
        guard ts, atSym("<", start), let after = typeArgumentsEnd(start, defaults: true), atSym("(", after) else { return false }
        return arrowFollows(parenAt: after)
    }
}
