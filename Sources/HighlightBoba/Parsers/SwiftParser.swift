import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Swift's parser: hand-written recursive descent over the Swift lexer's tokens.
///
/// It builds declarations, statements, expressions (with operator precedence), patterns and types,
/// so the highlight queries in `Queries/swift.json` can tell a declared name from a use, a type
/// position from a value position, and a contextual keyword (`get`, `some`, `async`…) used as an
/// identifier from the keyword. It also re-lexes the few places the lexer can't read alone: a tuple
/// index chain (`t.0.1`), a `/` after a postfix `!` or `?` (`x!/2`), and an operator name that
/// contains `/` (`infix operator /+/`).
///
/// `{ }` bodies are reparse boundaries: code blocks, type and extension bodies, accessor blocks and
/// closures. Each parses the same whatever surrounds it, because every flag the parse carries is
/// reset at the brace.
public struct SwiftParser: IncrementalParser {
    public init() {}

    public var reparseBoundaries: Set<SyntaxKind> {
        [SwiftKind.codeBlock, SwiftKind.memberBlock, SwiftKind.accessorBlock, SwiftKind.closure]
    }

    public func parse(_ builder: TreeBuilder) { SwiftParse(builder).sourceFile() }

    public func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { SwiftParse(builder).block(kind) }
}

/// The node kinds the Swift parser makes. Highlight queries match on these names.
enum SwiftKind {
    // Blocks (the reparse boundaries).
    static let codeBlock = SyntaxKind("codeBlock")
    static let memberBlock = SyntaxKind("memberBlock")
    static let accessorBlock = SyntaxKind("accessorBlock")
    static let closure = SyntaxKind("closure")

    // Declarations.
    static let attribute = SyntaxKind("attribute")
    static let attributeArguments = SyntaxKind("attributeArguments")
    static let importDecl = SyntaxKind("importDecl")
    static let funcDecl = SyntaxKind("funcDecl")
    static let initDecl = SyntaxKind("initDecl")
    static let deinitDecl = SyntaxKind("deinitDecl")
    static let subscriptDecl = SyntaxKind("subscriptDecl")
    static let varDecl = SyntaxKind("varDecl")
    static let patternBinding = SyntaxKind("patternBinding")
    static let classDecl = SyntaxKind("classDecl")
    static let structDecl = SyntaxKind("structDecl")
    static let enumDecl = SyntaxKind("enumDecl")
    static let protocolDecl = SyntaxKind("protocolDecl")
    static let actorDecl = SyntaxKind("actorDecl")
    static let extensionDecl = SyntaxKind("extensionDecl")
    static let typealiasDecl = SyntaxKind("typealiasDecl")
    static let associatedtypeDecl = SyntaxKind("associatedtypeDecl")
    static let enumCaseDecl = SyntaxKind("enumCaseDecl")
    static let enumCaseElement = SyntaxKind("enumCaseElement")
    static let operatorDecl = SyntaxKind("operatorDecl")
    static let precedenceGroupDecl = SyntaxKind("precedenceGroupDecl")
    static let precedenceGroupBody = SyntaxKind("precedenceGroupBody")
    static let macroDecl = SyntaxKind("macroDecl")
    static let accessor = SyntaxKind("accessor")
    static let genericParameters = SyntaxKind("genericParameters")
    static let genericParameter = SyntaxKind("genericParameter")
    static let whereClause = SyntaxKind("whereClause")
    static let inheritance = SyntaxKind("inheritance")
    static let parameterClause = SyntaxKind("parameterClause")
    static let parameter = SyntaxKind("parameter")
    static let typeAnnotation = SyntaxKind("typeAnnotation")
    static let effects = SyntaxKind("effects")
    static let returnClause = SyntaxKind("returnClause")
    static let directive = SyntaxKind("directive")

    // Names, by role.
    static let typeName = SyntaxKind("typeName")
    static let functionName = SyntaxKind("functionName")
    static let enumCaseName = SyntaxKind("enumCaseName")
    static let parameterName = SyntaxKind("parameterName")
    static let parameterLabel = SyntaxKind("parameterLabel")
    static let argumentLabel = SyntaxKind("argumentLabel")
    static let statementLabel = SyntaxKind("statementLabel")
    static let wildcard = SyntaxKind("wildcard")

    // Statements.
    static let ifStmt = SyntaxKind("ifStmt")
    static let guardStmt = SyntaxKind("guardStmt")
    static let whileStmt = SyntaxKind("whileStmt")
    static let repeatStmt = SyntaxKind("repeatStmt")
    static let forStmt = SyntaxKind("forStmt")
    static let switchStmt = SyntaxKind("switchStmt")
    static let switchCase = SyntaxKind("switchCase")
    static let casePattern = SyntaxKind("casePattern")
    static let returnStmt = SyntaxKind("returnStmt")
    static let throwStmt = SyntaxKind("throwStmt")
    static let jumpStmt = SyntaxKind("jumpStmt")
    static let deferStmt = SyntaxKind("deferStmt")
    static let doStmt = SyntaxKind("doStmt")
    static let catchClause = SyntaxKind("catchClause")
    static let labeledStmt = SyntaxKind("labeledStmt")
    static let conditionList = SyntaxKind("conditionList")
    static let optionalBinding = SyntaxKind("optionalBinding")
    static let caseCondition = SyntaxKind("caseCondition")

    // Expressions.
    static let identifier = SyntaxKind("identifier")
    static let binaryExpr = SyntaxKind("binaryExpr")
    static let ternaryExpr = SyntaxKind("ternaryExpr")
    static let castExpr = SyntaxKind("castExpr")
    static let prefixExpr = SyntaxKind("prefixExpr")
    static let postfixExpr = SyntaxKind("postfixExpr")
    static let tryExpr = SyntaxKind("tryExpr")
    static let awaitExpr = SyntaxKind("awaitExpr")
    static let callExpr = SyntaxKind("callExpr")
    static let subscriptExpr = SyntaxKind("subscriptExpr")
    static let argument = SyntaxKind("argument")
    static let memberExpr = SyntaxKind("memberExpr")
    static let memberName = SyntaxKind("memberName")
    static let implicitMember = SyntaxKind("implicitMember")
    static let tupleExpr = SyntaxKind("tupleExpr")
    static let arrayLiteral = SyntaxKind("arrayLiteral")
    static let dictionaryLiteral = SyntaxKind("dictionaryLiteral")
    static let dictionaryElement = SyntaxKind("dictionaryElement")
    static let stringLiteral = SyntaxKind("stringLiteral")
    static let interpolation = SyntaxKind("interpolation")
    static let regexLiteral = SyntaxKind("regexLiteral")
    static let keyPath = SyntaxKind("keyPath")
    static let macroExpansion = SyntaxKind("macroExpansion")
    static let operatorReference = SyntaxKind("operatorReference")
    static let closureSignature = SyntaxKind("closureSignature")
    static let captureList = SyntaxKind("captureList")
    static let captureItem = SyntaxKind("captureItem")
    static let closureParameter = SyntaxKind("closureParameter")

    // Patterns.
    static let identifierPattern = SyntaxKind("identifierPattern")
    static let valueBindingPattern = SyntaxKind("valueBindingPattern")
    static let isPattern = SyntaxKind("isPattern")

    // Types.
    static let typeIdentifier = SyntaxKind("typeIdentifier")
    static let genericArguments = SyntaxKind("genericArguments")
    static let tupleType = SyntaxKind("tupleType")
    static let tupleTypeElement = SyntaxKind("tupleTypeElement")
    static let arrayType = SyntaxKind("arrayType")
    static let dictionaryType = SyntaxKind("dictionaryType")
    static let optionalType = SyntaxKind("optionalType")
    static let functionType = SyntaxKind("functionType")
    static let compositionType = SyntaxKind("compositionType")
    static let someType = SyntaxKind("someType")
    static let anyType = SyntaxKind("anyType")
    static let attributedType = SyntaxKind("attributedType")
}

/// One parse: the builder, plus what the parser tracks on top of it.
final class SwiftParse {
    private typealias K = SwiftKind

    private let b: TreeBuilder
    /// Where the last significant token this parser consumed ends, or -1 after recovery skipped
    /// tokens it can't see. Operators are told apart by the whitespace around them.
    private var lastEnd = -1
    /// Whether a `{` after an expression is a trailing closure. Off in the conditions of `if`,
    /// `while`, `guard`, `for` and `switch`, where it opens the body.
    private var bracesAllowed = true
    /// Inside a `case` pattern, a `catch` pattern or a `for` pattern: `let x` and `is T` are patterns.
    private var patternMode = false
    /// Under `let`/`var` in a pattern: a bare name declares a variable.
    private var binding = false
    /// In a variable's initializer, where `{ willSet` or `{ didSet` opens observers, not a closure.
    /// Kept off elsewhere, so a trailing closure's parse never looks past its `{` first.
    private var observersMayFollow = false
    private var textCache: (location: Int, text: String) = (-1, "")
    private var lineStartCache: (location: Int, lastEnd: Int, value: Bool) = (-1, -1, false)

    /// Past this many open nodes the parser stops nesting and skips the rest of the construct, so
    /// hostile input can't run a background thread's stack out. The limit is on the tree's depth,
    /// so a block's reparse stops exactly where a whole parse does.
    static let maxDepth = 64
    /// The last guard, when a frame is bigger than the depth limit allows for.
    private let stack = StackGuard()

    init(_ builder: TreeBuilder) {
        b = builder
    }

    // MARK: Entry points

    func sourceFile() {
        while let token = b.current {
            if isCloser(token) {
                errorAndBump("unexpected `\(text(token))`")
                continue
            }
            statementInList()
        }
    }

    func block(_ kind: SyntaxKind) {
        switch kind {
        case K.closure: closure()
        case K.accessorBlock: accessorBlock()
        case K.memberBlock: braceBlock(K.memberBlock)
        default: braceBlock(K.codeBlock)
        }
    }

    // MARK: Tokens

    private var cur: SyntaxToken? { b.current }

    private func text(_ token: SyntaxToken) -> String {
        if textCache.location == token.location && textCache.text.utf16.count == token.length { return textCache.text }
        let value = b.text(of: token)
        textCache = (token.location, value)
        return value
    }

    private var curText: String? { cur.map(text) }

    private func bump() {
        if let token = cur { lastEnd = token.end }
        b.bump()
    }

    /// Bumps the tokens spelling `spelling` if they come next.
    @discardableResult
    private func eat(_ spelling: String) -> Bool {
        guard b.at(spelling) else { return false }
        // The last token of the spelling ends where the spelling does.
        if let token = cur { lastEnd = token.location + spelling.utf16.count }
        return b.bump(spelling)
    }

    @discardableResult
    private func expect(_ spelling: String) -> Bool {
        if eat(spelling) { return true }
        b.error("expected `\(spelling)`")
        return false
    }

    private func errorAndBump(_ message: String) {
        if let token = cur { lastEnd = token.end }
        b.errorAndBump(message)
    }

    private func recover(_ message: String, until stop: Set<String>) {
        let before = cur?.location
        b.recover(message, until: stop)
        if cur?.location != before { lastEnd = -1 }
    }

    private func node(_ kind: SyntaxKind, _ body: () -> Void) {
        b.startNode(kind)
        body()
        b.finishNode()
    }

    private func isKeyword(_ token: SyntaxToken?, _ word: String) -> Bool {
        guard let token, token.kind == .lexeme, token.scope == "keyword" else { return false }
        return text(token) == word
    }

    private func atKeyword(_ word: String) -> Bool { isKeyword(cur, word) }

    private func isKeyword(_ token: SyntaxToken?) -> Bool { token?.kind == .lexeme && token?.scope == "keyword" }

    private func isCloser(_ token: SyntaxToken) -> Bool {
        guard token.length == 1, token.kind == .symbol || token.scope == "punctuation.section.embedded" else { return false }
        let value = text(token)
        return value == ")" || value == "]" || value == "}"
    }

    private func isSymbol(_ token: SyntaxToken?, _ value: String) -> Bool {
        guard let token, token.kind == .symbol else { return false }
        return text(token) == value
    }

    /// A word, a capitalized name or function name the lexer scoped, or a contextual keyword.
    private func isName(_ token: SyntaxToken?) -> Bool {
        guard let token else { return false }
        switch token.kind {
        case .word: return true
        case .lexeme:
            switch token.scope {
            case "entity.name.type", "entity.name.function": return true
            case "keyword": return Self.contextual.contains(text(token))
            default: return false
            }
        default: return false
        }
    }

    /// Whether `` `name` `` starts at `offset`.
    private func backtickAhead(_ offset: Int = 0) -> Bool {
        guard isSymbol(b.peek(offset), "`"), let word = b.peek(offset + 1), word.kind == .word || word.kind == .lexeme,
              isSymbol(b.peek(offset + 2), "`") else { return false }
        return true
    }

    private func atName() -> Bool { isName(cur) || backtickAhead() }

    /// What may label an argument or parameter: any name or keyword (`for:`, `in:`, `default:`).
    private func isLabel(_ token: SyntaxToken?) -> Bool {
        guard let token else { return false }
        if isName(token) || isKeyword(token) { return true }
        return token.kind == .lexeme && (token.scope == "variable.language" || token.scope == "constant.language")
    }

    /// Bumps a name, backticked or not. Call only at one.
    private func bumpName() {
        if backtickAhead() {
            bump()
            bump()
            bump()
        } else {
            bump()
        }
    }

    /// A name in a node of `kind`, or a `_` in a `wildcard` node.
    private func name(_ kind: SyntaxKind) {
        if curText == "_" {
            node(K.wildcard) { bump() }
        } else {
            node(kind) { bumpName() }
        }
    }

    private static let contextual: Set<String> = [
        "open", "async", "some", "any", "final", "override", "mutating", "nonmutating", "lazy", "weak",
        "unowned", "convenience", "required", "dynamic", "indirect", "get", "set", "willSet", "didSet", "actor",
        "nonisolated", "isolated", "consume", "borrowing", "consuming", "package", "macro", "infix", "prefix",
        "postfix"
    ]

    /// Whether a line break separates the last consumed token from `token`.
    private func lineBreakBefore(_ token: SyntaxToken) -> Bool {
        guard lastEnd >= 0 else { return true }
        guard token.location > lastEnd else { return false }
        if lineStartCache.location == token.location && lineStartCache.lastEnd == lastEnd { return lineStartCache.value }
        let gap = b.text(of: SyntaxToken(kind: .space, location: lastEnd, length: token.location - lastEnd))
        let value = gap.utf16.contains(10) || gap.utf16.contains(13)
        lineStartCache = (token.location, lastEnd, value)
        return value
    }

    private var atLineStart: Bool { cur.map(lineBreakBefore) ?? true }

    private func adjacent(_ first: SyntaxToken?, _ second: SyntaxToken?) -> Bool {
        guard let first, let second else { return false }
        return first.end == second.location
    }

    /// Runs `body` with the flags given changed. Opening a bracket (`braces: true`) also ends a
    /// variable initializer's top level, where observers may follow.
    private func withFlags(braces: Bool? = nil, pattern: Bool? = nil, binding: Bool? = nil, observers: Bool? = nil,
                           _ body: () -> Void) {
        let saved = (bracesAllowed, patternMode, self.binding, observersMayFollow)
        if let braces { bracesAllowed = braces }
        if let pattern { patternMode = pattern }
        if let binding { self.binding = binding }
        if let observers { observersMayFollow = observers } else if braces == true { observersMayFollow = false }
        body()
        (bracesAllowed, patternMode, self.binding, observersMayFollow) = saved
    }

    /// Too deep to nest further: skips the rest of the construct.
    private func tooDeep() -> Bool {
        guard b.depth >= Self.maxDepth || stack.isLow else { return false }
        recover("nesting too deep", until: [])
        return true
    }

    // MARK: Operators

    private static let operatorCharacters = Set("/=-+!*%<>&|^~?.".utf16)

    private func isOperatorCharacter(_ token: SyntaxToken?) -> Bool {
        guard let token, token.kind == .symbol, token.length == 1 else { return false }
        return Self.operatorCharacters.contains(text(token).utf16.first!)
    }

    /// The operator spelled by the adjacent operator characters at `offset`: its text and token count.
    /// Only an operator that starts with `.` may contain one.
    private func operatorAhead(_ offset: Int = 0) -> (text: String, count: Int)? {
        guard let first = b.peek(offset), isOperatorCharacter(first) else { return nil }
        var spelling = text(first)
        let dotted = spelling == "."
        var count = 1
        var previous = first
        while count < 8, let next = b.peek(offset + count), adjacent(previous, next), isOperatorCharacter(next) {
            let character = text(next)
            if character == "." && !dotted { break }
            spelling += character
            count += 1
            previous = next
        }
        return (spelling, count)
    }

    private func bumpTokens(_ count: Int) {
        for _ in 0..<count { bump() }
    }

    private enum Associativity { case left, right }

    private static let precedence: [String: (Int, Associativity)] = [
        "<<": (160, .left), ">>": (160, .left), "&<<": (160, .left), "&>>": (160, .left),
        "*": (150, .left), "/": (150, .left), "%": (150, .left), "&*": (150, .left), "&": (150, .left),
        "+": (140, .left), "-": (140, .left), "&+": (140, .left), "&-": (140, .left), "|": (140, .left), "^": (140, .left),
        "..<": (135, .left), "...": (135, .left),
        "??": (131, .right),
        "<": (130, .left), "<=": (130, .left), ">": (130, .left), ">=": (130, .left), "==": (130, .left),
        "!=": (130, .left), "===": (130, .left), "!==": (130, .left), "~=": (130, .left),
        ".==": (130, .left), ".!=": (130, .left), ".<": (130, .left), ".<=": (130, .left), ".>": (130, .left), ".>=": (130, .left),
        "&&": (120, .left), "||": (110, .left),
        "=": (90, .right), "*=": (90, .right), "/=": (90, .right), "%=": (90, .right), "+=": (90, .right),
        "-=": (90, .right), "<<=": (90, .right), ">>=": (90, .right), "&=": (90, .right), "|=": (90, .right),
        "^=": (90, .right), "&*=": (90, .right), "&+=": (90, .right), "&-=": (90, .right), "&<<=": (90, .right),
        "&>>=": (90, .right), ".&=": (90, .right), ".|=": (90, .right), ".^=": (90, .right)
    ]
    private static let defaultPrecedence = 105
    private static let ternaryPrecedence = 100
    private static let castPrecedence = 132

    // MARK: Statements

    /// One statement in a list, then its `;`. Makes progress: a token no statement starts with is
    /// wrapped in an error.
    private func statementInList() {
        guard let token = cur else { return }
        statement()
        if cur?.location == token.location, let stuck = cur, !isCloser(stuck) {
            errorAndBump("unexpected `\(text(stuck))`")
        }
        while eat(";") {}
    }

    /// Statements until a closing bracket (or, in a switch case, the next case).
    private func statements(inSwitchCase: Bool = false) {
        while let token = cur {
            if isCloser(token) { break }
            if inSwitchCase && switchCaseAhead() { break }
            statementInList()
        }
    }

    private func statement() {
        guard let token = cur, !tooDeep() else { return }
        if token.scope == "meta.preprocessor", directive(token) { return }
        if declarationAhead() {
            declaration()
            return
        }
        if token.kind == .lexeme && token.scope == "keyword" {
            switch text(token) {
            case "if": ifStatement(); return
            case "guard": guardStatement(); return
            case "while": whileStatement(); return
            case "repeat": repeatStatement(); return
            case "for": forStatement(); return
            case "switch": switchStatement(); return
            case "do": doStatement(); return
            case "defer":
                node(K.deferStmt) {
                    bump()
                    codeBlock()
                }
                return
            case "return", "throw":
                node(text(token) == "return" ? K.returnStmt : K.throwStmt) {
                    bump()
                    if let next = cur, !isCloser(next), !b.at(";"), !lineBreakBefore(next), !switchCaseAhead() { expression() }
                }
                return
            case "break", "continue", "fallthrough":
                node(K.jumpStmt) {
                    bump()
                    if let next = cur, isName(next), !lineBreakBefore(next) { bump() }
                }
                return
            default: break
            }
        }
        // `label: for …`
        if isName(token), isSymbol(b.peek(1), ":"), let loop = b.peek(2),
           ["for", "while", "repeat", "if", "switch", "do"].contains(where: { isKeyword(loop, $0) }) {
            node(K.labeledStmt) {
                node(K.statementLabel) { bump() }
                bump()
                statement()
            }
            return
        }
        expression()
    }

    /// `#if`, `#elseif`, `#else` and `#endif` lines. Their clauses stay in the enclosing list.
    private func directive(_ token: SyntaxToken) -> Bool {
        let value = text(token)
        guard ["#if", "#elseif", "#else", "#endif"].contains(value) else { return false }
        node(K.directive) {
            bump()
            if value == "#if" || value == "#elseif", let next = cur, !lineBreakBefore(next) {
                withFlags(braces: false) { expression() }
            }
        }
        return true
    }

    private func codeBlock() {
        guard b.at("{") else {
            b.error("expected `{`")
            return
        }
        braceBlock(K.codeBlock)
    }

    /// A `{ }` of statements: a code block or a type body. Members and statements parse alike.
    private func braceBlock(_ kind: SyntaxKind) {
        node(kind) {
            bump()
            withFlags(braces: true, pattern: false, binding: false) { statements() }
            expect("}")
        }
    }

    private func ifStatement() {
        node(K.ifStmt) {
            bump()
            conditions()
            codeBlock()
            if atKeyword("else") {
                bump()
                if atKeyword("if") { ifStatement() } else { codeBlock() }
            }
        }
    }

    private func guardStatement() {
        node(K.guardStmt) {
            bump()
            conditions()
            expect("else")
            codeBlock()
        }
    }

    private func whileStatement() {
        node(K.whileStmt) {
            bump()
            conditions()
            codeBlock()
        }
    }

    private func repeatStatement() {
        node(K.repeatStmt) {
            bump()
            codeBlock()
            if atKeyword("while") {
                bump()
                withFlags(braces: false) { expression() }
            } else {
                b.error("expected `while`")
            }
        }
    }

    private func forStatement() {
        node(K.forStmt) {
            bump()
            if atKeyword("try") { bump() }
            if atKeyword("await") { bump() }
            if atKeyword("case") {
                bump()
                withFlags(braces: false, pattern: true) { expression() }
            } else {
                withFlags(braces: false, pattern: true, binding: true) { _ = unary() }
            }
            if b.at(":") { typeAnnotation() }
            if atKeyword("in") {
                bump()
                withFlags(braces: false) { expression() }
            } else {
                recover("expected `in`", until: ["{"])
            }
            if atKeyword("where") {
                bump()
                withFlags(braces: false) { expression() }
            }
            codeBlock()
        }
    }

    /// The comma-separated conditions of `if`, `guard` and `while`.
    private func conditions() {
        node(K.conditionList) {
            withFlags(braces: false) {
                while let token = cur, !b.at("{") {
                    let before = token.location
                    condition()
                    if eat(",") { continue }
                    if cur?.location == before, let stuck = cur, !isCloser(stuck), !atKeyword("else") {
                        errorAndBump("unexpected `\(text(stuck))` in a condition")
                        continue
                    }
                    break
                }
            }
        }
    }

    private func condition() {
        if atKeyword("let") || atKeyword("var") {
            node(K.optionalBinding) {
                bump()
                withFlags(pattern: true, binding: true) { _ = unary() }
                if b.at(":") { typeAnnotation() }
                if eat("=") { expression() }
            }
        } else if atKeyword("case") {
            node(K.caseCondition) {
                bump()
                withFlags(pattern: true) { expression(stopAtAssignment: true) }
                if expect("=") { expression() }
            }
        } else {
            expression()
        }
    }

    private func switchStatement() {
        node(K.switchStmt) {
            bump()
            withFlags(braces: false) { expression() }
            guard expect("{") else { return }
            withFlags(braces: true, pattern: false, binding: false) {
                while let token = cur, !isCloser(token) {
                    if switchCaseAhead() {
                        switchCase()
                    } else {
                        statementInList()
                    }
                }
            }
            expect("}")
        }
    }

    /// `case`, `default`, or `@unknown` before either.
    private func switchCaseAhead() -> Bool {
        if atKeyword("case") || atKeyword("default") { return true }
        guard let token = cur, token.scope == "entity.other.attribute" else { return false }
        return isKeyword(b.peek(1), "case") || isKeyword(b.peek(1), "default")
    }

    private func switchCase() {
        node(K.switchCase) {
            if cur?.scope == "entity.other.attribute" { attribute() }
            if atKeyword("default") {
                bump()
            } else {
                bump()
                casePatterns()
            }
            expect(":")
            statements(inSwitchCase: true)
        }
    }

    /// Patterns separated by commas, each with an optional `where`, up to `:` or `{`.
    private func casePatterns() {
        while cur != nil, !b.at(":"), !b.at("{") {
            let before = cur!.location
            node(K.casePattern) {
                withFlags(braces: false, pattern: true) { expression() }
                if atKeyword("where") {
                    node(K.whereClause) {
                        bump()
                        withFlags(braces: false) { expression() }
                    }
                }
            }
            if eat(",") { continue }
            if cur?.location == before, let stuck = cur, !isCloser(stuck) {
                errorAndBump("unexpected `\(text(stuck))` in a pattern")
                continue
            }
            break
        }
    }

    private func doStatement() {
        node(K.doStmt) {
            bump()
            if atKeyword("throws") { effects() }
            codeBlock()
            while atKeyword("catch") {
                node(K.catchClause) {
                    bump()
                    if !b.at("{") { casePatterns() }
                    codeBlock()
                }
            }
        }
    }

    // MARK: Declarations

    private static let declarationKeywords: Set<String> = [
        "let", "var", "func", "init", "deinit", "subscript", "class", "struct", "enum", "protocol", "extension",
        "typealias", "associatedtype", "import", "operator", "precedencegroup", "case", "actor", "macro"
    ]

    private static let modifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "package", "static", "class", "final", "override",
        "mutating", "nonmutating", "lazy", "weak", "unowned", "convenience", "required", "dynamic", "indirect",
        "nonisolated", "isolated", "optional", "prefix", "postfix", "infix", "async", "consuming", "borrowing",
        "distributed", "__consuming", "rethrows"
    ]

    /// Whether the token at `offset` is a declaration keyword that starts a declaration there.
    private func declarationKeywordAt(_ offset: Int) -> Bool {
        guard let token = b.peek(offset), token.kind == .lexeme, token.scope == "keyword" else { return false }
        let value = text(token)
        guard Self.declarationKeywords.contains(value) else { return false }
        if value == "actor" || value == "macro" { return isName(b.peek(offset + 1)) }
        return true
    }

    /// Whether the token at `offset` is a modifier of a declaration that follows.
    private func modifierAt(_ offset: Int) -> Bool {
        guard let token = b.peek(offset), token.kind == .word || (token.kind == .lexeme && token.scope == "keyword"),
              Self.modifiers.contains(text(token)) else { return false }
        var next = offset + 1
        // `private(set)`, `unowned(unsafe)`, `nonisolated(unsafe)`.
        if isSymbol(b.peek(next), "("), adjacent(token, b.peek(next)), isSymbol(b.peek(next + 2), ")") { next += 3 }
        guard let following = b.peek(next) else { return false }
        if following.scope == "entity.other.attribute" { return true }
        if declarationKeywordAt(next) {
            // `class` alone names a class; `class func` is a modifier.
            return true
        }
        return next - offset < 8 && modifierAt(next)
    }

    private func declarationAhead() -> Bool {
        guard let token = cur else { return false }
        if token.scope == "entity.other.attribute" { return true }
        if declarationKeywordAt(0) {
            // `case` starts an enum case here; in a switch the case loop sees it first.
            return true
        }
        return modifierAt(0)
    }

    /// Attributes, modifiers, then the declaration they belong to, all in one node.
    private func declaration() {
        let start = b.checkpoint()
        while let token = cur {
            if token.scope == "entity.other.attribute" {
                attribute()
            } else if modifierAt(0) && (!declarationKeywordAt(0) || atKeyword("class") && (declarationKeywordAt(1) || modifierAt(1))) {
                modifier()
            } else {
                break
            }
        }
        guard let token = cur, declarationKeywordAt(0) else {
            b.error("expected a declaration")
            return
        }
        switch text(token) {
        case "let", "var": b.startNode(K.varDecl, at: start); variableDeclaration()
        case "func": b.startNode(K.funcDecl, at: start); functionDeclaration()
        case "init": b.startNode(K.initDecl, at: start); initDeclaration()
        case "deinit":
            b.startNode(K.deinitDecl, at: start)
            bump()
            if b.at("{") { codeBlock() }
        case "subscript": b.startNode(K.subscriptDecl, at: start); subscriptDeclaration()
        case "class": b.startNode(K.classDecl, at: start); typeDeclaration()
        case "struct": b.startNode(K.structDecl, at: start); typeDeclaration()
        case "enum": b.startNode(K.enumDecl, at: start); typeDeclaration()
        case "protocol": b.startNode(K.protocolDecl, at: start); typeDeclaration()
        case "actor": b.startNode(K.actorDecl, at: start); typeDeclaration()
        case "extension": b.startNode(K.extensionDecl, at: start); extensionDeclaration()
        case "typealias": b.startNode(K.typealiasDecl, at: start); typealiasDeclaration()
        case "associatedtype": b.startNode(K.associatedtypeDecl, at: start); associatedtypeDeclaration()
        case "import": b.startNode(K.importDecl, at: start); importDeclaration()
        case "operator": b.startNode(K.operatorDecl, at: start); operatorDeclaration()
        case "precedencegroup": b.startNode(K.precedenceGroupDecl, at: start); precedenceGroupDeclaration()
        case "case": b.startNode(K.enumCaseDecl, at: start); enumCaseDeclaration()
        default: b.startNode(K.macroDecl, at: start); macroDeclaration()
        }
        b.finishNode()
    }

    private func modifier() {
        bump()
        if b.at("("), isSymbol(b.peek(2), ")") {
            bump()
            bump()
            bump()
        }
    }

    /// `@name`, `@Module.Name<T>`, and its arguments when a `(` follows with no space.
    private func attribute() {
        node(K.attribute) {
            let at = cur
            bump()
            var previous = at
            while isSymbol(cur, "."), adjacent(previous, cur), isName(b.peek(1)) {
                bump()
                previous = cur
                bump()
            }
            if b.at("<"), adjacent(previous, cur) { genericArguments() }
            if b.at("("), let open = cur, lastEnd == open.location { attributeArguments() }
        }
    }

    /// `(…)` after an attribute. Its contents vary by attribute, so they are read loosely: labels
    /// (`message:`) are marked, nested brackets kept whole, and everything else stays as it lexed.
    private func attributeArguments() {
        node(K.attributeArguments) {
            bump()
            var depth = 0
            while let token = cur {
                if isCloser(token) {
                    if depth == 0 { break }
                    depth -= 1
                    bump()
                    continue
                }
                if isLabel(token), isSymbol(b.peek(1), ":") {
                    node(K.argumentLabel) { bump() }
                    bump()
                    continue
                }
                if token.scope == "string.quoted" {
                    stringLiteral()
                    continue
                }
                let value = text(token)
                if value == "(" || value == "[" || value == "{" { depth += 1 }
                bump()
            }
            expect(")")
        }
    }

    private func variableDeclaration() {
        bump()
        repeat {
            let before = cur?.location
            node(K.patternBinding) {
                withFlags(braces: false, pattern: true, binding: true) { _ = unary() }
                if b.at(":") { typeAnnotation() }
                if eat("=") { withFlags(observers: true) { expression() } }
                if b.at("{") { accessorBlock() }
            }
            if cur?.location == before { break }
        } while eat(",")
    }

    private func typeAnnotation() {
        node(K.typeAnnotation) {
            bump()
            type()
        }
    }

    private func functionDeclaration() {
        bump()
        if atName() {
            name(K.functionName)
        } else if let token = cur, isOperatorCharacter(token) || token.scope == "string.regexp" {
            node(K.functionName) { operatorName() }
        } else {
            b.error("expected a function name")
        }
        if b.at("<") { genericParameters() }
        functionSignature()
        if atKeyword("where") { whereClause() }
        if b.at("{") { codeBlock() }
    }

    /// An operator's name: adjacent operator characters. A `/` in it the lexer took for a regex
    /// opener is re-lexed as an operator character.
    private func operatorName() {
        var previous: SyntaxToken?
        while let token = cur, previous == nil || adjacent(previous, token) {
            if token.scope == "string.regexp", text(token).hasPrefix("/") {
                b.relex(as: "operatorSlash")
                guard let relexed = cur else { break }
                previous = relexed
                bump()
                continue
            }
            guard isOperatorCharacter(token) else { break }
            previous = token
            bump()
        }
    }

    /// Parameters, effects and the result type.
    private func functionSignature() {
        parameterClause()
        if atKeyword("async") || atKeyword("throws") || atKeyword("rethrows") || b.at("reasync") { effects() }
        if b.at("->") {
            node(K.returnClause) {
                eat("->")
                type()
            }
        }
    }

    private func effects() {
        node(K.effects) {
            while let token = cur, atKeyword("async") || atKeyword("throws") || atKeyword("rethrows") || text(token) == "reasync" {
                bump()
                // Typed throws: `throws(MyError)`.
                if b.at("("), let open = cur, lastEnd == open.location {
                    bump()
                    type()
                    expect(")")
                }
            }
        }
    }

    private func parameterClause() {
        guard b.at("(") else {
            b.error("expected `(`")
            return
        }
        node(K.parameterClause) {
            bump()
            commaList(until: ")", stops: ["{", "->"]) { parameter() }
            expect(")")
        }
    }

    /// `label name: Type = default`, with the label, the type and the default optional.
    private func parameter() {
        node(K.parameter) {
            while cur?.scope == "entity.other.attribute" { attribute() }
            if isLabel(cur), isLabel(b.peek(1)), !isSymbol(b.peek(1), ":") {
                name(K.parameterLabel)
                name(K.parameterName)
            } else if isLabel(cur) || backtickAhead() {
                name(K.parameterName)
            }
            if b.at(":") { typeAnnotation() }
            eat("...")
            if eat("=") { expression() }
        }
    }

    private func initDeclaration() {
        bump()
        if let token = cur, lastEnd == token.location, b.at("?") || b.at("!") { bump() }
        if b.at("<") { genericParameters() }
        functionSignature()
        if atKeyword("where") { whereClause() }
        if b.at("{") { codeBlock() }
    }

    private func subscriptDeclaration() {
        bump()
        if b.at("<") { genericParameters() }
        functionSignature()
        if atKeyword("where") { whereClause() }
        if b.at("{") { accessorBlock() }
    }

    private func typeDeclaration() {
        bump()
        if atName() { name(K.typeName) } else { b.error("expected a type name") }
        if b.at("<") { genericParameters() }
        if b.at(":") { inheritance() }
        if atKeyword("where") { whereClause() }
        memberBlock()
    }

    private func extensionDeclaration() {
        bump()
        type()
        if b.at(":") { inheritance() }
        if atKeyword("where") { whereClause() }
        memberBlock()
    }

    private func memberBlock() {
        guard b.at("{") else {
            b.error("expected `{`")
            return
        }
        braceBlock(K.memberBlock)
    }

    private func typealiasDeclaration() {
        bump()
        if atName() { name(K.typeName) } else { b.error("expected a type name") }
        if b.at("<") { genericParameters() }
        if expect("=") { type() }
        if atKeyword("where") { whereClause() }
    }

    private func associatedtypeDeclaration() {
        bump()
        if atName() { name(K.typeName) } else { b.error("expected a type name") }
        if b.at(":") { inheritance() }
        if eat("=") { type() }
        if atKeyword("where") { whereClause() }
    }

    private func importDeclaration() {
        bump()
        if let token = cur, isKeyword(token), ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"].contains(text(token)) {
            bump()
        }
        while let token = cur, !lineBreakBefore(token), isName(token) || backtickAhead() {
            bumpName()
            guard isSymbol(cur, ".") else { break }
            bump()
        }
    }

    private func operatorDeclaration() {
        bump()
        node(K.functionName) { operatorName() }
        if eat(":") {
            while atName() {
                bumpName()
                guard eat(",") else { break }
            }
        }
    }

    private func precedenceGroupDeclaration() {
        bump()
        if atName() { name(K.typeName) } else { b.error("expected a precedence group name") }
        guard b.at("{") else {
            b.error("expected `{`")
            return
        }
        node(K.precedenceGroupBody) {
            bump()
            while let token = cur, !isCloser(token) { bump() }
            expect("}")
        }
    }

    private func enumCaseDeclaration() {
        bump()
        repeat {
            guard atName() else {
                b.error("expected a case name")
                break
            }
            node(K.enumCaseElement) {
                name(K.enumCaseName)
                if b.at("(") { tupleType() }
                if eat("=") { expression() }
            }
        } while eat(",")
    }

    private func macroDeclaration() {
        bump()
        name(K.functionName)
        if b.at("<") { genericParameters() }
        functionSignature()
        if eat("=") { expression() }
        if atKeyword("where") { whereClause() }
    }

    private func genericParameters() {
        node(K.genericParameters) {
            bump()
            commaList(until: ">") {
                node(K.genericParameter) {
                    if b.at("each") || atKeyword("let") { bump() }
                    if atName() { name(K.typeName) } else { b.error("expected a generic parameter name") }
                    if eat(":") { type() }
                }
            }
            expect(">")
        }
    }

    private func whereClause() {
        node(K.whereClause) {
            bump()
            repeat {
                guard type() else { break }
                if eat(":") || eat("==") { type() }
            } while eat(",")
        }
    }

    private func inheritance() {
        node(K.inheritance) {
            bump()
            repeat {
                if atKeyword("class") { bump() } else { type() }
            } while eat(",")
        }
    }

    // MARK: Accessors

    private static let accessorKeywords: Set<String> = [
        "get", "set", "willSet", "didSet", "_read", "_modify", "read", "modify", "unsafeAddress", "unsafeMutableAddress", "init"
    ]

    /// Whether the `{` at the cursor holds accessors rather than a getter's statements.
    private func accessorsAhead() -> Bool {
        var offset = 1
        while let token = b.peek(offset), offset < 16 {
            if token.scope == "entity.other.attribute" || ["mutating", "nonmutating", "__consuming", "borrowing", "consuming"].contains(text(token)) {
                offset += 1
                continue
            }
            return (token.kind == .word || isKeyword(token)) && Self.accessorKeywords.contains(text(token))
                && (text(token) != "init" || !isSymbol(b.peek(offset + 1), "("))
        }
        return false
    }

    private func accessorBlock() {
        node(K.accessorBlock) {
            let accessors = accessorsAhead()
            bump()
            withFlags(braces: true, pattern: false, binding: false) {
                if accessors {
                    while let token = cur, !isCloser(token) {
                        let before = token.location
                        accessor()
                        if cur?.location == before, let stuck = cur, !isCloser(stuck) { errorAndBump("expected an accessor") }
                    }
                } else {
                    statements()
                }
            }
            expect("}")
        }
    }

    private func accessor() {
        node(K.accessor) {
            while let token = cur, token.scope == "entity.other.attribute" || ["mutating", "nonmutating", "__consuming", "borrowing", "consuming"].contains(text(token)) {
                if token.scope == "entity.other.attribute" { attribute() } else { bump() }
            }
            guard let token = cur, Self.accessorKeywords.contains(text(token)), !isCloser(token) else { return }
            bump()
            if b.at("(") {
                node(K.parameterClause) {
                    bump()
                    if atName() { node(K.parameter) { name(K.parameterName) } }
                    expect(")")
                }
            }
            if atKeyword("async") || atKeyword("throws") { effects() }
            if b.at("{") { codeBlock() }
        }
    }

    // MARK: Expressions

    /// A whole expression: operands joined by binary operators, by precedence.
    /// - Parameter stopAtAssignment: leaves an `=` for the caller (`if case .x = y`).
    private func expression(stopAtAssignment: Bool = false) {
        _ = sequence(0, stopAtAssignment: stopAtAssignment || patternMode)
    }

    /// Precedence climbing: an operand, then each operator binding at least as tightly as `minimum`
    /// wraps everything before it.
    @discardableResult
    private func sequence(_ minimum: Int, stopAtAssignment: Bool) -> Bool {
        let start = b.checkpoint()
        guard unary() else { return false }
        while let token = cur {
            if isKeyword(token, "as") || isKeyword(token, "is") {
                guard Self.castPrecedence >= minimum else { break }
                b.startNode(K.castExpr, at: start)
                bump()
                if let mark = cur, lastEnd == mark.location, b.at("?") || b.at("!") { bump() }
                type()
                b.finishNode()
                continue
            }
            guard let op = binaryOperator(stopAtAssignment: stopAtAssignment) else { break }
            if op.text == "?" {
                guard Self.ternaryPrecedence >= minimum else { break }
                b.startNode(K.ternaryExpr, at: start)
                bump()
                withFlags(pattern: false, binding: false) { expression() }
                if expect(":") { sequence(Self.ternaryPrecedence, stopAtAssignment: stopAtAssignment) }
                b.finishNode()
                continue
            }
            let (precedence, associativity) = Self.precedence[op.text] ?? (Self.defaultPrecedence, .left)
            guard precedence >= minimum else { break }
            b.startNode(K.binaryExpr, at: start)
            bumpTokens(op.count)
            if !sequence(associativity == .right ? precedence : precedence + 1, stopAtAssignment: stopAtAssignment) {
                b.error("expected an expression after `\(op.text)`")
            }
            b.finishNode()
        }
        return true
    }

    /// The binary operator at the cursor, if one continues the expression. An operator with space
    /// on one side only is prefix or postfix; a prefix one at the start of a line starts the next
    /// statement.
    private func binaryOperator(stopAtAssignment: Bool) -> (text: String, count: Int)? {
        guard let first = cur, let op = operatorAhead() else { return nil }
        if op.text == "." || op.text == "->" { return nil }
        if stopAtAssignment && op.text == "=" { return nil }
        let leftBound = lastEnd == first.location
        let after = b.peek(op.count)
        let last = b.peek(op.count - 1)
        let rightBound = adjacent(last, after) && !(after.map(isCloser) ?? true)
            && !isSymbol(after, ",") && !isSymbol(after, ";") && !isSymbol(after, ":")
        if op.text == "?" { return leftBound ? nil : (op.text, 1) }
        if leftBound && !rightBound { return nil }
        if !leftBound && rightBound && lineBreakBefore(first) { return nil }
        return op
    }

    /// A prefix expression: `try`, `await`, prefix operators, then a postfix expression.
    @discardableResult
    private func unary() -> Bool {
        guard let token = cur else { return false }
        if tooDeep() { return true }
        if token.kind == .lexeme && token.scope == "keyword" {
            switch text(token) {
            case "try":
                node(K.tryExpr) {
                    bump()
                    if let mark = cur, lastEnd == mark.location, b.at("?") || b.at("!") { bump() }
                    if !unary() { b.error("expected an expression after `try`") }
                }
                return true
            case "await":
                node(K.awaitExpr) {
                    bump()
                    if !unary() { b.error("expected an expression after `await`") }
                }
                return true
            case "consume", "borrowing", "consuming":
                if let next = b.peek(1), isName(next) || next.scope == "variable.language", !lineBreakBeforeNext(token, next) {
                    node(K.prefixExpr) {
                        bump()
                        _ = unary()
                    }
                    return true
                }
            case "let" where patternMode, "var" where patternMode:
                node(K.valueBindingPattern) {
                    bump()
                    withFlags(binding: true) { _ = unary() }
                }
                return true
            case "is" where patternMode:
                node(K.isPattern) {
                    bump()
                    type()
                }
                return true
            default: break
            }
        }
        if isOperatorCharacter(token), !(isSymbol(token, ".") && !b.at("..")), let op = operatorAhead() {
            // A bare operator passed as a function: `reduce(0, +)`.
            if let after = b.peek(op.count), isCloser(after) || isSymbol(after, ",") {
                node(K.operatorReference) { bumpTokens(op.count) }
                return true
            }
            node(K.prefixExpr) {
                bumpTokens(op.count)
                if !unary() { b.error("expected an expression after `\(op.text)`") }
            }
            return true
        }
        let start = b.checkpoint()
        guard primary() else { return false }
        postfix(start)
        return true
    }

    private func lineBreakBeforeNext(_ token: SyntaxToken, _ next: SyntaxToken) -> Bool {
        let gap = b.text(of: SyntaxToken(kind: .space, location: token.end, length: max(1, next.location - token.end)))
        return next.location > token.end && (gap.utf16.contains(10) || gap.utf16.contains(13))
    }

    /// An operand: a name, literal, bracketed expression, closure, key path or macro.
    private func primary() -> Bool {
        guard let token = cur else { return false }
        switch token.kind {
        case .word:
            identifier()
            return true
        case .symbol:
            switch text(token) {
            case "(":
                tuple()
                return true
            case "[":
                collection()
                return true
            case "{":
                guard bracesAllowed else { return false }
                closure()
                return true
            case "\\":
                keyPath()
                return true
            case ".":
                guard isName(b.peek(1)) || isKeyword(b.peek(1)) || backtickAhead(1) else { return false }
                node(K.implicitMember) {
                    bump()
                    bumpName()
                }
                genericArgumentsIfAhead()
                return true
            case "`":
                guard backtickAhead() else { return false }
                identifier()
                return true
            default:
                return false
            }
        case .lexeme:
            switch token.scope {
            case "string.quoted":
                stringLiteral()
                return true
            case "string.regexp":
                regexLiteral()
                return true
            case "constant.numeric", "constant.language":
                bump()
                return true
            case "variable.language", "entity.name.type", "entity.name.function":
                identifier()
                return true
            case "meta.preprocessor":
                macroExpansion()
                return true
            case "keyword":
                switch text(token) {
                case "if":
                    ifStatement()
                    return true
                case "switch":
                    switchStatement()
                    return true
                case "init":
                    identifier()
                    return true
                default:
                    guard Self.contextual.contains(text(token)) else { return false }
                    identifier()
                    return true
                }
            default:
                return false
            }
        default:
            return false
        }
    }

    /// A name used as a value, or, under `let` in a pattern, the name it declares.
    private func identifier() {
        if binding, atName(), cur?.scope != "variable.language", !isSymbol(b.peek(1), "."), !isSymbol(b.peek(1), "(") {
            if curText == "_" {
                node(K.wildcard) { bump() }
            } else {
                node(K.identifierPattern) { bumpName() }
            }
            return
        }
        node(K.identifier) {
            bumpName()
            genericArgumentsIfAhead()
        }
    }

    /// `<…>` right after a name, when what follows reads as generic arguments, not a comparison.
    private func genericArgumentsIfAhead() {
        guard let open = cur, lastEnd == open.location, isSymbol(open, "<"), genericArgumentsAhead() else { return }
        genericArguments()
    }

    /// Looks ahead from a `<` for a matching `>` with only type-like tokens between, followed by
    /// something that can follow a type reference: `Array<Int>(…)`, `Foo<T>.bar`.
    private func genericArgumentsAhead() -> Bool {
        var depth = 0
        var offset = 0
        while offset < 64, let token = b.peek(offset) {
            if token.kind == .symbol {
                switch text(token) {
                case "<": depth += 1
                case ">":
                    // `->` inside a function type.
                    if offset > 0, let previous = b.peek(offset - 1), isSymbol(previous, "-"), adjacent(previous, token) { break }
                    depth -= 1
                    if depth == 0 {
                        guard let next = b.peek(offset + 1) else { return true }
                        if isSymbol(next, "="), adjacent(token, next) { return false }
                        if next.kind == .symbol {
                            return ["(", ")", "[", "]", "}", ".", ",", ";", ":", "?", "!", "=", "{"].contains(text(next))
                                || lineBreakBeforeNext(token, next)
                        }
                        return lineBreakBeforeNext(token, next) || isKeyword(next, "where") || isKeyword(next, "in")
                    }
                case ".", ",", "[", "]", "(", ")", "?", "!", ":", "&", "-", "_", "~": break
                default: return false
                }
            } else if token.kind == .lexeme {
                switch token.scope {
                case "entity.name.type", "variable.language", "constant.numeric": break
                case "keyword":
                    guard ["any", "some", "inout", "async", "throws", "each", "repeat"].contains(text(token)) else { return false }
                default: return false
                }
            } else if token.kind != .word {
                return false
            }
            offset += 1
        }
        return false
    }

    private func postfix(_ start: TreeBuilder.Checkpoint) {
        while let token = cur {
            if isSymbol(token, "."), !b.at("..") {
                guard let next = b.peek(1) else { break }
                b.startNode(K.memberExpr, at: start)
                bump()
                if next.scope == "constant.numeric" {
                    // A tuple index; `t.0.1` lexed `0.1` as one number.
                    if text(next).contains("."), adjacent(token, next) { b.relex(as: "tupleIndex") }
                    node(K.memberName) { bump() }
                } else if isName(next) || isKeyword(next) || next.scope == "variable.language" || backtickAhead(1) {
                    node(K.memberName) { bumpName() }
                    genericArgumentsIfAhead()
                } else {
                    b.error("expected a member name")
                }
                b.finishNode()
                continue
            }
            if token.kind == .symbol, !lineBreakBefore(token) {
                let value = text(token)
                if value == "(" {
                    b.startNode(K.callExpr, at: start)
                    argumentList(")")
                    trailingClosures()
                    b.finishNode()
                    continue
                }
                if value == "[" {
                    b.startNode(K.subscriptExpr, at: start)
                    argumentList("]")
                    trailingClosures()
                    b.finishNode()
                    continue
                }
                if value == "{" {
                    guard trailingClosureAhead() else { break }
                    b.startNode(K.callExpr, at: start)
                    trailingClosures()
                    b.finishNode()
                    continue
                }
            }
            // `x!/2`: after a postfix `!` or `?`, the lexer took `/` for a regex opener.
            if token.scope == "string.regexp", lastEnd == token.location, text(token).hasPrefix("/") {
                if b.relex(as: "operatorSlash") { break }
            }
            guard lastEnd == token.location, let op = operatorAhead(), !(op.text == "." ) else { break }
            let after = b.peek(op.count)
            let last = b.peek(op.count - 1)
            let rightBound = adjacent(last, after) && !(after.map(isCloser) ?? true) && !isSymbol(after, ",")
                && !isSymbol(after, ";") && !isSymbol(after, ":") && !isSymbol(after, ".")
            if op.text == "?" || op.text == "!" {
                b.startNode(K.postfixExpr, at: start)
                bump()
                b.finishNode()
                continue
            }
            // A postfix operator: `x...`, `x++` with space or a closer after it.
            guard !rightBound else { break }
            b.startNode(K.postfixExpr, at: start)
            bumpTokens(op.count)
            b.finishNode()
        }
    }

    private func trailingClosureAhead() -> Bool {
        guard bracesAllowed, let open = cur, isSymbol(open, "{"), !lineBreakBefore(open) else { return false }
        // `var x = 1 { didSet { … } }`: the braces are observers.
        if observersMayFollow, let first = b.peek(1), text(first) == "willSet" || text(first) == "didSet" { return false }
        return true
    }

    /// A closure after a call, then labelled ones: `} label: {`.
    private func trailingClosures() {
        guard trailingClosureAhead() else { return }
        closure()
        while let label = cur, isLabel(label), isSymbol(b.peek(1), ":"), isSymbol(b.peek(2), "{") {
            guard !isKeyword(label, "case"), !isKeyword(label, "default") else { break }
            node(K.argument) {
                node(K.argumentLabel) { bump() }
                bump()
                closure()
            }
        }
    }

    /// `(a, label: b)` or `[i]`: arguments up to `closer`.
    private func argumentList(_ closer: String) {
        bump()
        withFlags(braces: true, pattern: patternMode, binding: binding) {
            commaList(until: closer) { argument() }
        }
        expect(closer)
    }

    private func argument() {
        node(K.argument) {
            if isLabel(cur), isSymbol(b.peek(1), ":"), let label = cur, !(label.scope == "string.quoted") {
                node(K.argumentLabel) { bump() }
                bump()
                if let next = cur, isCloser(next) || isSymbol(next, ",") { return }
            }
            withFlags(pattern: patternMode, binding: binding) {
                if !sequence(0, stopAtAssignment: patternMode) { b.error("expected an expression") }
            }
        }
    }

    /// `element, element, …` until `closer`, recovering at a token that doesn't fit. A keyword that
    /// only starts a statement ends the list too, so a list left unclosed while typing doesn't
    /// swallow the declarations after it. So does any of `stops`.
    private func commaList(until closer: String, stops: Set<String> = [], _ element: () -> Void) {
        while let token = cur {
            if b.at(closer) || isCloser(token) || atListStop(token) || stops.contains(where: { b.at($0) }) { break }
            let before = token.location
            element()
            if eat(",") { continue }
            guard let next = cur, !b.at(closer), !isCloser(next), !atListStop(next) else { break }
            if next.location == before {
                errorAndBump("unexpected `\(text(next))`")
            } else {
                recover("expected `,` or `\(closer)`", until: Self.listStops.union(stops).union([",", closer]))
                eat(",")
            }
        }
    }

    /// Keywords that start a statement or declaration and can't appear inside a list.
    private static let listStops: Set<String> = [
        "func", "class", "struct", "enum", "protocol", "extension", "import", "return", "guard", "while", "for",
        "case", "default", "typealias", "deinit", "subscript", "defer", "do", "repeat", "break", "continue",
        "throw", "fallthrough", "catch", "else", "let", "var"
    ]

    private func atListStop(_ token: SyntaxToken) -> Bool {
        guard isKeyword(token) else { return false }
        let value = text(token)
        // `case .some(let x, var y)`: bindings inside a pattern's list.
        if patternMode && (value == "let" || value == "var") { return false }
        guard Self.listStops.contains(value), token == cur else { return false }
        // A keyword as a label: `for: x`, `for item: String`.
        return !isSymbol(b.peek(1), ":") && !(isLabel(b.peek(1)) && isSymbol(b.peek(2), ":"))
    }

    /// `(…)`: a parenthesized expression or a tuple.
    private func tuple() {
        node(K.tupleExpr) { argumentList(")") }
    }

    /// `[a, b]`, `[k: v]` or `[:]`.
    private func collection() {
        if isSymbol(b.peek(1), ":"), isSymbol(b.peek(2), "]") {
            node(K.dictionaryLiteral) { bumpTokens(3) }
            return
        }
        let dictionary = colonAhead()
        node(dictionary ? K.dictionaryLiteral : K.arrayLiteral) {
            bump()
            withFlags(braces: true, pattern: false, binding: false) {
                commaList(until: "]") {
                    guard dictionary else {
                        if !sequence(0, stopAtAssignment: false) { b.error("expected an element") }
                        return
                    }
                    node(K.dictionaryElement) {
                        if !sequence(0, stopAtAssignment: false) { b.error("expected a key") }
                        if expect(":") && !sequence(0, stopAtAssignment: false) { b.error("expected a value") }
                    }
                }
            }
            expect("]")
        }
    }

    /// At a `[`: whether a `:` comes before the first `,` or `]` at its own level, so it opens a
    /// dictionary. A ternary's `:` doesn't count. Looks a bounded way ahead.
    private func colonAhead() -> Bool {
        var depth = 0
        var offset = 1
        var ternary = 0
        while offset < 64, let token = b.peek(offset) {
            if token.kind == .symbol {
                switch text(token) {
                case "(", "[", "{": depth += 1
                case ")", "]", "}":
                    if depth == 0 { return false }
                    depth -= 1
                case ",": if depth == 0 { return false }
                case "?": if depth == 0, let previous = b.peek(offset - 1), !adjacent(previous, token) { ternary += 1 }
                case ":":
                    if depth == 0 {
                        if ternary == 0 { return true }
                        ternary -= 1
                    }
                default: break
                }
            }
            offset += 1
        }
        return false
    }

    /// `{ [captures] params in statements }`.
    func closure() {
        node(K.closure) {
            let signature = closureSignatureAhead()
            bump()
            withFlags(braces: true, pattern: false, binding: false) {
                if signature { closureSignature() }
                statements()
            }
            expect("}")
        }
    }

    /// Whether a closure's `in` comes before its first statement. Called at the `{`.
    private func closureSignatureAhead() -> Bool {
        var depth = 0
        var offset = 1
        while offset < 96, let token = b.peek(offset) {
            switch token.kind {
            case .symbol:
                switch text(token) {
                case "(", "[": depth += 1
                case ")", "]":
                    depth -= 1
                    if depth < 0 { return false }
                case "{", "}", ";": return false
                default: break
                }
            case .lexeme:
                switch token.scope {
                case "keyword":
                    let value = text(token)
                    if value == "in" { return depth == 0 }
                    guard ["async", "throws", "rethrows", "weak", "unowned", "some", "any", "inout", "borrowing",
                           "consuming", "isolated", "nonisolated", "let", "var"].contains(value) else { return false }
                case "entity.name.type", "entity.name.function", "variable.language", "constant.language",
                     "constant.numeric", "entity.other.attribute", "string.quoted": break
                default: return false
                }
            default: break
            }
            offset += 1
        }
        return false
    }

    private func closureSignature() {
        node(K.closureSignature) {
            while cur?.scope == "entity.other.attribute" { attribute() }
            if b.at("[") { captureList() }
            if b.at("(") {
                parameterClause()
            } else {
                while atName() || curText == "_" {
                    node(K.closureParameter) { name(K.parameterName) }
                    guard eat(",") else { break }
                }
            }
            if atKeyword("async") || atKeyword("throws") || atKeyword("rethrows") { effects() }
            if b.at("->") {
                node(K.returnClause) {
                    eat("->")
                    type()
                }
            }
            if atKeyword("in") { bump() } else { recover("expected `in`", until: ["in"]); if atKeyword("in") { bump() } }
        }
    }

    private func captureList() {
        node(K.captureList) {
            bump()
            commaList(until: "]") {
                node(K.captureItem) {
                    if atKeyword("weak") || atKeyword("unowned") { modifier() }
                    if cur?.scope == "variable.language" {
                        bump()
                    } else if atName() {
                        node(K.identifierPattern) { bumpName() }
                    } else {
                        b.error("expected a capture")
                    }
                    if eat("=") { expression() }
                }
            }
            expect("]")
        }
    }

    /// A string literal: its pieces, escapes and interpolations. The lexer gives each piece its
    /// own token; they are adjacent, or, in a multi-line string, separated only by line breaks.
    private func stringLiteral() {
        guard let first = cur else { return }
        let opener = text(first)
        let hashes = opener.prefix { $0 == "#" }.count
        let afterHashes = opener.dropFirst(hashes)
        let multiline = afterHashes.hasPrefix("\"\"\"")
        let closer = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
        node(K.stringLiteral) {
            bump()
            var closed = !multiline || (opener.count >= 2 * closer.count && opener.hasSuffix(closer))
            if !multiline { closed = opener.count > 1 + hashes && opener.hasSuffix(closer) }
            while !closed, let token = cur, token.kind == .lexeme {
                let joined = lastEnd == token.location || (multiline && onlyLineBreaks(before: token))
                guard joined else { break }
                switch token.scope {
                case "string.quoted":
                    bump()
                    if text(token).hasSuffix(closer) { closed = true }
                case "constant.character.escape", "invalid":
                    bump()
                case "punctuation.section.embedded":
                    guard text(token) == "\\" else { return }
                    interpolation()
                default:
                    return
                }
            }
        }
    }

    private func onlyLineBreaks(before token: SyntaxToken) -> Bool {
        guard lastEnd >= 0, token.location > lastEnd else { return false }
        let gap = b.text(of: SyntaxToken(kind: .space, location: lastEnd, length: token.location - lastEnd))
        return gap.utf16.allSatisfy { $0 == 10 || $0 == 13 }
    }

    /// `\(expression)` in a string, or `\#(…)` in a raw one: the expressions are ordinary code.
    private func interpolation() {
        node(K.interpolation) {
            bump()
            while let token = cur, token.scope == "punctuation.section.embedded", text(token) == "#" { bump() }
            guard let open = cur, open.scope == "punctuation.section.embedded", text(open) == "(" else {
                b.error("expected `(`")
                return
            }
            bump()
            withFlags(braces: true, pattern: false, binding: false) {
                commaList(until: ")") { argument() }
            }
            if let close = cur, close.scope == "punctuation.section.embedded", text(close) == ")" {
                bump()
            } else {
                b.error("expected `)` to end the interpolation")
            }
        }
    }

    /// `/regex/` or `#/regex/#`, possibly over several lines.
    private func regexLiteral() {
        guard let first = cur else { return }
        let extended = text(first).hasPrefix("#")
        node(K.regexLiteral) {
            bump()
            while let token = cur, token.scope == "string.regexp",
                  lastEnd == token.location || (extended && onlyLineBreaks(before: token)) {
                bump()
            }
        }
    }

    /// `\Root.path?.to[0]` or `\.path`.
    private func keyPath() {
        node(K.keyPath) {
            bump()
            if let token = cur, lastEnd == token.location, isName(token) {
                node(K.typeIdentifier) {
                    bumpName()
                    if b.at("<"), lastEnd == cur!.location { genericArguments() }
                }
            }
            while let token = cur, lastEnd == token.location {
                if isSymbol(token, "."), let next = b.peek(1), adjacent(token, next) {
                    bump()
                    if isName(next) || isKeyword(next) || next.scope == "variable.language" || next.scope == "constant.numeric" {
                        node(K.memberName) { bumpName() }
                    }
                } else if isSymbol(token, "?") || isSymbol(token, "!") {
                    bump()
                } else if isSymbol(token, "[") {
                    node(K.subscriptExpr) { argumentList("]") }
                } else {
                    break
                }
            }
        }
    }

    /// `#name`, `#name<T>(arguments) { trailing }`.
    private func macroExpansion() {
        node(K.macroExpansion) {
            let loose = ["#available", "#unavailable"].contains(curText ?? "")
            bump()
            if loose, let open = cur, isSymbol(open, "("), lastEnd == open.location {
                attributeArguments()
                return
            }
            if let open = cur, lastEnd == open.location, isSymbol(open, "<"), genericArgumentsAhead() { genericArguments() }
            if let open = cur, isSymbol(open, "("), !lineBreakBefore(open) { argumentList(")") }
            trailingClosures()
        }
    }

    // MARK: Types

    private static let typeSpecifiers: Set<String> = [
        "inout", "borrowing", "consuming", "__owned", "__shared", "sending", "isolated", "each", "repeat", "__isolated"
    ]

    /// A type. Returns whether one was there.
    @discardableResult
    private func type() -> Bool {
        guard let token = cur else {
            b.error("expected a type")
            return false
        }
        if tooDeep() { return true }
        let start = b.checkpoint()
        if token.scope == "entity.other.attribute" || Self.typeSpecifiers.contains(text(token)) && (isKeyword(token) || token.kind == .word) && isTypeStart(b.peek(1)) {
            node(K.attributedType) {
                while let next = cur {
                    if next.scope == "entity.other.attribute" {
                        attribute()
                    } else if Self.typeSpecifiers.contains(text(next)), isTypeStart(b.peek(1)) {
                        bump()
                    } else {
                        break
                    }
                }
                type()
            }
            return true
        }
        if isKeyword(token, "some") || isKeyword(token, "any") {
            node(isKeyword(token, "some") ? K.someType : K.anyType) {
                bump()
                type()
            }
            return true
        }
        guard primaryType() else {
            b.error("expected a type")
            return false
        }
        typeSuffixes(start)
        return true
    }

    private func isTypeStart(_ token: SyntaxToken?) -> Bool {
        guard let token else { return false }
        if isName(token) || token.scope == "variable.language" || token.scope == "entity.other.attribute" { return true }
        if isKeyword(token, "some") || isKeyword(token, "any") || Self.typeSpecifiers.contains(text(token)) { return true }
        return isSymbol(token, "(") || isSymbol(token, "[") || isSymbol(token, "~")
    }

    private func primaryType() -> Bool {
        guard let token = cur else { return false }
        if isSymbol(token, "(") {
            tupleType()
            return true
        }
        if isSymbol(token, "[") {
            node(colonAhead() ? K.dictionaryType : K.arrayType) {
                bump()
                type()
                if eat(":") { type() }
                expect("]")
            }
            return true
        }
        if isSymbol(token, "~") {
            node(K.typeIdentifier) {
                bump()
                if atName() { bumpName() }
            }
            return true
        }
        guard isName(token) || token.scope == "variable.language" || backtickAhead() || isKeyword(token, "Any") else { return false }
        node(K.typeIdentifier) {
            bumpName()
            if b.at("<") { genericArguments() }
            while isSymbol(cur, "."), let next = b.peek(1), isName(next) || isKeyword(next) || next.scope == "variable.language" {
                bump()
                bumpName()
                if b.at("<") { genericArguments() }
            }
        }
        return true
    }

    /// `?`, `!`, `...`, `.Type`, `& Other`, and `async throws -> Result` after a type.
    private func typeSuffixes(_ start: TreeBuilder.Checkpoint) {
        while let token = cur {
            if lastEnd == token.location, isSymbol(token, "?") || isSymbol(token, "!") {
                b.startNode(K.optionalType, at: start)
                bump()
                b.finishNode()
            } else if isSymbol(token, "&"), !lineBreakBefore(token), !isOperatorCharacter(b.peek(1)) || !adjacent(token, b.peek(1)) {
                b.startNode(K.compositionType, at: start)
                bump()
                if primaryType() {
                    typeSuffixesWithoutFunction()
                }
                b.finishNode()
            } else if isSymbol(token, "."), let next = b.peek(1), isName(next) {
                b.startNode(K.typeIdentifier, at: start)
                bump()
                bumpName()
                b.finishNode()
            } else if !lineBreakBefore(token), atKeyword("async") || atKeyword("throws") || b.at("->") {
                b.startNode(K.functionType, at: start)
                if atKeyword("async") || atKeyword("throws") { effects() }
                if expect("->") { type() }
                b.finishNode()
                return
            } else {
                return
            }
        }
    }

    private func typeSuffixesWithoutFunction() {
        while let token = cur, lastEnd == token.location, isSymbol(token, "?") || isSymbol(token, "!") { bump() }
    }

    /// `(Int, label: String)`: a tuple type, or a function type's parameters.
    private func tupleType() {
        node(K.tupleType) {
            bump()
            withFlags(braces: true, pattern: false, binding: false) {
                commaList(until: ")") {
                    node(K.tupleTypeElement) {
                        if isLabel(cur), isLabel(b.peek(1)), isSymbol(b.peek(2), ":") {
                            name(K.parameterLabel)
                            name(K.parameterName)
                            bump()
                        } else if isLabel(cur), isSymbol(b.peek(1), ":") {
                            name(K.parameterLabel)
                            bump()
                        }
                        type()
                        eat("...")
                        if eat("=") { expression() }
                    }
                }
            }
            expect(")")
        }
    }

    private func genericArguments() {
        node(K.genericArguments) {
            bump()
            commaList(until: ">") {
                if cur?.scope == "constant.numeric" { bump() } else { type() }
            }
            expect(">")
        }
    }
}
