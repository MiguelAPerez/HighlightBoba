import Foundation

extension JSParse {
    func program() {
        while !isAtEnd {
            if atCloser {
                errorAndBump("unexpected `\(text(cur!))`")
                continue
            }
            statementMakingProgress()
        }
    }

    /// A statement that consumes at least one token, so a loop around it always advances.
    func statementMakingProgress() {
        let before = consumed
        statement()
        if consumed == before, let token = cur { errorAndBump("unexpected `\(text(token))`") }
    }

    /// `{ statements }`: a reparse boundary.
    func block() {
        start(JSKind.statementBlock)
        expect("{")
        statements()
        expect("}")
        finish()
    }

    /// Statements up to the `}` (or other closer) that ends them.
    func statements() {
        while !isAtEnd && !atCloser { statementMakingProgress() }
    }

    /// What a statement starting at the next token is. Deciding it is kept out of `statement()`
    /// so the recursive functions' stack frames stay small (see `JSParse.maxDepth`).
    enum StatementStart {
        case block, empty, decorators, variable, constEnum, function, classDeclaration, ifStatement, forStatement
        case whileStatement, doStatement, returnStatement, throwStatement, breakStatement, continueStatement
        case tryStatement, switchStatement, debugger, with, importStatement, exportStatement, typeScript, labeled
        case expression
    }

    @inline(never)
    func statementStart() -> StatementStart {
        guard let token = cur else { return .expression }
        if atSym("{") { return .block }
        if atSym(";") { return .empty }
        if atDecorator { return .decorators }
        guard isWordLike(token) else { return .expression }
        switch text(token) {
        case "var": return .variable
        case "const": return ts && atWord("enum", 1) ? .constEnum : .variable
        case "let" where isIdentifier(1) || atSym("[", 1) || atSym("{", 1): return .variable
        case "function": return .function
        case "async" where atWord("function", 1) && !newlineBetween(0, 1): return .function
        case "class": return .classDeclaration
        case "if": return .ifStatement
        case "for": return .forStatement
        case "while": return .whileStatement
        case "do": return .doStatement
        case "return": return .returnStatement
        case "throw": return .throwStatement
        case "break": return .breakStatement
        case "continue": return .continueStatement
        case "try": return .tryStatement
        case "switch": return .switchStatement
        case "debugger": return .debugger
        case "with": return .with
        case "import" where !atSym("(", 1) && !atSym(".", 1): return .importStatement
        case "export": return .exportStatement
        default: break
        }
        if ts && startsTypeScriptDeclaration() { return .typeScript }
        if isIdentifier() && atSym(":", 1) { return .labeled }
        return .expression
    }

    func statement() {
        if cur == nil || tooDeep() { return }
        switch statementStart() {
        case .block: block()
        case .empty: wrap(JSKind.emptyStatement)
        case .decorators:
            decorators()
            statement()
        case .variable: variableDeclaration()
        case .constEnum: enumDeclaration()
        case .function: function(JSKind.functionDeclaration)
        case .classDeclaration: classDeclaration(JSKind.classDeclaration)
        case .ifStatement: ifStatement()
        case .forStatement: forStatement()
        case .whileStatement: whileStatement()
        case .doStatement: doStatement()
        case .returnStatement: returnOrThrow(JSKind.returnStatement)
        case .throwStatement: returnOrThrow(JSKind.throwStatement)
        case .breakStatement: jump(JSKind.breakStatement)
        case .continueStatement: jump(JSKind.continueStatement)
        case .tryStatement: tryStatement()
        case .switchStatement: switchStatement()
        case .debugger:
            start(JSKind.debuggerStatement)
            bump()
            semicolon()
            finish()
        case .with:
            start(JSKind.withStatement)
            bump()
            parenthesized()
            statement()
            finish()
        case .importStatement: importStatement()
        case .exportStatement: exportStatement()
        case .typeScript: typeScriptDeclaration()
        case .labeled: labeledStatement()
        case .expression: expressionStatement()
        }
    }

    @inline(never)
    func newlineBetween(_ first: Int, _ second: Int) -> Bool {
        guard let a = tok(first), let b = tok(second) else { return false }
        return hasNewline(from: a.end, to: b.location)
    }

    func expressionStatement() {
        start(JSKind.expressionStatement)
        expression()
        semicolon()
        finish()
    }

    func labeledStatement() {
        start(JSKind.labeledStatement)
        wrap(JSKind.label)
        bump()
        statement()
        finish()
    }

    /// `var`, `let` or `const` and its declarators. In a `for` head the caller ends it, and `in`
    /// isn't an operator in its initialisers.
    func variableDeclaration(inFor: Bool = false) {
        start(JSKind.variableDeclaration)
        bump()
        repeat {
            start(JSKind.variableDeclarator)
            bindingTarget()
            if ts && atSym("!") { bump() }
            if ts && atSym(":") { typeAnnotation() }
            if atOp("=") {
                bump()
                assignment(noIn: inFor)
            }
            finish()
        } while atSym(",") && { bump(); return true }()
        if !inFor { semicolon() }
        finish()
    }

    func parenthesized() {
        expect("(")
        expression()
        expect(")")
    }

    func ifStatement() {
        start(JSKind.ifStatement)
        bump()
        parenthesized()
        statement()
        if atWord("else") {
            start(JSKind.elseClause)
            bump()
            statement()
            finish()
        }
        finish()
    }

    func forStatement() {
        let mark = checkpoint()
        bump()
        if atWord("await") { bump() }
        expect("(")
        var kind = JSKind.forStatement
        if atSym(";") {
            // No initialiser.
        } else if atWord("var") || atWord("const") || (atWord("let") && (isIdentifier(1) || atSym("[", 1) || atSym("{", 1))) {
            variableDeclaration(inFor: true)
        } else {
            expression(noIn: true)
        }
        if atWord("of") || atWord("in") {
            kind = JSKind.forInStatement
            let of = atWord("of")
            bump()
            if of { assignment() } else { expression() }
        } else {
            expect(";")
            if !atSym(";") { expression() }
            expect(";")
            if !atSym(")") { expression() }
        }
        expect(")")
        statement()
        start(kind, at: mark)
        finish()
    }

    func whileStatement() {
        start(JSKind.whileStatement)
        bump()
        parenthesized()
        statement()
        finish()
    }

    func doStatement() {
        start(JSKind.doStatement)
        bump()
        statement()
        expectWord("while")
        parenthesized()
        if atSym(";") { bump() }
        finish()
    }

    /// `return` and `throw`: an expression unless the statement ends first (a line break ends `return`).
    func returnOrThrow(_ kind: SyntaxKind) {
        start(kind)
        bump()
        if !atSym(";") && !atCloseBrace && !isAtEnd && !newlineBefore { expression() }
        semicolon()
        finish()
    }

    /// `break` and `continue`, with a label on the same line.
    func jump(_ kind: SyntaxKind) {
        start(kind)
        bump()
        if isIdentifier() && !newlineBefore { wrap(JSKind.label) }
        semicolon()
        finish()
    }

    func tryStatement() {
        start(JSKind.tryStatement)
        bump()
        block()
        if atWord("catch") {
            start(JSKind.catchClause)
            bump()
            if atSym("(") {
                bump()
                bindingTarget()
                if ts && atSym(":") { typeAnnotation() }
                expect(")")
            }
            block()
            finish()
        }
        if atWord("finally") {
            start(JSKind.finallyClause)
            bump()
            block()
            finish()
        }
        finish()
    }

    func switchStatement() {
        start(JSKind.switchStatement)
        bump()
        parenthesized()
        switchBody()
        finish()
    }

    /// `{ case …: … default: … }`: a reparse boundary.
    func switchBody() {
        start(JSKind.switchBody)
        expect("{")
        while !isAtEnd && !atCloser {
            guard atWord("case") || atWord("default") else {
                errorAndBump("expected `case` or `default`")
                continue
            }
            start(JSKind.switchCase)
            if atWord("case") {
                bump()
                expression()
            } else {
                bump()
            }
            expect(":")
            while !isAtEnd && !atCloser && !atWord("case") && !atWord("default") { statementMakingProgress() }
            finish()
        }
        expect("}")
        finish()
    }

    // MARK: Modules

    func importStatement() {
        start(JSKind.importStatement)
        bump()
        if ts && atWord("type") && (atSym("{", 1) || atSym("*", 1) || (isIdentifier(1) && !atWord("from", 1))) { bump() }
        if isStringStart(cur) {
            string()
        } else {
            if isIdentifier() {
                wrap(JSKind.binding)
                if ts && atOp("=") {
                    // `import fs = require("fs")`, `import A = B.C`
                    start(JSKind.importAlias)
                    bump()
                    leftHandSide()
                    finish()
                    semicolon()
                    return finish()
                }
                if atSym(",") { bump() }
            }
            if atSym("*") {
                start(JSKind.namespaceImport)
                bump()
                expectWord("as")
                if isIdentifier() { wrap(JSKind.binding) } else { error("expected a name") }
                finish()
            } else if atSym("{") {
                namedImports()
            }
            expectWord("from")
            if isStringStart(cur) { string() } else { error("expected a module name") }
        }
        importAttributes()
        semicolon()
        finish()
    }

    func importAttributes() {
        if (atWord("with") || atWord("assert")) && atSym("{", 1) && !newlineBefore {
            bump()
            object()
        }
    }

    func namedImports() {
        start(JSKind.namedImports)
        bump()
        while !isAtEnd && !atCloser {
            start(JSKind.importSpecifier)
            if ts && atWord("type") && (isWordLike(tok(1)) || isStringStart(tok(1))) && !atWord("as", 1) { bump() }
            if atWord("as", 1) || isStringStart(cur) {
                if isStringStart(cur) { string() } else { bump() }
                expectWord("as")
                if isIdentifier() { wrap(JSKind.binding) } else { error("expected a name") }
            } else if isIdentifier() {
                wrap(JSKind.binding)
            } else if !atSym(",") {
                errorAndBump("expected a name")
            }
            finish()
            if atSym(",") { bump() } else { break }
        }
        expect("}")
        finish()
    }

    func exportStatement() {
        start(JSKind.exportStatement)
        bump()
        if atWord("default") {
            bump()
            if atDecorator { decorators() }
            if atWord("function") || (atWord("async") && atWord("function", 1) && !newlineBetween(0, 1)) {
                function(JSKind.functionDeclaration)
            } else if atWord("class") || (ts && atWord("abstract") && atWord("class", 1)) {
                classDeclaration(JSKind.classDeclaration)
            } else if ts && atWord("interface") && isIdentifier(1) {
                interfaceDeclaration()
            } else {
                assignment()
                semicolon()
            }
        } else if atSym("*") {
            bump()
            if atWord("as") {
                bump()
                if isStringStart(cur) { string() } else { bump() }
            }
            expectWord("from")
            if isStringStart(cur) { string() } else { error("expected a module name") }
            importAttributes()
            semicolon()
        } else if atSym("{") || (ts && atWord("type") && atSym("{", 1)) {
            if atWord("type") { bump() }
            exportClause()
            if atWord("from") {
                bump()
                if isStringStart(cur) { string() } else { error("expected a module name") }
                importAttributes()
            }
            semicolon()
        } else if ts && atOp("=") {
            bump()
            expression()
            semicolon()
        } else if ts && atWord("as") && atWord("namespace", 1) {
            bump()
            bump()
            if isIdentifier() { wrap(JSKind.typeName) } else { error("expected a name") }
            semicolon()
        } else if ts && atWord("import") {
            importStatement()
        } else {
            if atDecorator { decorators() }
            statement()
        }
        finish()
    }

    func exportClause() {
        start(JSKind.exportClause)
        bump()
        while !isAtEnd && !atCloser {
            start(JSKind.exportSpecifier)
            if ts && atWord("type") && isWordLike(tok(1)) && !atWord("as", 1) { bump() }
            if isStringStart(cur) {
                string()
            } else if isWordLike(cur) {
                if atWord("as", 1) { bump() } else { wrap(JSKind.identifier) }
            } else if !atSym(",") {
                errorAndBump("expected a name")
            }
            if atWord("as") {
                bump()
                if isStringStart(cur) { string() } else if isWordLike(cur) { bump() } else { error("expected a name") }
            }
            finish()
            if atSym(",") { bump() } else { break }
        }
        expect("}")
        finish()
    }

    // MARK: TypeScript declarations

    /// Whether a TypeScript-only declaration starts here: `type X =`, `interface X`, `declare …`.
    func startsTypeScriptDeclaration() -> Bool {
        guard let name = word() else { return false }
        let sameLine = !newlineBetween(0, 1)
        switch name {
        case "type": return isIdentifier(1) && sameLine
        case "interface": return isIdentifier(1) && sameLine
        case "enum": return isIdentifier(1)
        case "namespace": return isIdentifier(1) && sameLine
        case "module": return (isIdentifier(1) || isStringStart(tok(1))) && sameLine
        case "abstract": return atWord("class", 1) && sameLine
        case "global": return atSym("{", 1)
        case "declare": return sameLine && (isWordLike(tok(1)) && !atWord("in", 1) && !atWord("instanceof", 1))
        default: return false
        }
    }

    func typeScriptDeclaration() {
        switch word() {
        case "type": typeAlias()
        case "interface": interfaceDeclaration()
        case "enum": enumDeclaration()
        case "namespace", "module", "global": moduleDeclaration()
        case "abstract": classDeclaration(JSKind.classDeclaration)
        case "declare":
            start(JSKind.ambientDeclaration)
            bump()
            statement()
            finish()
        default: expressionStatement()
        }
    }

    func typeAlias() {
        start(JSKind.typeAliasDeclaration)
        bump()
        wrap(JSKind.typeName)
        if atSym("<") { typeParameters() }
        if atOp("=") { bump() } else { error("expected `=`") }
        type()
        semicolon()
        finish()
    }

    func interfaceDeclaration() {
        start(JSKind.interfaceDeclaration)
        bump()
        wrap(JSKind.typeName)
        if atSym("<") { typeParameters() }
        if atWord("extends") {
            start(JSKind.extendsClause)
            bump()
            typeList()
            finish()
        }
        if atSym("{") { objectType() } else { error("expected `{`") }
        finish()
    }

    /// Types separated by commas: `extends A, B<C>`, `implements I`.
    func typeList() {
        repeat { type() } while atSym(",") && { bump(); return true }()
    }

    func enumDeclaration() {
        start(JSKind.enumDeclaration)
        if atWord("const") { bump() }
        bump()
        if isIdentifier() { wrap(JSKind.typeName) } else { error("expected a name") }
        if atSym("{") { enumBody() } else { error("expected `{`") }
        finish()
    }

    /// `{ A = 1, B, "C" }`: a reparse boundary.
    func enumBody() {
        start(JSKind.enumBody)
        expect("{")
        while !isAtEnd && !atCloser {
            start(JSKind.enumMember)
            if isStringStart(cur) {
                string()
            } else if isWordLike(cur) {
                wrap(JSKind.propertyName)
            } else if atSym("[") {
                computedPropertyName()
            } else {
                errorAndBump("expected an enum member")
            }
            if atOp("=") {
                bump()
                assignment()
            }
            finish()
            if atSym(",") { bump() } else if !atCloser && !newlineBefore { error("expected `,`") }
        }
        expect("}")
        finish()
    }

    /// `namespace A.B { … }`, `module "m" { … }`, `global { … }`.
    func moduleDeclaration() {
        start(JSKind.moduleDeclaration)
        let global = atWord("global")
        bump()
        if !global {
            if isStringStart(cur) {
                string()
            } else {
                wrap(JSKind.typeName)
                while atSym("."), isWordLike(tok(1)) {
                    bump()
                    wrap(JSKind.typeName)
                }
            }
        }
        if atSym("{") { block() } else { semicolon() }
        finish()
    }
}
