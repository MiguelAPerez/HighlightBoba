import Foundation

extension PythonParse {
    /// Counts one more level of expression nesting; past the limit, wraps the next token in an
    /// error instead, so deep input costs no stack.
    func enter() -> Bool {
        guard nesting < Self.maxNesting, !stack.isLow else {
            if cur != nil { b.errorAndBump("nested too deeply") } else { b.error("nested too deeply") }
            return false
        }
        nesting += 1
        return true
    }

    /// Whether the next token can start an expression.
    var startsExpression: Bool {
        guard let token = cur else { return false }
        switch token.kind {
        case .word: return true
        case .symbol:
            switch text(token) {
            case "(", "[", "{", "-", "+", "~": return true
            case "*": return op == "*" || op == "**"
            case ".": return op == "..."
            default: return false
            }
        case .lexeme:
            if let word = keyword(token) { return ["not", "lambda", "await", "yield"].contains(word) || Self.softKeywords.contains(word) }
            return token.scope != "punctuation.section.embedded" && token.scope != "entity.other.attribute"
        default: return false
        }
    }

    // MARK: Lists of expressions

    /// Comma-separated expressions, any of them starred; a `tuple` when there's a comma.
    func starExpressions() {
        if atKeyword("yield") {
            yieldExpression()
            return
        }
        let start = b.checkpoint()
        starExpression()
        guard at(",") else { return }
        while at(",") {
            b.bump()
            guard startsExpression else { break }
            starExpression()
        }
        wrap(K.tuple, from: start)
    }

    func starExpression() {
        if atOp("*") {
            node(K.starred) {
                b.bump("*")
                binary(5)
            }
        } else {
            namedExpression()
        }
    }

    /// An expression; `name := value` is handled where the name is read.
    func namedExpression() { expression() }

    // MARK: Expressions

    func expression() {
        guard enter() else { return }
        defer { nesting -= 1 }
        if atKeyword("lambda") {
            lambda()
            return
        }
        if atKeyword("yield") {
            yieldExpression()
            return
        }
        let start = b.checkpoint()
        binary(1)
        if atKeyword("if") {
            b.startNode(K.conditional, at: start)
            b.bump()
            binary(1)
            if atKeyword("else") {
                b.bump()
                expression()
            } else {
                b.error("expected `else`")
            }
            b.finishNode()
        }
    }

    /// Operators from `or` (1) to `*` (10), by precedence climbing; prefix `not` (3) and `-` (11) included.
    func binary(_ minimum: Int) {
        guard enter() else { return }
        defer { nesting -= 1 }
        let start = b.checkpoint()
        if minimum <= 3 && atKeyword("not") {
            node(K.unary) {
                b.bump()
                binary(3)
            }
        } else if let prefix = op, prefix == "-" || prefix == "+" || prefix == "~" {
            node(K.unary) {
                b.bump()
                binary(11)
            }
        } else {
            power()
        }
        while let (spelling, precedence) = binaryOperator(), precedence >= minimum {
            b.startNode(K.binary, at: start)
            switch spelling {
            case "not in":
                b.bump()
                b.bump()
            case "is":
                b.bump()
                if atKeyword("not") { b.bump() }
            default:
                b.bump(spelling)
            }
            binary(precedence + 1)
            b.finishNode()
        }
    }

    func binaryOperator() -> (String, Int)? {
        guard let token = cur else { return nil }
        if let word = keyword(token) {
            switch word {
            case "or": return ("or", 1)
            case "and": return ("and", 2)
            case "in": return ("in", 4)
            case "is": return ("is", 4)
            case "not":
                guard let next = b.peek(1), keyword(next) == "in" else { return nil }
                return ("not in", 4)
            default: return nil
            }
        }
        // `a @b`: the lexer took `@b` for a decorator. It's matrix multiplication.
        if token.kind == .lexeme && token.scope == "entity.other.attribute" {
            guard b.relex(as: "matmulOperator") else { return nil }
        }
        switch op {
        case "<", ">", "==", ">=", "<=", "!=": return (op!, 4)
        case "|": return ("|", 5)
        case "^": return ("^", 6)
        case "&": return ("&", 7)
        case "<<", ">>": return (op!, 8)
        case "+", "-": return (op!, 9)
        case "*", "/", "//", "%", "@": return (op!, 10)
        default: return nil
        }
    }

    /// `await`, then a primary, then `**` and its right side, which binds to the right.
    func power() {
        let start = b.checkpoint()
        if atKeyword("await") {
            node(K.awaitExpression) {
                b.bump()
                primary()
            }
        } else {
            primary()
        }
        if atOp("**") {
            b.startNode(K.binary, at: start)
            b.bump("**")
            binary(11)
            b.finishNode()
        }
    }

    func primary() {
        let start = b.checkpoint()
        atom()
        trailers(start)
    }

    /// `.name`, calls and subscripts after what was parsed since `start`.
    func trailers(_ start: TreeBuilder.Checkpoint) {
        while true {
            if atOp(".") {
                b.startNode(K.attribute, at: start)
                b.bump(".")
                if let token = cur, isName(token) {
                    // An attribute is never the builtin or `self` the lexer read: `"".format`, `node.self`.
                    if token.kind == .lexeme && token.scope != "entity.name.type" && token.scope != "entity.name.function" {
                        b.relex(as: "identifier")
                    }
                    b.bump()
                } else {
                    b.error("expected an attribute name")
                }
                b.finishNode()
            } else if at("(") {
                b.startNode(K.call, at: start)
                arguments()
                b.finishNode()
            } else if at("[") {
                b.startNode(K.subscription, at: start)
                bracketed("[", "]") {
                    guard !at("]") else {
                        b.error("expected a subscript")
                        return
                    }
                    sliceItem()
                    commaList(afterFirst: true) { sliceItem() }
                }
                b.finishNode()
            } else {
                return
            }
        }
    }

    func sliceItem() {
        let start = b.checkpoint()
        if !atOp(":") { starExpression() }
        guard atOp(":") else { return }
        b.startNode(K.slice, at: start)
        b.bump(":")
        if !atOp(":") && !atListEnd && !at(",") { expression() }
        if atOp(":") {
            b.bump(":")
            if !atListEnd && !at(",") { expression() }
        }
        b.finishNode()
    }

    func atom() {
        guard let token = cur else {
            b.error("expected an expression")
            return
        }
        if isName(token) {
            let start = b.checkpoint()
            bumpName()
            if atOp(":=") {
                wrap(K.target, from: start)
                b.startNode(K.namedExpression, at: start)
                b.bump(":=")
                expression()
                b.finishNode()
            }
            return
        }
        switch token.kind {
        case .lexeme:
            if isString(token) || isFieldBrace(token, "{") {
                string()
            } else if token.scope == "constant.numeric" || token.scope == "constant.language" {
                b.bump()
            } else if let word = keyword(token), ["not", "lambda", "await", "yield"].contains(word) {
                expression()
            } else {
                b.error("expected an expression")
            }
        case .symbol:
            switch text(token) {
            case "(": parenthesized()
            case "[": listDisplay()
            case "{": braceDisplay()
            case "." where op == "...": b.bump("...")
            case "-", "+", "~": binary(11)
            default: b.error("expected an expression")
            }
        default:
            b.error("expected an expression")
        }
    }

    var atComprehension: Bool {
        if atKeyword("for") { return true }
        guard atKeyword("async"), let next = b.peek(1) else { return false }
        return keyword(next) == "for"
    }

    func comprehensionClauses() {
        while atComprehension {
            node(K.forClause) {
                if atKeyword("async") { b.bump() }
                b.bump()
                targetList()
                if atKeyword("in") {
                    b.bump()
                    binary(1)
                } else {
                    b.error("expected `in`")
                }
            }
            while atKeyword("if") {
                node(K.ifClause) {
                    b.bump()
                    binary(1)
                }
            }
        }
    }

    func parenthesized() {
        let start = b.checkpoint()
        var kind = K.parenthesized
        bracketed("(", ")") {
            if at(")") {
                kind = K.tuple
                return
            }
            if atKeyword("yield") {
                yieldExpression()
                return
            }
            starExpression()
            if atComprehension {
                comprehensionClauses()
                kind = K.generator
                return
            }
            guard at(",") else { return }
            kind = K.tuple
            commaList(afterFirst: true) { starExpression() }
        }
        wrap(kind, from: start)
    }

    func listDisplay() {
        let start = b.checkpoint()
        bracketed("[", "]") {
            guard !at("]") else { return }
            starExpression()
            if atComprehension {
                comprehensionClauses()
                return
            }
            commaList(afterFirst: true) { starExpression() }
        }
        wrap(K.list, from: start)
    }

    func braceDisplay() {
        let start = b.checkpoint()
        var kind = K.set
        bracketed("{", "}") {
            if at("}") {
                kind = K.dictionary
                return
            }
            if atOp("**") {
                kind = K.dictionary
                dictionaryItem()
            } else {
                let item = b.checkpoint()
                starExpression()
                if atOp(":") {
                    kind = K.dictionary
                    b.startNode(K.pair, at: item)
                    b.bump(":")
                    expression()
                    b.finishNode()
                }
            }
            if atComprehension {
                comprehensionClauses()
                return
            }
            if kind == K.dictionary {
                commaList(afterFirst: true) { dictionaryItem() }
            } else {
                commaList(afterFirst: true) { starExpression() }
            }
        }
        wrap(kind, from: start)
    }

    func dictionaryItem() {
        if atOp("**") {
            node(K.starred) {
                b.bump("**")
                binary(5)
            }
            return
        }
        guard startsExpression else { return }
        let item = b.checkpoint()
        expression()
        b.startNode(K.pair, at: item)
        if atOp(":") {
            b.bump(":")
            expression()
        } else {
            b.error("expected `:`")
        }
        b.finishNode()
    }

    func arguments() {
        node(K.arguments) {
            bracketed("(", ")") {
                guard !at(")") else { return }
                let first = b.checkpoint()
                argument()
                if atComprehension {
                    comprehensionClauses()
                    wrap(K.generator, from: first)
                }
                commaList(afterFirst: true) { argument() }
            }
        }
    }

    func argument() {
        if let star = op, star == "*" || star == "**" {
            node(K.starred) {
                b.bump(star)
                expression()
            }
        } else if atName && op(at: 1) == "=" {
            node(K.keywordArgument) {
                bumpName()
                b.bump("=")
                expression()
            }
        } else if startsExpression {
            namedExpression()
        }
    }

    func yieldExpression() {
        guard enter() else { return }
        defer { nesting -= 1 }
        node(K.yieldExpression) {
            b.bump()
            if atKeyword("from") {
                b.bump()
                expression()
            } else if startsExpression {
                starExpressions()
            }
        }
    }

    func lambda() {
        node(K.lambda) {
            b.bump()
            if !atOp(":") && cur != nil { node(K.parameters) { parameterList(lambda: true) } }
            expectOp(":")
            expression()
        }
    }

    // MARK: Strings

    /// String pieces, implicitly concatenated, and the replacement fields of f-strings in them.
    func string() {
        node(K.string) {
            while let token = cur {
                if isFieldBrace(token, "{") {
                    field()
                } else if isString(token) {
                    b.bump()
                } else {
                    break
                }
            }
        }
    }

    /// `{expression=!conversion:spec}` in an f-string. The lexer reads the expression as code and
    /// the spec as string text, with the field's own braces as `punctuation.section.embedded`.
    func field() {
        node(K.field) {
            b.bump()
            brackets += 1
            if let token = cur, !isFieldBrace(token, "}"), startsExpression { starExpressions() }
            if atOp("=") { b.bump("=") }
            if atOp("!") {
                b.bump("!")
                if atName { b.bump() }
            }
            if atOp(":") {
                node(K.formatSpec) {
                    b.bump(":")
                    while let token = cur, !isFieldBrace(token, "}") {
                        if isFieldBrace(token, "{") { field() } else { b.bump() }
                    }
                }
            }
            let closed = cur.map { isFieldBrace($0, "}") } ?? false
            brackets -= 1
            if closed { b.bump() } else { b.error("expected `}`") }
        }
    }

    // MARK: Targets and parameters

    /// The targets of `for` and comprehensions, which stop before `in`.
    func targetList() {
        guard startsExpression else {
            b.error("expected a target")
            return
        }
        node(K.target) {
            let start = b.checkpoint()
            targetItem()
            guard at(",") else { return }
            while at(",") {
                b.bump()
                guard startsExpression else { break }
                targetItem()
            }
            wrap(K.tuple, from: start)
        }
    }

    func targetItem() {
        if atOp("*") {
            node(K.starred) {
                b.bump("*")
                binary(5)
            }
        } else {
            binary(5)
        }
    }

    func parameters() {
        node(K.parameters) { bracketed("(", ")") { parameterList(lambda: false) } }
    }

    /// Parameters until `)`, or a lambda's `:`.
    func parameterList(lambda: Bool) {
        var needsComma = false
        while let token = cur {
            if lambda ? atOp(":") : Self.closers.contains(text(token)) { break }
            if needsComma {
                if at(",") {
                    b.bump()
                    needsComma = false
                } else {
                    junk("expected `,`")
                }
                continue
            }
            if parameter(lambda: lambda) {
                needsComma = true
            } else {
                junk("expected a parameter")
            }
        }
    }

    /// `name: annotation = default`, `*args`, `**kwargs`, `*` or `/`. Returns false, having read
    /// nothing, when none of those comes next.
    func parameter(lambda: Bool) -> Bool {
        let marker = op.flatMap { ["*", "**", "/"].contains($0) ? $0 : nil }
        guard marker != nil || atName else { return false }
        node(K.parameter) {
            if let marker {
                b.bump(marker)
                if marker == "/" || !atName { return }
            }
            bumpName()
            if !lambda && atOp(":") {
                b.bump(":")
                node(K.annotation) {
                    if atOp("*") {
                        node(K.starred) {
                            b.bump("*")
                            expression()
                        }
                    } else {
                        expression()
                    }
                }
            }
            if atOp("=") {
                b.bump("=")
                node(K.defaultValue) { expression() }
            }
        }
        return true
    }

    /// PEP 695: `[T: bound = default, *Ts, **P]`.
    func typeParameters() {
        node(K.typeParameters) {
            bracketed("[", "]") {
                commaList {
                    let marker = op.flatMap { ["*", "**"].contains($0) ? $0 : nil }
                    guard marker != nil || atName else { return }
                    node(K.typeParameter) {
                        if let marker { b.bump(marker) }
                        if atName { bumpName() } else { b.error("expected a type parameter name") }
                        if atOp(":") {
                            b.bump(":")
                            node(K.annotation) { expression() }
                        }
                        if atOp("=") {
                            b.bump("=")
                            node(K.annotation) { expression() }
                        }
                    }
                }
            }
        }
    }
}
