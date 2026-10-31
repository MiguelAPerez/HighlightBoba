import Foundation

/// JSX, in the `.jsx` and `.tsx` dialects.
///
/// The lexer guesses an element from the character before a `<`, as it guesses a regex from the
/// one before a `/`. The parser decides: where an expression starts, it re-lexes a `<` the lexer
/// left as an operator in the grammar's `jsxStart` state, and elsewhere it re-lexes a guessed one
/// as the operator (`angleIfNeeded`). From an element's `<`, the JSX states lex its tags,
/// attribute strings, entities and text, with `{ }` holding code again. A `<` inside that code is
/// another **root**.
///
/// The lexer's stack mirrors the elements: one state per open element, plus one for the tag being
/// read. When the parser ends elements the lexer still has open (a half-typed tag, a stray `}`, an
/// outer element's closing tag), it re-lexes the next token after popping them (`relexPopping`),
/// so the code after a broken element lexes as code again.
extension JSParse {
    /// Whether a JSX element starts here: a `<` the lexer read in its JSX states, or one it left
    /// as an operator, written against a name or `>`. JSX allows `< div>`, but a `<` and a space
    /// where an expression starts is far likelier a half-typed comparison than an element, and
    /// reading it as one would re-lex the rest of the file.
    var atJSXElement: Bool { jsxElementStart() }

    @inline(never)
    private func jsxElementStart() -> Bool {
        if jsxPunctuation("<") { return true }
        guard let angle = cur, atSym("<"), let next = tok(1), next.location == angle.end else { return false }
        return next.kind == .word || (next.kind == .lexeme && Self.wordScopes.contains(next.scope ?? "")) || atSym(">", 1)
    }

    /// A `<`, `/` or `>` the JSX states read as a tag's punctuation.
    @inline(never)
    func jsxPunctuation(_ spelling: String, _ offset: Int = 0) -> Bool {
        guard let token = tok(offset), isLexeme(token, "punctuation") else { return false }
        return text(token) == spelling
    }

    /// A JSX element where an expression starts. It begins a root: the elements nested in it by
    /// their tags, but not those in its `{ }` expressions, which are roots of their own.
    func jsxRoot() {
        if atSym("<") && !relex(.jsx) {
            // Out of re-lex budget: the lexer's reading stays, and so does `<` as an operator.
            return error("expected an expression")
        }
        _ = jsxElement(open: [])
    }

    enum JSXTagEnd { case open, selfClosing, broken }

    enum JSXChild { case closingTag, element, expression, strayBrace, text, end }

    /// An element from its `<`. `open` names the elements it is nested in within its root, outermost
    /// first. Returns whether it ended without its closing tag because something ends an element
    /// around it too (an outer closing tag, a stray `}`, the end of the text), so that one closes
    /// or unwinds in turn.
    func jsxElement(open: [String]) -> Bool {
        if tooDeep() { return false }
        start(JSKind.jsxElement)
        let tag = checkpoint()
        bump()
        let name = jsxNameNode(attribute: false) ?? ""
        if ts && !name.isEmpty && atSym("<") && cur?.location == lastEnd { typeArguments() }
        switch jsxAttributes() {
        case .selfClosing:
            start(JSKind.jsxSelfClosingTag, at: tag)
            bump()
            bump()
            finish()
            finish()
            return false
        case .broken:
            start(JSKind.jsxOpeningTag, at: tag)
            finish()
            finish()
            return false
        case .open:
            start(JSKind.jsxOpeningTag, at: tag)
            bump()
            finish()
        }
        let unwinding = jsxChildren(name: name, open: open)
        finish()
        return unwinding
    }

    /// The children of the element named `name`, up to and including its closing tag.
    func jsxChildren(name: String, open: [String]) -> Bool {
        while true {
            switch jsxChild() {
            case .text:
                jsxText()
            case .expression:
                jsxExpression()
            case .element:
                guard jsxElement(open: open + [name]) else { continue }
                // A child ended at something that closes an element around it; the lexer has
                // already been told.
                if jsxClosingTagNamed(name) {
                    jsxClosingTag()
                    return false
                }
                error("expected `</\(name)>`")
                return true
            case .closingTag:
                if jsxClosingTagNamed(name) {
                    jsxClosingTag()
                    return false
                }
                let closing = jsxClosingName()
                guard let outer = open.lastIndex(of: closing) else {
                    // It closes nothing open, so it closes this element, misspelt.
                    error("expected `</\(name)>`")
                    jsxClosingTag()
                    return false
                }
                // It closes an outer element: this one and those between are left unclosed.
                error("expected `</\(name)>`")
                relexPopping(open.count - outer)
                return true
            case .strayBrace:
                // `}` can't be JSX text, so the elements of this root were left unclosed, and the
                // `}` ends a block around them.
                error("expected `</\(name)>`")
                relexPopping(open.count + 1)
                return true
            case .end:
                error("expected `</\(name)>`")
                return true
            }
        }
    }

    @inline(never)
    func jsxChild() -> JSXChild {
        guard cur != nil else { return .end }
        if jsxPunctuation("<") {
            return jsxPunctuation("/", 1) && tok(1)?.location == cur?.end ? .closingTag : .element
        }
        if atSym("{") { return .expression }
        if atSym("}") { return .strayBrace }
        return .text
    }

    /// Text between tags, entities included.
    func jsxText() {
        start(JSKind.jsxText)
        while jsxChild() == .text { bump() }
        finish()
    }

    /// A tag's attributes, up to its `>` or `/>`. Anything else ends the tag there, and the lexer
    /// leaves the tag's state, so that token reads as what follows the element.
    func jsxAttributes() -> JSXTagEnd {
        while true {
            if jsxPunctuation(">") { return .open }
            if jsxPunctuation("/") && jsxPunctuation(">", 1) { return .selfClosing }
            if atSym("{") {
                jsxExpression()
            } else if jsxNameAhead(attribute: true) != nil {
                jsxAttribute()
            } else {
                error("expected `>`")
                if cur != nil { relexPopping(1) }
                return .broken
            }
        }
    }

    /// `name`, `name="value"`, `name={value}`.
    func jsxAttribute() {
        start(JSKind.jsxAttribute)
        jsxNameNode(attribute: true)
        if atSym("=") {
            bump()
            if isStringStart(cur) {
                if jsxStringRunsOn() { relex(.jsxLineString) }
                jsxString()
            } else if atSym("{") {
                jsxExpression()
            } else {
                error("expected an attribute value")
            }
        }
        finish()
    }

    /// An attribute's quoted value: no escapes, entities allowed, and it may span lines.
    func jsxString() {
        guard let opener = cur else { return }
        start(JSKind.string)
        let first = Array(text(opener).utf16)
        let quote = first[0]
        bump()
        var closed = first.count > 1 && first.last == quote
        while !closed, let token = cur, isLexeme(token, "string.quoted") || isLexeme(token, "constant.character.escape") {
            bump()
            if token.scope == "string.quoted" && text(token).utf16.last == quote { closed = true }
        }
        finish()
    }

    /// Whether the attribute value starting here is a quote left open: it runs past its line and
    /// doesn't close, holds `<`, `>`, `{`, `}` or `=` on a later line, or isn't followed by what can
    /// follow an attribute. A real value spanning lines (a long `className`) has none of those.
    @inline(never)
    func jsxStringRunsOn() -> Bool {
        guard let opener = cur else { return false }
        let first = Array(text(opener).utf16)
        if first.count > 1 && first.last == first[0] { return false }
        var offset = 1
        while offset < Self.scanLimit, let token = tok(offset),
              isLexeme(token, "string.quoted") || isLexeme(token, "constant.character.escape") {
            let piece = text(token)
            if hasNewline(from: opener.end, to: token.location),
               piece.utf16.contains(where: { [60, 62, 123, 125, 61].contains($0) }) { return true }
            if token.scope == "string.quoted" && piece.utf16.last == first[0] {
                guard hasNewline(from: opener.end, to: token.location) else { return false }
                return !(jsxPunctuation(">", offset + 1) || jsxPunctuation("/", offset + 1) || atSym("{", offset + 1)
                         || tok(offset + 1)?.kind == .word)
            }
            offset += 1
        }
        return true
    }

    /// `{expression}`, `{...spread}`, or an empty `{}` that may hold a comment.
    func jsxExpression() {
        start(JSKind.jsxExpression)
        bump()
        if atOp("...") {
            start(JSKind.spreadElement)
            bump("...")
            assignment()
            finish()
        } else if !atSym("}") {
            expression()
        }
        if !atSym("}") { recover("expected `}`", until: ["}"]) }
        if atSym("}") { bump() }
        finish()
    }

    /// `</name>`, or `</>` closing a fragment.
    func jsxClosingTag() {
        start(JSKind.jsxClosingTag)
        bump()
        bump()
        jsxNameNode(attribute: false)
        if jsxPunctuation(">") {
            bump()
        } else {
            error("expected `>`")
            // Leave the closing tag's state and the element's.
            if cur != nil { relexPopping(2) }
        }
        finish()
    }

    @inline(never)
    func jsxClosingTagNamed(_ name: String) -> Bool { jsxChild() == .closingTag && jsxClosingName() == name }

    /// The name in the closing tag that starts here; empty for `</>`.
    @inline(never)
    func jsxClosingName() -> String { jsxNameAhead(attribute: false, at: 2)?.text ?? "" }

    // MARK: Names

    /// Wraps the name that comes next, if one does, and returns its text.
    @discardableResult
    func jsxNameNode(attribute: Bool) -> String? {
        guard let name = jsxNameAhead(attribute: attribute) else { return nil }
        start(name.kind)
        for _ in 0..<name.length { bump() }
        finish()
        return name.text
    }

    /// The name starting `offset` tokens ahead: how many tokens it spans, its text and its node
    /// kind. A name is an identifier that may hold `-` (`aria-label`, `my-element`), then a
    /// namespace (`svg:rect`) or, for an element, members (`Foo.Bar`). An element is intrinsic when
    /// it is lowercase, dashed or namespaced, as React decides; otherwise it is a component.
    @inline(never)
    func jsxNameAhead(attribute: Bool, at start: Int = 0) -> (length: Int, text: String, kind: SyntaxKind)? {
        guard let first = tok(start), first.kind == .word else { return nil }
        var spelled = text(first)
        var offset = start + 1
        var dashed = false, member = false, namespaced = false
        while true {
            // `-` joins the parts of one identifier, written without spaces.
            while let dash = tok(offset), dash.kind == .symbol, text(dash) == "-", let before = tok(offset - 1),
                  dash.location == before.end {
                spelled += "-"
                dashed = true
                offset += 1
                if let part = tok(offset), part.kind == .word, part.location == dash.end {
                    spelled += text(part)
                    offset += 1
                }
            }
            guard let separator = sym(offset), let part = tok(offset + 1), part.kind == .word else { break }
            if separator == ":" && !namespaced && !member {
                namespaced = true
            } else if separator == "." && !attribute && !namespaced {
                member = true
            } else {
                break
            }
            spelled += separator + text(part)
            offset += 2
        }
        let kind: SyntaxKind
        if attribute {
            kind = JSKind.jsxAttributeName
        } else if member {
            kind = JSKind.jsxComponentName
        } else if namespaced || dashed || (spelled.utf16.first.map { (97...122).contains($0) } ?? false) {
            kind = JSKind.jsxTagName
        } else {
            kind = JSKind.jsxComponentName
        }
        return (offset - start, spelled, kind)
    }
}
