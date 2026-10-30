import Foundation

extension JSParse {
    // MARK: Functions

    /// `[async] function [*] [name] (…) { … }`, as a declaration or an expression.
    func function(_ kind: SyntaxKind) {
        start(kind)
        if atWord("async") { bump() }
        bump()
        if atSym("*") { bump() }
        if isWordLike(cur) { wrap(JSKind.functionName) }
        functionRest()
        finish()
    }

    /// What follows a function's or method's name: type parameters, parameters, return type and body.
    /// A TypeScript overload, or an abstract or ambient one, has no body.
    func functionRest() {
        if ts && atSym("<") { typeParameters() }
        if atSym("(") { formalParameters() } else { error("expected `(`") }
        if ts && atSym(":") { returnType() }
        if atSym("{") { block() } else { semicolon() }
    }

    func formalParameters() {
        start(JSKind.formalParameters)
        bump()
        while !isAtEnd && !atCloser {
            let before = consumed
            parameter()
            if consumed == before { errorAndBump("expected a parameter") }
            if !separator() { break }
        }
        expect(")")
        finish()
    }

    static let parameterModifiers: Set<String> = ["public", "private", "protected", "readonly", "override"]

    func parameter() {
        start(JSKind.parameter)
        if atDecorator { decorators() }
        if ts {
            while let name = word(), Self.parameterModifiers.contains(name), isIdentifier(1) || atSym("{", 1) || atSym("[", 1) { bump() }
        }
        if atOp("...") { bump("...") }
        if ts && atWord("this") { bump() } else { bindingTarget() }
        if ts && atSym("?") { bump() }
        if ts && atSym(":") { typeAnnotation() }
        if atOp("=") {
            bump()
            assignment()
        }
        finish()
    }

    // MARK: Decorators

    var atDecorator: Bool { isLexeme(cur, "entity.other.attribute") || atSym("@") }

    func decorators() {
        while atDecorator { decorator() }
    }

    /// `@name`, `@a.b`, `@call(…)`. The lexer reads `@a.b` as one token when it can.
    func decorator() {
        start(JSKind.decorator)
        if atSym("@") {
            bump()
            if atSym("(") {
                parenthesizedExpression()
            } else if isWordLike(cur) {
                bump()
                while atSym("."), isWordLike(tok(1)) {
                    bump()
                    bump()
                }
            } else {
                error("expected a decorator")
            }
        } else {
            bump()
        }
        if atSym("(") && !newlineBefore { arguments() }
        finish()
    }

    // MARK: Classes

    func classDeclaration(_ kind: SyntaxKind) {
        start(kind)
        if atWord("abstract") { bump() }
        expectWord("class")
        if isIdentifier() && !atWord("extends") && !atWord("implements") { wrap(JSKind.typeName) }
        if ts && atSym("<") { typeParameters() }
        if atWord("extends") {
            start(JSKind.classHeritage)
            bump()
            leftHandSide()
            if ts && atSym("<") { typeArguments() }
            finish()
        }
        if ts && atWord("implements") {
            start(JSKind.implementsClause)
            bump()
            typeList()
            finish()
        }
        if atSym("{") { classBody() } else { error("expected `{`") }
        finish()
    }

    /// `{ members }`: a reparse boundary.
    func classBody() {
        start(JSKind.classBody)
        expect("{")
        while !isAtEnd && !atCloser {
            if atSym(";") {
                bump()
                continue
            }
            let before = consumed
            classMember()
            if consumed == before { errorAndBump("expected a class member") }
        }
        expect("}")
        finish()
    }

    func classMember() {
        if atDecorator { decorators() }
        if atWord("static") && atSym("{", 1) {
            start(JSKind.classStaticBlock)
            bump()
            block()
            return finish()
        }
        let mark = checkpoint()
        let method = memberModifiers(inClass: true)
        if ts && atSym("[") && isIdentifier(1) && atSym(":", 2) {
            start(JSKind.indexSignature, at: mark)
            indexSignatureRest()
            semicolon()
            return finish()
        }
        propertyKey(method: method, inClass: true)
        if ts && (atSym("?") || atOp("!")) { bump() }
        if atSym("(") || (ts && atSym("<")) || method {
            start(JSKind.methodDefinition, at: mark)
            functionRest()
            return finish()
        }
        start(JSKind.fieldDefinition, at: mark)
        if ts && atSym(":") { typeAnnotation() }
        if atOp("=") {
            bump()
            assignment()
        }
        semicolon()
        finish()
    }

    /// `[key: string]: T` after its modifiers.
    func indexSignatureRest() {
        bump()
        wrap(JSKind.binding)
        typeAnnotation()
        expect("]")
        if atSym("?") { bump() }
        if atSym(":") { typeAnnotation() }
    }

    // MARK: Types

    func typeAnnotation() {
        start(JSKind.typeAnnotation)
        bump()
        type()
        finish()
    }

    /// `: T` after parameters, which may be a predicate: `x is T`, `asserts x`, `asserts this is T`.
    func returnType() {
        start(JSKind.typeAnnotation)
        bump()
        typeOrPredicate()
        finish()
    }

    func typeOrPredicate() {
        let subject = isIdentifier(1) || atWord("this", 1)
        if atWord("asserts") && subject && !newlineBetween(0, 1) {
            start(JSKind.typePredicate)
            bump()
            if atWord("this") { bump() } else { wrap(JSKind.identifier) }
            if atWord("is") {
                bump()
                type()
            }
            finish()
        } else if (isIdentifier() || atWord("this")) && atWord("is", 1) && !newlineBetween(0, 1) {
            start(JSKind.typePredicate)
            if atWord("this") { bump() } else { wrap(JSKind.identifier) }
            bump()
            type()
            finish()
        } else {
            type()
        }
    }

    /// A type. `noConditional` reads `A extends B` without the `? :` (the check of a conditional type).
    func type(noConditional: Bool = false) {
        if tooDeep() { return }
        if atSym("<") || (atSym("(") && arrowFollows(parenAt: 0)) { return functionType(JSKind.functionType) }
        if atWord("new") || (atWord("abstract") && atWord("new", 1)) { return functionType(JSKind.constructorType) }
        let mark = checkpoint()
        unionType()
        if !noConditional && atWord("extends") && !newlineBefore {
            start(JSKind.conditionalType, at: mark)
            bump()
            type(noConditional: true)
            expect("?")
            type()
            expect(":")
            type()
            finish()
        }
    }

    func functionType(_ kind: SyntaxKind) {
        start(kind)
        if atWord("abstract") { bump() }
        if atWord("new") { bump() }
        if atSym("<") { typeParameters() }
        if atSym("(") { formalParameters() } else { error("expected `(`") }
        if bump("=>") { typeOrPredicate() } else { error("expected `=>`") }
        finish()
    }

    func unionType() { joinedTypes(JSKind.unionType, "|", element: intersectionType) }

    func intersectionType() { joinedTypes(JSKind.intersectionType, "&", element: typeOperatorType) }

    /// `A | B | C`, with an optional leading `|`.
    private func joinedTypes(_ kind: SyntaxKind, _ separator: String, element: () -> Void) {
        let mark = checkpoint()
        if atSym(separator) { bump() }
        element()
        guard atSym(separator) else { return }
        start(kind, at: mark)
        while atSym(separator) {
            bump()
            element()
        }
        finish()
    }

    func typeOperatorType() {
        if tooDeep() { return }
        if let name = word(), name == "keyof" || name == "unique" || name == "readonly", startsType(1) {
            start(JSKind.typeOperator)
            bump()
            typeOperatorType()
            return finish()
        }
        if atWord("infer") && isIdentifier(1) {
            start(JSKind.inferType)
            bump()
            wrap(JSKind.typeName)
            return finish()
        }
        let mark = checkpoint()
        primaryType()
        while atSym("[") && !newlineBefore {
            if atSym("]", 1) {
                start(JSKind.arrayType, at: mark)
                bump()
                bump()
            } else {
                start(JSKind.indexedAccessType, at: mark)
                bump()
                type()
                expect("]")
            }
            finish()
        }
    }

    func startsType(_ offset: Int) -> Bool {
        guard let token = tok(offset) else { return false }
        if token.kind == .symbol { return ["(", "[", "{", "<", "-"].contains(text(token)) }
        return isWordLike(token) || isLexeme(token, "string.quoted") || isLexeme(token, "constant.numeric")
    }

    func primaryType() {
        guard let token = cur else { return error("expected a type") }
        if atSym("(") {
            start(JSKind.parenthesizedType)
            bump()
            type()
            expect(")")
            return finish()
        }
        if atSym("[") { return tupleType() }
        if atSym("{") { return mappedTypeAhead() ? mappedType() : objectType() }
        if isTemplateStart(token) { return template(inType: true) }
        if isStringStart(token) {
            start(JSKind.literalType)
            string()
            return finish()
        }
        if isLexeme(token, "constant.numeric") || isLexeme(token, "constant.language") { return wrap(JSKind.literalType) }
        if atSym("-") && isLexeme(tok(1), "constant.numeric") {
            start(JSKind.literalType)
            bump()
            bump()
            return finish()
        }
        switch word() {
        case "typeof":
            start(JSKind.typeQuery)
            bump()
            if atWord("import") {
                importType()
            } else if isWordLike(cur) {
                if isIdentifier() { wrap(JSKind.identifier) } else { bump() }
                while atSym("."), isWordLike(tok(1)) {
                    bump()
                    bump()
                }
            } else {
                error("expected a name")
            }
            if atSym("<") && !newlineBefore { typeArguments() }
            return finish()
        case "import": return importType()
        case "this": return bump()
        default: break
        }
        guard isIdentifier() || atWord("void") else { return error("expected a type") }
        typeReference()
    }

    /// `T`, `ns.T`, `Map<K, V>`.
    func typeReference() {
        let mark = checkpoint()
        while atSym(".", 1), isWordLike(tok(2)) {
            bump()
            bump()
        }
        wrap(JSKind.typeIdentifier)
        if atSym("<") && !newlineBefore {
            start(JSKind.genericType, at: mark)
            typeArguments()
            finish()
        }
    }

    /// `import("module").Name<T>`.
    func importType() {
        start(JSKind.importType)
        bump()
        expect("(")
        if isStringStart(cur) { string() } else { error("expected a module name") }
        expect(")")
        while atSym("."), isWordLike(tok(1)) {
            bump()
            if atSym(".", 1) { bump() } else { wrap(JSKind.typeIdentifier) }
        }
        if atSym("<") && !newlineBefore { typeArguments() }
        finish()
    }

    func tupleType() {
        start(JSKind.tupleType)
        bump()
        while !isAtEnd && !atCloser {
            let before = consumed
            if atOp("...") { bump("...") }
            if isWordLike(cur) && (atSym(":", 1) || (atSym("?", 1) && atSym(":", 2))) {
                wrap(JSKind.propertyName)
                if atSym("?") { bump() }
                bump()
            }
            type()
            if atSym("?") { bump() }
            if consumed == before { errorAndBump("expected a type") }
            if !separator() { break }
        }
        expect("]")
        finish()
    }

    func mappedTypeAhead() -> Bool {
        var offset = 1
        if atSym("+", offset) || atSym("-", offset) { offset += 1 }
        if atWord("readonly", offset) { offset += 1 }
        return atSym("[", offset) && isWordLike(tok(offset + 1)) && atWord("in", offset + 2)
    }

    /// `{ readonly [K in keyof T]?: T[K] }`.
    func mappedType() {
        start(JSKind.mappedType)
        bump()
        if atSym("+") || atSym("-") { bump() }
        if atWord("readonly") { bump() }
        expect("[")
        wrap(JSKind.typeName)
        bump()
        type()
        if atWord("as") {
            bump()
            type()
        }
        expect("]")
        if atSym("+") || atSym("-") { bump() }
        if atSym("?") { bump() }
        if atSym(":") { typeAnnotation() }
        if atSym(";") || atSym(",") { bump() }
        expect("}")
        finish()
    }

    /// `{ members }` of an interface or an object type: a reparse boundary.
    func objectType() {
        start(JSKind.objectType)
        expect("{")
        while !isAtEnd && !atCloser {
            let before = consumed
            typeMember()
            if consumed == before { errorAndBump("expected a member") }
            if atSym(";") || atSym(",") {
                bump()
            } else if !atCloser && !isAtEnd && !newlineBefore {
                recover("expected `;`", until: [";", ","])
                if atSym(";") || atSym(",") { bump() }
            }
        }
        expect("}")
        finish()
    }

    func typeMember() {
        let mark = checkpoint()
        if atSym("(") || atSym("<") {
            start(JSKind.callSignature, at: mark)
            signatureRest()
            return finish()
        }
        if atWord("new") && (atSym("(", 1) || atSym("<", 1)) {
            start(JSKind.constructSignature, at: mark)
            bump()
            signatureRest()
            return finish()
        }
        var accessor = false
        while let name = word(), name == "readonly" || name == "get" || name == "set", startsMemberName(1), !newlineBetween(0, 1) {
            if name != "readonly" { accessor = true }
            bump()
        }
        if atSym("[") && isIdentifier(1) && atSym(":", 2) {
            start(JSKind.indexSignature, at: mark)
            indexSignatureRest()
            return finish()
        }
        propertyKey(method: accessor, inClass: true)
        if atSym("?") { bump() }
        if atSym("(") || atSym("<") {
            start(JSKind.methodSignature, at: mark)
            signatureRest()
            return finish()
        }
        start(JSKind.propertySignature, at: mark)
        if atSym(":") { typeAnnotation() }
        finish()
    }

    func signatureRest() {
        if atSym("<") { typeParameters() }
        if atSym("(") { formalParameters() } else { error("expected `(`") }
        if atSym(":") { returnType() }
    }

    /// `<T extends C = D, …>` where things are declared.
    func typeParameters() {
        start(JSKind.typeParameters)
        bump()
        while !isAtEnd && !atSym(">") && !atCloser {
            let before = consumed
            start(JSKind.typeParameter)
            while let name = word(), name == "const" || name == "in" || name == "out", isIdentifier(1) { bump() }
            if isIdentifier() { wrap(JSKind.typeName) } else { error("expected a type parameter") }
            if atWord("extends") {
                bump()
                type()
            }
            if atOp("=") {
                bump()
                type()
            }
            finish()
            if consumed == before { break }
            if atSym(",") { bump() } else { break }
        }
        closeAngle()
        finish()
    }

    /// `<A, B>` where types are applied.
    func typeArguments() {
        start(JSKind.typeArguments)
        bump()
        while !isAtEnd && !atSym(">") && !atCloser {
            let before = consumed
            type()
            if consumed == before { break }
            if atSym(",") { bump() } else { break }
        }
        closeAngle()
        finish()
    }

    /// One `>`: in `Array<Array<T>>` each `>` closes its own list, as the lexer leaves them separate.
    func closeAngle() {
        if atSym(">") { bump() } else { error("expected `>`") }
    }
}
