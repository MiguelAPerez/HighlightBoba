import Foundation

/// The JavaScript parser, with a TypeScript dialect: one hand-written recursive descent over the
/// lexer's `syntaxTokens`, building the lossless tree that the bundled highlight queries refine.
///
/// The parser decides what the lexer could only guess from the previous character: a `/` is a regex
/// where an expression starts and division after an operand, and it asks the lexer to re-read the
/// token when its guess was wrong (see `JSParse.Relex`). In TypeScript it tells `f<T>(x)` from
/// `a < b`, and closes `Map<K, Array<V>>` one `>` at a time: the lexer leaves operators as
/// one-character symbols, so `>>` is never one token to split.
///
/// The JSX and TSX dialects add JSX elements. A `<` where an expression starts opens one, and the
/// parser asks the lexer to read it in the grammar's JSX states (see `JSParse+JSX.swift`).
public struct JSParser: IncrementalParser {
    public enum Dialect: Sendable { case javascript, typescript, jsx, tsx }

    public let dialect: Dialect

    public init(dialect: Dialect = .javascript) { self.dialect = dialect }

    public var reparseBoundaries: Set<SyntaxKind> {
        [JSKind.statementBlock, JSKind.classBody, JSKind.object, JSKind.switchBody, JSKind.objectType, JSKind.enumBody]
    }

    public func parse(_ builder: TreeBuilder) {
        JSParse(builder, dialect: dialect).program()
    }

    public func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) {
        let parse = JSParse(builder, dialect: dialect)
        switch kind {
        case JSKind.statementBlock: parse.block()
        case JSKind.classBody: parse.classBody()
        case JSKind.object: parse.object()
        case JSKind.switchBody: parse.switchBody()
        case JSKind.objectType: parse.objectType()
        case JSKind.enumBody: parse.enumBody()
        default: preconditionFailure("\(kind) is not a JavaScript reparse boundary")
        }
    }
}

/// The node kinds the JavaScript parser builds, which its highlight queries match on.
public enum JSKind {
    // Names: each wraps the one token that names something, so a query can colour it by role.
    public static let identifier = SyntaxKind("identifier")
    public static let binding = SyntaxKind("binding")
    public static let propertyName = SyntaxKind("property_name")
    public static let functionName = SyntaxKind("function_name")
    public static let methodName = SyntaxKind("method_name")
    public static let typeName = SyntaxKind("type_name")
    public static let typeIdentifier = SyntaxKind("type_identifier")
    public static let label = SyntaxKind("label")
    public static let decorator = SyntaxKind("decorator")

    // Statements.
    public static let statementBlock = SyntaxKind("statement_block")
    public static let emptyStatement = SyntaxKind("empty_statement")
    public static let expressionStatement = SyntaxKind("expression_statement")
    public static let variableDeclaration = SyntaxKind("variable_declaration")
    public static let variableDeclarator = SyntaxKind("variable_declarator")
    public static let ifStatement = SyntaxKind("if_statement")
    public static let elseClause = SyntaxKind("else_clause")
    public static let forStatement = SyntaxKind("for_statement")
    public static let forInStatement = SyntaxKind("for_in_statement")
    public static let whileStatement = SyntaxKind("while_statement")
    public static let doStatement = SyntaxKind("do_statement")
    public static let returnStatement = SyntaxKind("return_statement")
    public static let breakStatement = SyntaxKind("break_statement")
    public static let continueStatement = SyntaxKind("continue_statement")
    public static let throwStatement = SyntaxKind("throw_statement")
    public static let tryStatement = SyntaxKind("try_statement")
    public static let catchClause = SyntaxKind("catch_clause")
    public static let finallyClause = SyntaxKind("finally_clause")
    public static let switchStatement = SyntaxKind("switch_statement")
    public static let switchBody = SyntaxKind("switch_body")
    public static let switchCase = SyntaxKind("switch_case")
    public static let labeledStatement = SyntaxKind("labeled_statement")
    public static let debuggerStatement = SyntaxKind("debugger_statement")
    public static let withStatement = SyntaxKind("with_statement")
    public static let functionDeclaration = SyntaxKind("function_declaration")
    public static let classDeclaration = SyntaxKind("class_declaration")
    public static let importStatement = SyntaxKind("import_statement")
    public static let namedImports = SyntaxKind("named_imports")
    public static let importSpecifier = SyntaxKind("import_specifier")
    public static let namespaceImport = SyntaxKind("namespace_import")
    public static let exportStatement = SyntaxKind("export_statement")
    public static let exportClause = SyntaxKind("export_clause")
    public static let exportSpecifier = SyntaxKind("export_specifier")

    // Expressions.
    public static let string = SyntaxKind("string")
    public static let templateString = SyntaxKind("template_string")
    public static let templateSubstitution = SyntaxKind("template_substitution")
    public static let parenthesizedExpression = SyntaxKind("parenthesized_expression")
    public static let sequenceExpression = SyntaxKind("sequence_expression")
    public static let assignmentExpression = SyntaxKind("assignment_expression")
    public static let conditionalExpression = SyntaxKind("conditional_expression")
    public static let binaryExpression = SyntaxKind("binary_expression")
    public static let unaryExpression = SyntaxKind("unary_expression")
    public static let updateExpression = SyntaxKind("update_expression")
    public static let awaitExpression = SyntaxKind("await_expression")
    public static let yieldExpression = SyntaxKind("yield_expression")
    public static let callExpression = SyntaxKind("call_expression")
    public static let arguments = SyntaxKind("arguments")
    public static let memberExpression = SyntaxKind("member_expression")
    public static let subscriptExpression = SyntaxKind("subscript_expression")
    public static let newExpression = SyntaxKind("new_expression")
    public static let metaProperty = SyntaxKind("meta_property")
    public static let arrowFunction = SyntaxKind("arrow_function")
    public static let functionExpression = SyntaxKind("function_expression")
    public static let classExpression = SyntaxKind("class")
    public static let array = SyntaxKind("array")
    public static let object = SyntaxKind("object")
    public static let pair = SyntaxKind("pair")
    public static let shorthandProperty = SyntaxKind("shorthand_property")
    public static let computedPropertyName = SyntaxKind("computed_property_name")
    public static let spreadElement = SyntaxKind("spread_element")
    public static let nonNullExpression = SyntaxKind("non_null_expression")
    public static let asExpression = SyntaxKind("as_expression")
    public static let satisfiesExpression = SyntaxKind("satisfies_expression")
    public static let typeAssertion = SyntaxKind("type_assertion")

    // Functions, classes and patterns.
    public static let formalParameters = SyntaxKind("formal_parameters")
    public static let parameter = SyntaxKind("parameter")
    public static let classBody = SyntaxKind("class_body")
    public static let classHeritage = SyntaxKind("class_heritage")
    public static let implementsClause = SyntaxKind("implements_clause")
    public static let methodDefinition = SyntaxKind("method_definition")
    public static let fieldDefinition = SyntaxKind("field_definition")
    public static let classStaticBlock = SyntaxKind("class_static_block")
    public static let objectPattern = SyntaxKind("object_pattern")
    public static let arrayPattern = SyntaxKind("array_pattern")
    public static let patternPair = SyntaxKind("pattern_pair")
    public static let restPattern = SyntaxKind("rest_pattern")
    public static let assignmentPattern = SyntaxKind("assignment_pattern")

    // TypeScript.
    public static let typeAnnotation = SyntaxKind("type_annotation")
    public static let typeParameters = SyntaxKind("type_parameters")
    public static let typeParameter = SyntaxKind("type_parameter")
    public static let typeArguments = SyntaxKind("type_arguments")
    public static let interfaceDeclaration = SyntaxKind("interface_declaration")
    public static let extendsClause = SyntaxKind("extends_clause")
    public static let typeAliasDeclaration = SyntaxKind("type_alias_declaration")
    public static let enumDeclaration = SyntaxKind("enum_declaration")
    public static let enumBody = SyntaxKind("enum_body")
    public static let enumMember = SyntaxKind("enum_member")
    public static let moduleDeclaration = SyntaxKind("module_declaration")
    public static let ambientDeclaration = SyntaxKind("ambient_declaration")
    public static let importAlias = SyntaxKind("import_alias")
    public static let objectType = SyntaxKind("object_type")
    public static let propertySignature = SyntaxKind("property_signature")
    public static let methodSignature = SyntaxKind("method_signature")
    public static let indexSignature = SyntaxKind("index_signature")
    public static let callSignature = SyntaxKind("call_signature")
    public static let constructSignature = SyntaxKind("construct_signature")
    public static let mappedType = SyntaxKind("mapped_type")
    public static let unionType = SyntaxKind("union_type")
    public static let intersectionType = SyntaxKind("intersection_type")
    public static let functionType = SyntaxKind("function_type")
    public static let constructorType = SyntaxKind("constructor_type")
    public static let conditionalType = SyntaxKind("conditional_type")
    public static let arrayType = SyntaxKind("array_type")
    public static let indexedAccessType = SyntaxKind("indexed_access_type")
    public static let tupleType = SyntaxKind("tuple_type")
    public static let genericType = SyntaxKind("generic_type")
    public static let typeQuery = SyntaxKind("type_query")
    public static let typeOperator = SyntaxKind("type_operator")
    public static let inferType = SyntaxKind("infer_type")
    public static let importType = SyntaxKind("import_type")
    public static let literalType = SyntaxKind("literal_type")
    public static let parenthesizedType = SyntaxKind("parenthesized_type")
    public static let templateLiteralType = SyntaxKind("template_literal_type")
    public static let typePredicate = SyntaxKind("type_predicate")

    // JSX.
    /// An element or fragment: its opening tag, children and closing tag, or one self-closing tag.
    public static let jsxElement = SyntaxKind("jsx_element")
    /// An element's tags: `<a href="…">`, `<br />`, `</a>`; a fragment's are `<>` and `</>`.
    public static let jsxOpeningTag = SyntaxKind("jsx_opening_tag")
    public static let jsxSelfClosingTag = SyntaxKind("jsx_self_closing_tag")
    public static let jsxClosingTag = SyntaxKind("jsx_closing_tag")
    /// An intrinsic element's name: `div`, `my-element`, `svg:rect`.
    public static let jsxTagName = SyntaxKind("jsx_tag_name")
    /// A component's name: `Button`, `Foo.Bar`, `this.Item`.
    public static let jsxComponentName = SyntaxKind("jsx_component_name")
    public static let jsxAttribute = SyntaxKind("jsx_attribute")
    public static let jsxAttributeName = SyntaxKind("jsx_attribute_name")
    /// `{expression}`, `{...spread}` or an empty `{/* comment */}`, as an attribute or a child.
    public static let jsxExpression = SyntaxKind("jsx_expression")
    public static let jsxText = SyntaxKind("jsx_text")
}
