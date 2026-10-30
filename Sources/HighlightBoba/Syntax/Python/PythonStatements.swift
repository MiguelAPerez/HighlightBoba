import Foundation

extension PythonParse {
    // MARK: Blocks

    func module() {
        statements(indent: 0)
        while let token = b.current { b.errorAndBump("unexpected `\(text(token))`") }
    }

    /// An indented block, from its first token, which starts a line.
    func block() {
        guard let first = b.current else { return }
        let indent = width(first) ?? lineIndent
        node(K.block) { statements(indent: indent) }
    }

    /// Statements until a line indented less than `indent`.
    func statements(indent: Int) {
        while let token = nextLine {
            if let width = width(token) {
                if width < indent { return }
                if width > indent { b.error("unexpected indent") }
                lineIndent = width
            }
            statement()
        }
    }

    /// What follows a compound statement's `:`: simple statements on the same line, or an
    /// indented block on the next.
    func suite(_ col: Int) {
        if cur != nil {
            simpleStatements()
            return
        }
        guard let next = nextLine, let width = width(next), width > col else {
            b.error("expected an indented block")
            return
        }
        guard b.depth < Self.maxDepth else {
            b.error("blocks nested too deeply")
            return
        }
        block()
    }

    func colonSuite(_ col: Int) {
        expectOp(":")
        suite(col)
    }

    /// Whether the next line starts with the clause keyword `word` at `col`, as `else` follows an
    /// `if`. It then heads the logical line.
    func clause(_ word: String, _ col: Int) -> Bool {
        guard let token = nextLine, width(token) == col, keyword(token) == word else { return false }
        joined = token.location
        lineIndent = col
        return true
    }

    func elseClause(_ col: Int) {
        if clause("else", col) { node(K.elseClause) { b.bump(); colonSuite(col) } }
    }

    // MARK: Statements

    func statement() {
        guard let token = b.current else { return }
        joined = token.location
        let col = lineIndent
        if let word = keyword(token) {
            switch word {
            case "def": function(col); return
            case "class": classDefinition(col); return
            case "if": ifStatement(col); return
            case "while": whileStatement(col); return
            case "for": forStatement(col); return
            case "try": tryStatement(col); return
            case "with": withStatement(col); return
            case "async":
                if let next = b.peek(1), b.indentation(of: next) == nil {
                    switch keyword(next) {
                    case "def": function(col); return
                    case "for": forStatement(col); return
                    case "with": withStatement(col); return
                    default: break
                    }
                }
            case "elif", "else", "except", "finally": strayClause(word, col); return
            default: break
            }
        }
        if isDecoratorStart(token) {
            decorated(col)
            return
        }
        if text(token) == "match" && isName(token) && looksLikeMatch() {
            matchStatement(col)
            return
        }
        simpleStatements()
    }

    func simpleStatements() {
        while true {
            smallStatement()
            guard at(";") else { break }
            b.bump()
            if cur == nil { break }
        }
        restOfLine("expected a line break")
    }

    func smallStatement() {
        guard let token = cur else { return }
        switch keyword(token) {
        case "pass", "break", "continue":
            node(K.keywordStatement) { b.bump() }
        case "return":
            node(K.keywordStatement) {
                b.bump()
                if startsExpression { starExpressions() }
            }
        case "raise":
            node(K.keywordStatement) {
                b.bump()
                guard startsExpression else { return }
                expression()
                if atKeyword("from") {
                    b.bump()
                    expression()
                }
            }
        case "global", "nonlocal":
            node(K.keywordStatement) {
                b.bump()
                repeat {
                    guard atName else {
                        b.error("expected a name")
                        break
                    }
                    b.bump()
                } while bumpComma()
            }
        case "del":
            node(K.keywordStatement) {
                b.bump()
                starExpressions()
            }
        case "assert":
            node(K.keywordStatement) {
                b.bump()
                expression()
                if at(",") {
                    b.bump()
                    expression()
                }
            }
        case "import": importStatement()
        case "from": importFrom()
        default:
            if text(token) == "type" && isName(token) && looksLikeTypeAlias() {
                typeAlias()
            } else {
                expressionStatement()
            }
        }
    }

    /// Bumps a `,` that more of the list follows on the same line.
    func bumpComma() -> Bool {
        guard at(",") else { return false }
        b.bump()
        return cur != nil
    }

    static let augmented: Set<String> = ["+=", "-=", "*=", "/=", "//=", "%=", "**=", ">>=", "<<=", "&=", "|=", "^=", "@="]

    func expressionStatement() {
        let start = b.checkpoint()
        starExpressions()
        if atOp("=") {
            wrap(K.target, from: start)
            b.startNode(K.assignment, at: start)
            while atOp("=") {
                b.bump("=")
                let value = b.checkpoint()
                starExpressions()
                if atOp("=") { wrap(K.target, from: value) }
            }
            b.finishNode()
        } else if let assign = op, Self.augmented.contains(assign) {
            wrap(K.target, from: start)
            b.startNode(K.assignment, at: start)
            b.bump(assign)
            starExpressions()
            b.finishNode()
        } else if atOp(":") {
            wrap(K.target, from: start)
            b.startNode(K.assignment, at: start)
            b.bump(":")
            node(K.annotation) { expression() }
            if atOp("=") {
                b.bump("=")
                starExpressions()
            }
            b.finishNode()
        } else {
            wrap(K.expressionStatement, from: start)
        }
    }

    func importStatement() {
        node(K.importStatement) {
            b.bump()
            repeat {
                dottedName()
                if atKeyword("as") {
                    b.bump()
                    alias()
                }
            } while bumpComma()
        }
    }

    func importFrom() {
        node(K.importFrom) {
            b.bump()
            var sawDots = false
            while let run = op, run == "." || run == "..." {
                b.bump(run)
                sawDots = true
            }
            if atName {
                dottedName()
            } else if !sawDots {
                b.error("expected a module name")
            }
            guard atKeyword("import") else {
                b.error("expected `import`")
                return
            }
            b.bump()
            if at("*") {
                b.bump()
            } else if at("(") {
                bracketed("(", ")") { commaList { importName() } }
            } else {
                repeat { importName() } while bumpComma()
            }
        }
    }

    func dottedName() {
        guard atName else {
            b.error("expected a module name")
            return
        }
        b.bump()
        while atOp(".") {
            b.bump(".")
            if atName { b.bump() } else { b.error("expected a name") }
        }
    }

    func importName() {
        guard atName else {
            b.error("expected a name")
            return
        }
        b.bump()
        if atKeyword("as") {
            b.bump()
            alias()
        }
    }

    /// The name after `as`, which it binds.
    func alias() {
        if atName { node(K.target) { bumpName() } } else { b.error("expected a name") }
    }

    func looksLikeTypeAlias() -> Bool {
        guard let name = b.peek(1), b.indentation(of: name) == nil, isName(name),
              let after = b.peek(2), b.indentation(of: after) == nil, after.kind == .symbol else { return false }
        return text(after) == "[" || op(at: 2) == "="
    }

    func typeAlias() {
        node(K.typeAlias) {
            b.bump()
            bumpName()
            if at("[") { typeParameters() }
            expectOp("=")
            node(K.annotation) { expression() }
        }
    }

    // MARK: Compound statements

    func isDecoratorStart(_ token: SyntaxToken) -> Bool {
        if token.kind == .symbol { return text(token) == "@" }
        return token.kind == .lexeme && token.scope == "entity.other.attribute" && text(token).hasPrefix("@")
    }

    func decorated(_ col: Int) {
        node(K.decorated) {
            decorator()
            while let next = nextLine, width(next) != nil, isDecoratorStart(next) {
                joined = next.location
                decorator()
            }
            guard let next = nextLine, width(next) != nil else {
                b.error("expected `def` or `class` after a decorator")
                return
            }
            joined = next.location
            switch keyword(next) {
            case "def", "async": function(col)
            case "class": classDefinition(col)
            default: b.error("expected `def` or `class` after a decorator")
            }
        }
    }

    func decorator() {
        node(K.decorator) {
            if let token = cur, token.kind == .lexeme {
                // `@name.name`, one token from the lexer, then any calls.
                let start = b.checkpoint()
                b.bump()
                trailers(start)
            } else {
                b.bump()
                namedExpression()
            }
            restOfLine("expected a line break after a decorator")
        }
    }

    func function(_ col: Int) {
        node(K.function) {
            if atKeyword("async") { b.bump() }
            if atKeyword("def") { b.bump() } else { b.error("expected `def`") }
            if atName { bumpName() } else { b.error("expected a function name") }
            if at("[") { typeParameters() }
            if at("(") { parameters() } else { b.error("expected `(`") }
            if atOp("->") {
                b.bump("->")
                node(K.annotation) { expression() }
            }
            colonSuite(col)
        }
    }

    func classDefinition(_ col: Int) {
        node(K.classDefinition) {
            b.bump()
            if atName { bumpName() } else { b.error("expected a class name") }
            if at("[") { typeParameters() }
            if at("(") { arguments() }
            colonSuite(col)
        }
    }

    func ifStatement(_ col: Int) {
        node(K.ifStatement) {
            b.bump()
            namedExpression()
            colonSuite(col)
            while clause("elif", col) {
                node(K.elifClause) {
                    b.bump()
                    namedExpression()
                    colonSuite(col)
                }
            }
            elseClause(col)
        }
    }

    func whileStatement(_ col: Int) {
        node(K.whileStatement) {
            b.bump()
            namedExpression()
            colonSuite(col)
            elseClause(col)
        }
    }

    func forStatement(_ col: Int) {
        node(K.forStatement) {
            if atKeyword("async") { b.bump() }
            b.bump()
            targetList()
            if atKeyword("in") {
                b.bump()
                starExpressions()
            } else {
                b.error("expected `in`")
            }
            colonSuite(col)
            elseClause(col)
        }
    }

    func tryStatement(_ col: Int) {
        node(K.tryStatement) {
            b.bump()
            colonSuite(col)
            while clause("except", col) { exceptClause(col) }
            elseClause(col)
            if clause("finally", col) {
                node(K.finallyClause) {
                    b.bump()
                    colonSuite(col)
                }
            }
        }
    }

    func exceptClause(_ col: Int) {
        node(K.exceptClause) {
            b.bump()
            if at("*") { b.bump() }
            if startsExpression {
                starExpressions()
                if atKeyword("as") {
                    b.bump()
                    alias()
                }
            }
            colonSuite(col)
        }
    }

    func withStatement(_ col: Int) {
        node(K.withStatement) {
            if atKeyword("async") { b.bump() }
            b.bump()
            if at("(") && parenthesizesItems() {
                bracketed("(", ")") { commaList { withItem() } }
            } else {
                repeat { withItem() } while bumpComma()
            }
            colonSuite(col)
        }
    }

    /// Whether the `(` after `with` closes right before the header's `:`, so it holds the items,
    /// as in `with (open(a) as f, open(b) as g):`, rather than starting the first expression.
    func parenthesizesItems() -> Bool {
        var depth = 0
        var offset = 0
        while offset < 2048, let token = b.peek(offset) {
            if token.kind == .symbol {
                switch text(token) {
                case "(", "[", "{": depth += 1
                case ")", "]", "}":
                    depth -= 1
                    if depth == 0 {
                        guard let after = b.peek(offset + 1), after.kind == .symbol, text(after) == ":" else { return false }
                        return op(at: offset + 1) == ":"
                    }
                default: break
                }
            }
            offset += 1
        }
        return false
    }

    func withItem() {
        guard startsExpression else { return }
        node(K.withItem) {
            expression()
            if atKeyword("as") {
                b.bump()
                node(K.target) { targetItem() }
            }
        }
    }

    /// A clause keyword with no statement to belong to: parsed as a clause, inside an `error` node.
    func strayClause(_ word: String, _ col: Int) {
        b.error("`\(word)` without a statement it belongs to")
        node(.error) {
            b.bump()
            if startsExpression { starExpressions() }
            if atKeyword("as") {
                b.bump()
                alias()
            }
            colonSuite(col)
        }
    }

    // MARK: match

    /// Whether `match` at the start of a statement starts a match statement: something that can
    /// start a subject follows it, and its logical line ends in `:`. Otherwise `match` is a name
    /// (`match = 1`, `match(x)`).
    func looksLikeMatch() -> Bool {
        guard let first = b.peek(1), b.indentation(of: first) == nil else { return false }
        switch first.kind {
        case .symbol:
            guard ["(", "[", "{", "-", "+", "~", "*", "."].contains(text(first)) else { return false }
            if text(first) == "*" && op(at: 1) != "*" { return false }
            if text(first) == "." && op(at: 1) != "..." { return false }
        case .lexeme:
            if let word = keyword(first), !["not", "lambda", "await"].contains(word) && !Self.softKeywords.contains(word) { return false }
        default: break
        }
        var depth = 0
        var offset = 1
        var last = first
        while offset < 2048 {
            guard let token = b.peek(offset) else { break }
            if offset > 1 && b.indentation(of: token) != nil && !(last.kind == .symbol && text(last) == "\\") {
                if depth == 0 || Self.statementOnly.contains(keyword(token) ?? "") { break }
            }
            if token.kind == .symbol || (token.kind == .lexeme && token.scope == "punctuation.section.embedded") {
                switch text(token) {
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth = max(0, depth - 1)
                default: break
                }
            }
            last = token
            offset += 1
        }
        return offset < 2048 && depth == 0 && last.kind == .symbol && text(last) == ":"
    }

    func matchStatement(_ col: Int) {
        node(K.matchStatement) {
            b.bump()
            starExpressions()
            expectOp(":")
            restOfLine("expected a line break after `match`")
            guard let next = nextLine, let width = width(next), width > col else {
                b.error("expected an indented block of `case` clauses")
                return
            }
            guard b.depth < Self.maxDepth else {
                b.error("blocks nested too deeply")
                return
            }
            caseBlock()
        }
    }

    /// A match statement's block, from its first token: `case` clauses.
    func caseBlock() {
        guard let first = b.current else { return }
        let indent = width(first) ?? lineIndent
        node(K.caseBlock) {
            while let token = nextLine {
                if let width = width(token) {
                    if width < indent { return }
                    if width > indent { b.error("unexpected indent") }
                    lineIndent = width
                }
                joined = token.location
                if text(token) == "case" && isName(token) {
                    caseClause(lineIndent)
                } else {
                    b.error("expected `case`")
                    node(.error) { statement() }
                }
            }
        }
    }

    func caseClause(_ col: Int) {
        node(K.caseClause) {
            b.bump()
            if startsPattern { node(K.casePattern) { openSequencePattern() } } else { b.error("expected a pattern") }
            if atKeyword("if") {
                node(K.guardClause) {
                    b.bump()
                    namedExpression()
                }
            }
            colonSuite(col)
        }
    }
}
