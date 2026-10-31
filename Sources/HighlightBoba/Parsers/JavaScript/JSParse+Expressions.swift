import Foundation

extension JSParse {
    static let assignmentOperators: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=",
                                                    "|=", "^=", "&&=", "||=", "??="]

    static let precedence: [String: Int] = [
        "??": 1, "||": 2, "&&": 3, "|": 4, "^": 5, "&": 6, "==": 7, "!=": 7, "===": 7, "!==": 7,
        "<": 8, ">": 8, "<=": 8, ">=": 8, "<<": 9, ">>": 9, ">>>": 9, "+": 10, "-": 10, "*": 11, "/": 11, "%": 11, "**": 12
    ]

    static let relational = 8

    /// An expression, commas included. With `noIn`, `in` isn't an operator (a `for` head).
    func expression(noIn: Bool = false) {
        let mark = checkpoint()
        assignment(noIn: noIn)
        guard atSym(",") else { return }
        start(JSKind.sequenceExpression, at: mark)
        while atSym(",") {
            bump()
            assignment(noIn: noIn)
        }
        finish()
    }

    func assignment(noIn: Bool = false) {
        if tooDeep() { return }
        if atWord("yield") { return yieldExpression(noIn: noIn) }
        if arrowAhead() { return arrowFunction(noIn: noIn) }
        let mark = checkpoint()
        conditional(noIn: noIn)
        if let spelling = assignmentOperator() {
            start(JSKind.assignmentExpression, at: mark)
            bump(spelling)
            assignment(noIn: noIn)
            finish()
        }
    }

    @inline(never)
    func assignmentOperator() -> String? {
        guard let spelling = op(), Self.assignmentOperators.contains(spelling) else { return nil }
        return spelling
    }

    /// Whether an arrow function starts here: `x =>`, `(…) =>`, `async x =>`, `<T>(…) =>`.
    @inline(never)
    func arrowAhead() -> Bool {
        if isIdentifier() && arrow(at: 1) { return true }
        if atWord("async") && !newlineBetween(0, 1) {
            if isIdentifier(1) && arrow(at: 2) { return true }
            if atSym("(", 1) { return arrowFollows(parenAt: 1) }
            if ts && atSym("<", 1) { return typeParametersCanStart(at: 1) && genericArrow(at: 1) }
        }
        if atSym("(") { return arrowFollows(parenAt: 0) }
        if ts && (atSym("<") || jsxPunctuation("<")) && typeParametersCanStart(at: 0) {
            angleIfNeeded()
            return genericArrow(at: 0)
        }
        return false
    }

    /// In TSX, `<T>` where an expression starts is an element, so type parameters there are
    /// written `<T,>` or `<T extends U>`. Elsewhere any `<` may open them.
    @inline(never)
    func typeParametersCanStart(at start: Int) -> Bool {
        guard jsx else { return true }
        let name = atWord("const", start + 1) && isIdentifier(start + 2) ? start + 2 : start + 1
        guard isIdentifier(name) else { return false }
        if atSym(",", name + 1) { return true }
        // `<T extends>` is an element with an attribute named `extends`.
        guard atWord("extends", name + 1) else { return false }
        return !atSym("=", name + 2) && !atSym(">", name + 2) && !atSym("/", name + 2)
    }

    func arrowFunction(noIn: Bool) {
        start(JSKind.arrowFunction)
        if atWord("async") && !arrow(at: 1) { bump() }
        if ts && atSym("<") { typeParameters() }
        if atSym("(") {
            formalParameters()
            if ts && atSym(":") { returnType() }
        } else if isIdentifier() {
            wrap(JSKind.binding)
        }
        if !bump("=>") { error("expected `=>`") }
        arrowBody(noIn: noIn)
        finish()
    }

    func arrowBody(noIn: Bool) {
        if atSym("{") { block() } else { assignment(noIn: noIn) }
    }

    func yieldExpression(noIn: Bool) {
        start(JSKind.yieldExpression)
        bump()
        if atSym("*") {
            bump()
            assignment(noIn: noIn)
        } else if !newlineBefore && startsOperand {
            assignment(noIn: noIn)
        }
        finish()
    }

    /// Whether the next token can begin an operand, for the optional ones after `yield`.
    var startsOperand: Bool {
        guard let token = cur, !atCloser else { return false }
        if token.kind != .symbol { return true }
        switch op() {
        case ",", ";", ":", "?", "=", "=>": return false
        case let spelling?: return Self.precedence[spelling] == nil || spelling == "+" || spelling == "-" || spelling == "<"
        case nil: return true
        }
    }

    func conditional(noIn: Bool) {
        let mark = checkpoint()
        binary(0, noIn: noIn)
        guard atOp("?") else { return }
        start(JSKind.conditionalExpression, at: mark)
        bump()
        assignment()
        expect(":")
        assignment(noIn: noIn)
        finish()
    }

    /// Binary operators by precedence climbing, left-associative except `**`.
    func binary(_ minimum: Int, noIn: Bool) {
        let mark = checkpoint()
        unary()
        while true {
            divisionIfNeeded()
            angleIfNeeded()
            guard let (spelling, level) = binaryOperator(noIn: noIn), level >= minimum else { return }
            if spelling == "as" || spelling == "satisfies" {
                typeCast(spelling, from: mark)
                continue
            }
            start(JSKind.binaryExpression, at: mark)
            bump(spelling)
            binary(spelling == "**" ? level : level + 1, noIn: noIn)
            finish()
        }
    }

    /// `value as T`, `value satisfies T`, `value as const`.
    @inline(never)
    func typeCast(_ spelling: String, from mark: TreeBuilder.Checkpoint) {
        start(spelling == "as" ? JSKind.asExpression : JSKind.satisfiesExpression, at: mark)
        bump()
        if atWord("const") { bump() } else { type() }
        finish()
    }

    @inline(never)
    func binaryOperator(noIn: Bool) -> (String, Int)? {
        if let name = word() {
            switch name {
            case "instanceof": return (name, Self.relational)
            case "in": return noIn ? nil : (name, Self.relational)
            case "as", "satisfies": return ts && !newlineBefore ? (name, Self.relational) : nil
            default: return nil
            }
        }
        guard let spelling = op(), let level = Self.precedence[spelling] else { return nil }
        return (spelling, level)
    }

    /// An operator belongs here, so a regex the lexer started here is division: `a\n/ b / c`, `x++ / 2`.
    @inline(never)
    func divisionIfNeeded() {
        if let token = cur, isLexeme(token, "string.regexp"), text(token).hasPrefix("/") { relex(.division) }
    }

    enum UnaryStart {
        case prefix(String)
        case keyword
        case await
        case assertion
        case operand
    }

    @inline(never)
    func unaryStart() -> UnaryStart {
        if let spelling = op(), ["!", "~", "+", "-", "++", "--"].contains(spelling) { return .prefix(spelling) }
        switch word() {
        case "typeof", "void", "delete": return .keyword
        case "await": return .await
        default: return ts && !jsx && atSym("<") ? .assertion : .operand
        }
    }

    func unary() {
        if tooDeep() { return }
        switch unaryStart() {
        case .prefix(let spelling):
            start(spelling == "++" || spelling == "--" ? JSKind.updateExpression : JSKind.unaryExpression)
            bump(spelling)
            unary()
            finish()
        case .keyword, .await:
            start(atWord("await") ? JSKind.awaitExpression : JSKind.unaryExpression)
            bump()
            unary()
            finish()
        case .assertion:
            // `<T>value`; a generic arrow was taken at the assignment level.
            start(JSKind.typeAssertion)
            typeArguments()
            unary()
            finish()
        case .operand:
            let mark = checkpoint()
            leftHandSide()
            postfixUpdate(from: mark)
        }
    }

    @inline(never)
    func postfixUpdate(from mark: TreeBuilder.Checkpoint) {
        if let spelling = op(), spelling == "++" || spelling == "--", !newlineBefore {
            start(JSKind.updateExpression, at: mark)
            bump(spelling)
            finish()
        }
    }

    /// A primary expression and its member accesses, calls and tagged templates.
    func leftHandSide() {
        let mark = checkpoint()
        if atWord("new") { newExpression() } else { primary() }
        chain(from: mark, calls: true)
    }

    enum ChainStep {
        case member, optional, index, call, taggedTemplate, nonNull, typeArguments, end
    }

    @inline(never)
    func chainStep(calls: Bool) -> ChainStep {
        angleIfNeeded()
        guard let token = cur else { return .end }
        let spelling = op()
        if spelling == "." { return .member }
        if spelling == "?." { return .optional }
        if spelling == "[" { return .index }
        if spelling == "(" && calls { return .call }
        if isTemplateStart(token) { return .taggedTemplate }
        if ts && spelling == "!" && !newlineBefore { return .nonNull }
        if ts && spelling == "<" && (calls ? typeArgumentsCall(at: 0) : typeArgumentsEnd(0) != nil) { return .typeArguments }
        return .end
    }

    /// `.x`, `?.x`, `[i]`, `` `tag` ``, TypeScript `!` and `<T>`, and with `calls`, `(…)`.
    func chain(from mark: TreeBuilder.Checkpoint, calls: Bool) {
        while true {
            switch chainStep(calls: calls) {
            case .member:
                start(JSKind.memberExpression, at: mark)
                bump()
                memberName()
            case .optional:
                start(calls && atSym("(", 2) ? JSKind.callExpression : JSKind.memberExpression, at: mark)
                bump("?.")
                if atSym("(") {
                    arguments()
                } else if atSym("[") {
                    bump()
                    expression()
                    expect("]")
                } else {
                    memberName()
                }
            case .index:
                start(JSKind.subscriptExpression, at: mark)
                bump()
                expression()
                expect("]")
            case .call:
                start(JSKind.callExpression, at: mark)
                arguments()
            case .taggedTemplate:
                start(JSKind.callExpression, at: mark)
                template()
            case .nonNull:
                start(JSKind.nonNullExpression, at: mark)
                bump()
            case .typeArguments:
                start(calls ? JSKind.callExpression : JSKind.memberExpression, at: mark)
                typeArguments()
                if calls {
                    if atSym("(") { arguments() } else if isTemplateStart(cur) { template() }
                }
            case .end:
                return
            }
            finish()
        }
    }

    @inline(never)
    func memberName() {
        if atSym("#") {
            bump()
            if isWordLike(cur) { bump() }
        } else if isWordLike(cur) {
            bump()
        } else {
            error("expected a property name")
        }
    }

    func newExpression() {
        if atSym(".", 1) {
            start(JSKind.metaProperty)
            bump()
            bump()
            if isWordLike(cur) { bump() } else { error("expected `target`") }
            return finish()
        }
        start(JSKind.newExpression)
        bump()
        if !tooDeep() {
            let mark = checkpoint()
            if atWord("new") { newExpression() } else { primary() }
            chain(from: mark, calls: false)
            if atSym("(") { arguments() }
        }
        finish()
    }

    func arguments() {
        start(JSKind.arguments)
        bump()
        while !isAtEnd && !atCloser {
            let before = consumed
            if atOp("...") {
                start(JSKind.spreadElement)
                bump("...")
                assignment()
                finish()
            } else {
                assignment()
            }
            if consumed == before { errorAndBump("expected an argument") }
            if !separator() { break }
        }
        expect(")")
        finish()
    }

    /// After a list item: consumes a `,` and says to go on; at a closer, says to stop; otherwise
    /// records an error and skips to the next `,`.
    func separator() -> Bool {
        if atSym(",") {
            bump()
            return true
        }
        if atCloser || isAtEnd { return false }
        recover("expected `,`", until: [",", ";"])
        guard atSym(",") else { return false }
        bump()
        return true
    }

    enum PrimaryStart {
        case token, string, template, parenthesized, array, object, privateName, decoratedClass
        case function, classExpression, new, identifier, jsx, missing
    }

    /// What the primary expression at the next token is. A `/` the lexer took for division is
    /// re-lexed as a regex first, since an operand starts here.
    @inline(never)
    func primaryStart() -> PrimaryStart {
        if jsx && atJSXElement { return .jsx }
        if atSym("/") { relex(.regex) }
        guard let token = cur else { return .missing }
        switch token.kind {
        case .lexeme:
            switch token.scope {
            case "string.regexp", "constant.numeric", "constant.language", "variable.language": return .token
            case "string.quoted": return isTemplateStart(token) ? .template : .string
            case "entity.other.attribute": return .decoratedClass
            case "keyword", "entity.name.type", "entity.name.function": break
            default: return .missing
            }
        case .word: break
        case .symbol:
            switch text(token) {
            case "(": return .parenthesized
            case "[": return .array
            case "{": return .object
            case "#": return .privateName
            case "@": return .decoratedClass
            default: return .missing
            }
        default: return .missing
        }
        switch text(token) {
        case "function": return .function
        case "async" where atWord("function", 1) && !newlineBetween(0, 1): return .function
        case "class": return .classExpression
        case "import", "super", "this": return .token
        case "new": return .new
        default: break
        }
        guard isIdentifier() else { return .missing }
        // The lexer reads a keyword-like word and a `/` after it as one regex rule (`of / 2`).
        if isLexeme(token, "keyword"), let next = tok(1), isLexeme(next, "string.regexp"), text(next).hasPrefix("/"),
           !newlineBetween(0, 1) {
            relex(.identifier)
        }
        return .identifier
    }

    func primary() {
        switch primaryStart() {
        case .token: bump()
        case .string: string()
        case .template: template()
        case .parenthesized: parenthesizedExpression()
        case .array: array()
        case .object: object()
        case .privateName:
            // `#field in object`
            start(JSKind.propertyName)
            bump()
            if isWordLike(cur) { bump() }
            finish()
        case .decoratedClass:
            decorators()
            if atWord("class") { classDeclaration(JSKind.classExpression) } else { error("expected `class`") }
        case .function: function(JSKind.functionExpression)
        case .classExpression: classDeclaration(JSKind.classExpression)
        case .new: newExpression()
        case .identifier: wrap(JSKind.identifier)
        case .jsx: jsxRoot()
        case .missing: error("expected an expression")
        }
    }

    func parenthesizedExpression() {
        let mark = checkpoint()
        start(JSKind.parenthesizedExpression)
        bump()
        if atSym(")") { error("expected an expression") } else { expression() }
        expect(")")
        finish()
        // Parameters too long for the arrow scan to see past still make an arrow function.
        if arrow(at: 0) {
            start(JSKind.arrowFunction, at: mark)
            bump("=>")
            arrowBody(noIn: false)
            finish()
        }
    }

    func array() {
        start(JSKind.array)
        bump()
        while !isAtEnd && !atCloser {
            if atSym(",") {
                bump()
                continue
            }
            let before = consumed
            if atOp("...") {
                start(JSKind.spreadElement)
                bump("...")
                assignment()
                finish()
            } else {
                assignment()
            }
            if consumed == before { errorAndBump("expected an element") }
            if !separator() { break }
        }
        expect("]")
        finish()
    }

    // MARK: Literals

    /// A `'…'` or `"…"` string: its pieces, escapes between them, and a backslash line continuation.
    func string() {
        guard let opener = cur else { return }
        start(JSKind.string)
        let first = Array(text(opener).utf16)
        let quote = first[0]
        bump()
        var closed = first.count > 1 && first.last == quote
        var continued = false
        while !closed, let token = cur, isLexeme(token, "string.quoted") || isLexeme(token, "constant.character.escape"),
              token.location == lastEnd || continued {
            let piece = Array(text(token).utf16)
            continued = token.scope == "constant.character.escape" && piece == [92]
            bump()
            if token.scope == "string.quoted" && piece.last == quote { closed = true }
        }
        finish()
    }

    /// A template literal; each `${…}` holds an expression, or a type in a template literal type.
    func template(inType: Bool = false) {
        guard let opener = cur else { return }
        start(inType ? JSKind.templateLiteralType : JSKind.templateString)
        let first = Array(text(opener).utf16)
        bump()
        var closed = first.count > 1 && first.last == 96
        while !closed, let token = cur {
            if isLexeme(token, "string.quoted") || isLexeme(token, "constant.character.escape") {
                let piece = text(token)
                bump()
                if token.scope == "string.quoted" && piece.hasSuffix("`") { closed = true }
            } else if isEmbedded(token, "$") && isEmbedded(tok(1), "{") {
                start(JSKind.templateSubstitution)
                bump()
                bump()
                if !isEmbedded(cur, "}") {
                    if inType { type() } else { expression() }
                }
                if !isEmbedded(cur, "}") { recover("expected `}`", until: ["}"]) }
                if isEmbedded(cur, "}") { bump() }
                finish()
            } else {
                break
            }
        }
        finish()
    }

    // MARK: Objects

    /// `{ key: value, … }`: a reparse boundary.
    func object() {
        start(JSKind.object)
        expect("{")
        while !isAtEnd && !atCloser {
            let before = consumed
            objectMember()
            if consumed == before { errorAndBump("expected a property") }
            if !separator() { break }
        }
        expect("}")
        finish()
    }

    func objectMember() {
        if atOp("...") {
            start(JSKind.spreadElement)
            bump("...")
            assignment()
            return finish()
        }
        let mark = checkpoint()
        let method = memberModifiers(inClass: false)
        let shorthand = propertyKey(method: method, inClass: false)
        if atSym("(") || (ts && atSym("<")) || method {
            start(JSKind.methodDefinition, at: mark)
            functionRest()
        } else if atSym(":") {
            start(JSKind.pair, at: mark)
            bump()
            assignment()
        } else if shorthand {
            start(JSKind.shorthandProperty, at: mark)
            if atOp("=") {
                // `{ a = 1 } = value`: a default, valid only once this turns out to be a pattern.
                bump()
                assignment()
            }
        } else {
            return error("expected `:`")
        }
        finish()
    }

    static let classModifiers: Set<String> = ["static", "public", "private", "protected", "readonly", "abstract",
                                              "override", "declare", "accessor", "async", "get", "set"]

    /// The words before a member's name that modify it (`static`, `get`, `async`…) and a `*`. A word
    /// is a modifier only if a name follows, so `get() {}` and `{ async: 1 }` name a member `get`
    /// and `async`. Returns whether they make the member a method.
    func memberModifiers(inClass: Bool) -> Bool {
        var method = false
        while let name = word() {
            let allowed = inClass ? Self.classModifiers.contains(name) : (name == "async" || name == "get" || name == "set")
            guard allowed, startsMemberName(1) else { break }
            let accessorLike = name == "async" || name == "get" || name == "set"
            if accessorLike && newlineBetween(0, 1) { break }
            if !inClass && name != "async" && atSym("*", 1) { break }
            if accessorLike { method = true }
            bump()
        }
        if atSym("*") {
            bump()
            method = true
        }
        return method
    }

    func startsMemberName(_ offset: Int) -> Bool {
        guard let token = tok(offset) else { return false }
        return isWordLike(token) || isStringStart(token) || isLexeme(token, "constant.numeric")
            || atSym("[", offset) || atSym("#", offset) || atSym("*", offset)
    }

    /// A member's name: wrapped as a method's name when parameters follow, a variable when it is an
    /// object's shorthand `{ a }`, else a property's. Returns whether it was shorthand.
    @discardableResult
    func propertyKey(method: Bool, inClass: Bool) -> Bool {
        guard let token = cur else {
            error("expected a property name")
            return false
        }
        if isStringStart(token) {
            string()
        } else if isLexeme(token, "constant.numeric") {
            bump()
        } else if atSym("[") {
            computedPropertyName()
        } else if atSym("#") || isWordLike(token) {
            let nameLength = atSym("#") ? 2 : 1
            let callsNext = atSym("(", nameLength) || (ts && atSym("<", nameLength))
                || (ts && atSym("?", nameLength) && (atSym("(", nameLength + 1) || atSym("<", nameLength + 1)))
            if method || callsNext {
                start(JSKind.methodName)
            } else if !inClass && nameLength == 1 && !atSym(":", 1) && isIdentifier() {
                wrap(JSKind.identifier)
                return true
            } else {
                start(JSKind.propertyName)
            }
            bump()
            if nameLength == 2 && isWordLike(cur) { bump() }
            finish()
        } else {
            error("expected a property name")
        }
        return false
    }

    func computedPropertyName() {
        start(JSKind.computedPropertyName)
        bump()
        assignment()
        expect("]")
        finish()
    }

    // MARK: Patterns

    /// A name or a destructuring pattern being declared.
    func bindingTarget() {
        if atSym("{") {
            objectPattern()
        } else if atSym("[") {
            arrayPattern()
        } else if isIdentifier() {
            wrap(JSKind.binding)
        } else {
            error("expected a name")
        }
    }

    /// A target with an optional `= default`.
    func bindingElement() {
        let mark = checkpoint()
        bindingTarget()
        if atOp("=") {
            start(JSKind.assignmentPattern, at: mark)
            bump()
            assignment()
            finish()
        }
    }

    func objectPattern() {
        if tooDeep() { return }
        start(JSKind.objectPattern)
        bump()
        while !isAtEnd && !atCloser {
            let before = consumed
            if atOp("...") {
                start(JSKind.restPattern)
                bump("...")
                bindingTarget()
                finish()
            } else if isIdentifier() && !atSym(":", 1) {
                bindingElement()
            } else {
                start(JSKind.patternPair)
                if isStringStart(cur) {
                    string()
                } else if isLexeme(cur, "constant.numeric") {
                    bump()
                } else if atSym("[") {
                    computedPropertyName()
                } else if isWordLike(cur) {
                    wrap(JSKind.propertyName)
                }
                if expect(":") { bindingElement() }
                finish()
            }
            if consumed == before { errorAndBump("expected a property") }
            if !separator() { break }
        }
        expect("}")
        finish()
    }

    func arrayPattern() {
        if tooDeep() { return }
        start(JSKind.arrayPattern)
        bump()
        while !isAtEnd && !atCloser {
            if atSym(",") {
                bump()
                continue
            }
            let before = consumed
            if atOp("...") {
                start(JSKind.restPattern)
                bump("...")
                bindingTarget()
                finish()
            } else {
                bindingElement()
            }
            if consumed == before { errorAndBump("expected an element") }
            if !separator() { break }
        }
        expect("]")
        finish()
    }
}
