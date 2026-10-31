import Foundation

/// `case` patterns (PEP 634).
extension PythonParse {
    var startsPattern: Bool {
        guard let token = cur else { return false }
        if isName(token) { return true }
        switch token.kind {
        case .lexeme:
            return isString(token) || isFieldBrace(token, "{") || token.scope == "constant.numeric" || token.scope == "constant.language"
        case .symbol:
            return ["(", "[", "{", "-", "*"].contains(text(token))
        default:
            return false
        }
    }

    /// Patterns separated by commas, without brackets: `case a, *rest:`.
    func openSequencePattern() {
        let start = b.checkpoint()
        starPattern()
        guard at(",") else { return }
        while at(",") {
            b.bump()
            guard startsPattern else { break }
            starPattern()
        }
        wrap(K.sequencePattern, from: start)
    }

    func starPattern() {
        if atOp("*") {
            node(K.starred) {
                b.bump("*")
                if atName { b.bump() } else { b.error("expected a name") }
            }
        } else {
            pattern()
        }
    }

    /// An or-pattern, perhaps with `as name`.
    func pattern() {
        guard enter() else { return }
        defer { nesting -= 1 }
        let start = b.checkpoint()
        closedPattern()
        if atOp("|") {
            b.startNode(K.orPattern, at: start)
            while atOp("|") {
                b.bump("|")
                closedPattern()
            }
            b.finishNode()
        }
        if atKeyword("as") {
            b.startNode(K.asPattern, at: start)
            b.bump()
            alias()
            b.finishNode()
        }
    }

    func closedPattern() {
        guard let token = cur else {
            b.error("expected a pattern")
            return
        }
        if isName(token) {
            let start = b.checkpoint()
            bumpName()
            var dotted = false
            while atOp(".") {
                b.bump(".")
                if atName { b.bump() } else { b.error("expected a name") }
                dotted = true
            }
            if at("(") {
                wrap(K.valuePattern, from: start)
                b.startNode(K.classPattern, at: start)
                bracketed("(", ")") { commaList { patternArgument() } }
                b.finishNode()
            } else if dotted {
                wrap(K.valuePattern, from: start)
            }
            return
        }
        if token.kind == .lexeme || atOp("-") {
            literalPattern()
            return
        }
        switch text(token) {
        case "(":
            let start = b.checkpoint()
            var kind = K.sequencePattern
            bracketed("(", ")") {
                guard !at(")") else { return }
                starPattern()
                if at(",") {
                    commaList(afterFirst: true) { starPattern() }
                } else {
                    kind = K.parenthesized
                }
            }
            wrap(kind, from: start)
        case "[":
            let start = b.checkpoint()
            bracketed("[", "]") { commaList { starPattern() } }
            wrap(K.sequencePattern, from: start)
        case "{":
            let start = b.checkpoint()
            bracketed("{", "}") { commaList { mappingItem() } }
            wrap(K.mappingPattern, from: start)
        default:
            b.error("expected a pattern")
        }
    }

    /// A number (`-1`, `1+2j`), string, `None`, `True` or `False`.
    func literalPattern() {
        guard let token = cur else { return }
        if isString(token) || isFieldBrace(token, "{") {
            node(K.valuePattern) { string() }
            return
        }
        guard token.kind == .lexeme || atOp("-") else {
            b.error("expected a pattern")
            return
        }
        node(K.valuePattern) {
            if atOp("-") { b.bump("-") }
            guard let number = cur, number.scope == "constant.numeric" || number.scope == "constant.language" else {
                b.error("expected a number")
                return
            }
            b.bump()
            if let sign = op, sign == "+" || sign == "-" {
                b.bump(sign)
                if cur?.scope == "constant.numeric" { b.bump() } else { b.error("expected a number") }
            }
        }
    }

    func patternArgument() {
        if atName && op(at: 1) == "=" {
            node(K.keywordPattern) {
                b.bump()
                b.bump("=")
                pattern()
            }
        } else if startsPattern {
            starPattern()
        }
    }

    func mappingItem() {
        if atOp("**") {
            node(K.starred) {
                b.bump("**")
                if atName { b.bump() } else { b.error("expected a name") }
            }
            return
        }
        guard startsPattern else { return }
        let item = b.checkpoint()
        closedPattern()
        b.startNode(K.pair, at: item)
        expectOp(":")
        pattern()
        b.finishNode()
    }
}
