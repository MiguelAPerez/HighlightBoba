import Foundation

/// Python 3, parsed by recursive descent over the lexer's tokens (see docs/PARSER.md).
///
/// Python's line breaks and indentation are syntax, but they are trivia to the builder, so the
/// parser derives them: a token that starts a line (`TreeBuilder.indentation(of:)`) ends the
/// logical line unless brackets are open or a backslash continues it, and its indentation opens
/// or closes indented blocks. Soft keywords (`match`, `case`, `type`, `_`) are decided here, by
/// position, and a word the lexer guessed wrong is re-lexed.
///
/// Indented blocks are reparse boundaries. A block ends at the first line indented less, which
/// is outside it, so a block reparse ends it at `TreeBuilder.isAtBlockEnd` instead of looking.
public struct PythonParser: IncrementalParser {
    public init() {}

    public var reparseBoundaries: Set<SyntaxKind> { [PythonKind.block, PythonKind.caseBlock] }

    public func parse(_ builder: TreeBuilder) { PythonParse(builder).module() }

    public func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) {
        let parse = PythonParse(builder)
        if kind == PythonKind.caseBlock { parse.caseBlock() } else { parse.block() }
    }
}

/// The node kinds the Python parser makes, which its highlight queries match on.
enum PythonKind {
    static let block = SyntaxKind("block")
    static let caseBlock = SyntaxKind("case_block")

    static let function = SyntaxKind("function")
    static let classDefinition = SyntaxKind("class")
    static let decorated = SyntaxKind("decorated")
    static let decorator = SyntaxKind("decorator")
    static let parameters = SyntaxKind("parameters")
    static let parameter = SyntaxKind("parameter")
    static let defaultValue = SyntaxKind("default")
    static let annotation = SyntaxKind("annotation")
    static let typeParameters = SyntaxKind("type_parameters")
    static let typeParameter = SyntaxKind("type_parameter")

    static let ifStatement = SyntaxKind("if_statement")
    static let elifClause = SyntaxKind("elif_clause")
    static let elseClause = SyntaxKind("else_clause")
    static let forStatement = SyntaxKind("for_statement")
    static let whileStatement = SyntaxKind("while_statement")
    static let tryStatement = SyntaxKind("try_statement")
    static let exceptClause = SyntaxKind("except_clause")
    static let finallyClause = SyntaxKind("finally_clause")
    static let withStatement = SyntaxKind("with_statement")
    static let withItem = SyntaxKind("with_item")
    static let matchStatement = SyntaxKind("match_statement")
    static let caseClause = SyntaxKind("case_clause")
    static let guardClause = SyntaxKind("guard")

    static let expressionStatement = SyntaxKind("expression_statement")
    static let assignment = SyntaxKind("assignment")
    static let target = SyntaxKind("target")
    static let typeAlias = SyntaxKind("type_alias")
    static let importStatement = SyntaxKind("import_statement")
    static let importFrom = SyntaxKind("import_from")
    static let keywordStatement = SyntaxKind("keyword_statement")

    static let binary = SyntaxKind("binary")
    static let unary = SyntaxKind("unary")
    static let conditional = SyntaxKind("conditional")
    static let lambda = SyntaxKind("lambda")
    static let namedExpression = SyntaxKind("named_expression")
    static let starred = SyntaxKind("starred")
    static let awaitExpression = SyntaxKind("await")
    static let yieldExpression = SyntaxKind("yield")
    static let call = SyntaxKind("call")
    static let arguments = SyntaxKind("arguments")
    static let keywordArgument = SyntaxKind("keyword_argument")
    static let attribute = SyntaxKind("attribute")
    static let subscription = SyntaxKind("subscript")
    static let slice = SyntaxKind("slice")
    static let parenthesized = SyntaxKind("parenthesized")
    static let tuple = SyntaxKind("tuple")
    static let list = SyntaxKind("list")
    static let dictionary = SyntaxKind("dictionary")
    static let set = SyntaxKind("set")
    static let pair = SyntaxKind("pair")
    static let generator = SyntaxKind("generator")
    static let forClause = SyntaxKind("for_clause")
    static let ifClause = SyntaxKind("if_clause")
    static let string = SyntaxKind("string")
    static let field = SyntaxKind("fstring_field")
    static let formatSpec = SyntaxKind("format_spec")

    static let casePattern = SyntaxKind("case_pattern")
    static let orPattern = SyntaxKind("or_pattern")
    static let asPattern = SyntaxKind("as_pattern")
    static let sequencePattern = SyntaxKind("sequence_pattern")
    static let mappingPattern = SyntaxKind("mapping_pattern")
    static let classPattern = SyntaxKind("class_pattern")
    static let keywordPattern = SyntaxKind("keyword_pattern")
    static let valuePattern = SyntaxKind("value_pattern")
}

/// One parse: the builder, plus what Python's logical lines need.
final class PythonParse {
    typealias K = PythonKind

    let b: TreeBuilder
    /// Brackets open around the parser. Inside them line breaks join lines.
    var brackets = 0
    /// A token that starts a line but belongs to the logical line being parsed: the first token of
    /// a statement, or the token after a backslash continuation.
    var joined = -1
    /// Expression nesting, so input like 100,000 `(` can't run the stack out.
    var nesting = 0
    /// The indentation of the line the statement being parsed starts on.
    var lineIndent = 0

    static let maxNesting = 100
    static let maxDepth = 200
    /// The last guard, when a frame is bigger than the limits allow for: a debug build's.
    let stack = StackGuard()

    init(_ builder: TreeBuilder) { b = builder }

    // MARK: Tokens

    private var textCache = (location: -1, length: 0, text: "")

    func text(_ token: SyntaxToken) -> String {
        if textCache.location != token.location || textCache.length != token.length {
            textCache = (token.location, token.length, b.text(of: token))
        }
        return textCache.text
    }

    /// The width of `token`'s indentation if it starts a line, tabs to the next multiple of 8.
    func width(_ token: SyntaxToken) -> Int? {
        guard let indentation = b.indentation(of: token) else { return nil }
        var width = 0
        for unit in indentation.utf16 { width = unit == 9 ? (width / 8 + 1) * 8 : width + 1 }
        return width
    }

    static let statementOnly: Set<String> = ["def", "class", "return", "import", "pass", "break", "continue", "raise",
                                             "global", "nonlocal", "del", "assert", "while", "with", "try", "except",
                                             "finally", "elif"]

    /// The next token if it continues the logical line, else `nil`.
    ///
    /// Outside brackets a token that starts a line ends the logical line. Inside them it doesn't,
    /// unless it's a keyword that only starts a statement: an unclosed `(` then ends there, so a
    /// half-typed call doesn't swallow the rest of the file. In a block reparse, the end of the
    /// block outside brackets is the end of a line: the block ended there before, at a line break.
    var cur: SyntaxToken? {
        if brackets == 0 && b.isAtBlockEnd { return nil }
        guard let token = b.current else { return nil }
        if token.location == joined { return token }
        if token.kind == .symbol && text(token) == "\\" {
            guard let next = b.peek(1), b.indentation(of: next) != nil else { return token }
            if brackets == 0 && token.location != joined && b.indentation(of: token) != nil { return nil }
            b.bump()
            joined = next.location
            return self.cur
        }
        guard let width = width(token) else { return token }
        guard brackets > 0, !Self.statementOnly.contains(keyword(token) ?? "") else { return nil }
        // A line no deeper than the statement's, after a line that doesn't ask for more, is a new
        // statement: `x = f(1, 2` then `y = 3`.
        if width <= lineIndent, let previous = b.previous {
            let word = keyword(token) ?? ""
            // No clause follows a comma: `items = [1, 2,` then `for item in items:`.
            if ["for", "if", "async"].contains(word) && text(previous) == "," { return nil }
            // Strings on consecutive lines concatenate: `("a"` then `"b")`.
            if !continuesLine(previous) && startsStatement(token) && !(isString(previous) && isString(token)) { return nil }
        }
        return token
    }

    /// Whether a statement can start with `token`: not a closing bracket, a binary operator, or a
    /// keyword that continues an expression (`and`, `if`, `for`…).
    func startsStatement(_ token: SyntaxToken) -> Bool {
        if token.kind == .symbol { return ["(", "[", "{", "-", "+", "~", "*", "@", "."].contains(text(token)) }
        return !["and", "or", "in", "is", "if", "else", "for", "async"].contains(keyword(token) ?? "")
    }

    /// Whether a line ending in `token` asks for more: an opening bracket, a comma or an operator.
    func continuesLine(_ token: SyntaxToken) -> Bool {
        switch token.kind {
        case .symbol: return !Self.closers.contains(text(token))
        case .lexeme:
            if let word = keyword(token) { return !["None", "True", "False"].contains(word) }
            return token.scope == "punctuation.section.embedded" && text(token) == "{"
        default: return false
        }
    }

    /// The next token wherever it is, for a statement loop: `nil` at the end, or at the end of the block a reparse covers.
    var nextLine: SyntaxToken? { b.isAtBlockEnd ? nil : b.current }

    func at(_ wanted: String) -> Bool {
        guard let token = cur else { return false }
        return text(token) == wanted
    }

    func keyword(_ token: SyntaxToken) -> String? {
        token.kind == .lexeme && token.scope == "keyword" ? text(token) : nil
    }

    func atKeyword(_ wanted: String) -> Bool {
        guard let token = cur else { return false }
        return keyword(token) == wanted
    }

    static let nameScopes: Set<String> = ["support.function", "entity.name.type", "variable.language", "entity.name.function"]
    static let softKeywords: Set<String> = ["match", "case", "type"]

    func isName(_ token: SyntaxToken) -> Bool {
        switch token.kind {
        case .word: return true
        case .lexeme:
            guard let scope = token.scope else { return false }
            return Self.nameScopes.contains(scope) || (scope == "keyword" && Self.softKeywords.contains(text(token)))
        default: return false
        }
    }

    var atName: Bool { cur.map(isName) ?? false }

    /// Bumps a name, re-lexing a soft keyword the lexer took for a keyword as a plain name.
    func bumpName() {
        if let token = cur, keyword(token) != nil { b.relex(as: "softKeywordName") }
        b.bump()
    }

    func isString(_ token: SyntaxToken) -> Bool {
        token.kind == .lexeme && (token.scope == "string.quoted" || token.scope == "constant.character.escape")
    }

    func isFieldBrace(_ token: SyntaxToken, _ brace: String) -> Bool {
        token.kind == .lexeme && token.scope == "punctuation.section.embedded" && text(token) == brace
    }

    static let multiStarts: Set<String> = ["*", "/", ">", "<", "=", "!", "-", ":", "+", "%", "&", "|", "^", "@", "."]
    static let twoCharOps: Set<String> = ["**", "//", ">>", "<<", "<=", ">=", "==", "!=", "->", ":=", "+=", "-=", "*=",
                                          "/=", "%=", "&=", "|=", "^=", "@="]
    static let threeCharOps: Set<String> = ["**=", "//=", ">>=", "<<=", "..."]

    private var opCache = (location: -1, length: 0, op: String?.none)

    /// The operator the symbols at the next token spell, longest first: `**=`, `**`, `*`.
    var op: String? {
        guard let token = cur, token.kind == .symbol else { return nil }
        if opCache.location == token.location && opCache.length == token.length { return opCache.op }
        let result = spell(from: token, offset: 0)
        opCache = (token.location, token.length, result)
        return result
    }

    /// The operator at the token `offset` places ahead, which must be on the same logical line.
    func op(at offset: Int) -> String? {
        guard let token = b.peek(offset), token.kind == .symbol else { return nil }
        return spell(from: token, offset: offset)
    }

    private func spell(from token: SyntaxToken, offset: Int) -> String {
        let first = text(token)
        guard Self.multiStarts.contains(first), let second = b.peek(offset + 1), second.kind == .symbol,
              second.location == token.end else { return first }
        let two = first + b.text(of: second)
        if two == ".." || ["**", "//", ">>", "<<"].contains(two),
           let third = b.peek(offset + 2), third.kind == .symbol, third.location == second.end,
           Self.threeCharOps.contains(two + b.text(of: third)) {
            return two + b.text(of: third)
        }
        return Self.twoCharOps.contains(two) ? two : first
    }

    func atOp(_ wanted: String) -> Bool { op == wanted }

    func expectOp(_ wanted: String) {
        if atOp(wanted) { b.bump(wanted) } else { b.error("expected `\(wanted)`") }
    }

    func expectText(_ wanted: String) {
        if at(wanted) { b.bump() } else { b.error("expected `\(wanted)`") }
    }

    func node(_ kind: SyntaxKind, _ body: () -> Void) {
        b.startNode(kind)
        body()
        b.finishNode()
    }

    func wrap(_ kind: SyntaxKind, from checkpoint: TreeBuilder.Checkpoint) {
        b.startNode(kind, at: checkpoint)
        b.finishNode()
    }

    /// Wraps the rest of the logical line in an `error` node.
    func restOfLine(_ message: String) {
        guard cur != nil else { return }
        b.error(message)
        b.startNode(.error)
        while cur != nil { b.bump() }
        b.finishNode()
    }

    /// Records an error and wraps the next token in an `error` node.
    func junk(_ message: String) {
        if cur != nil { b.errorAndBump(message) }
    }

    static let closers: Set<String> = [")", "]", "}"]

    /// Whether the next token ends a bracketed list: a closing bracket, a field's `}`, or the line's end.
    var atListEnd: Bool {
        guard let token = cur else { return true }
        return Self.closers.contains(text(token))
    }

    /// `element`s separated by commas, until a closing bracket. With `afterFirst`, one element was
    /// read already. A missing comma, or a token no element starts with, is wrapped in an error.
    func commaList(afterFirst: Bool = false, _ element: () -> Void) {
        var needsComma = afterFirst
        while !atListEnd {
            if needsComma {
                if at(",") {
                    b.bump()
                    needsComma = false
                } else {
                    junk("expected `,`")
                }
                continue
            }
            let before = cur?.location
            element()
            if cur?.location == before {
                if at(",") {
                    b.error("expected an element")
                    b.bump()
                } else {
                    junk("unexpected `\(cur.map(text) ?? "")`")
                }
                needsComma = false
            } else {
                needsComma = true
            }
        }
    }

    /// Parses a bracketed list: `open`, `body`, then `close`, with line breaks joined inside.
    func bracketed(_ open: String, _ close: String, _ body: () -> Void) {
        b.bump(open)
        brackets += 1
        body()
        // Read inside the brackets, so a line break before the closer doesn't hide it.
        let closed = at(close)
        brackets -= 1
        if closed { b.bump() } else { b.error("expected `\(close)`") }
    }
}
