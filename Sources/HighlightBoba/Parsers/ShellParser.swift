import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The shell parser (POSIX sh and bash): hand-written recursive descent over the shell lexer's tokens.
///
/// It knows **command position**, which the lexer can only guess at: the command name is the first
/// word after the assignments and redirections, after `|`, `&&`, `;`, `then`, `do`, `!`, `time`…
/// Reserved words are keywords only there, so `echo if then done` is a command and three arguments,
/// and the parser re-lexes keywords and builtin names that sit in an argument as plain words. It
/// builds simple commands, pipelines and lists, every compound command, function definitions,
/// `[[ ]]` and `(( ))`, substitutions, parameter and arithmetic expansions, and heredoc bodies, so
/// `Queries/shell.json` can scope command names, declared functions, assigned variables, options,
/// `case` patterns and test operators.
///
/// It also re-lexes three places the lexer reads wrong: the `)` closing a `case` pattern inside
/// `$( )`, which the lexer takes for the substitution's end; a `<<` shift inside `$(( ))` or `(( ))`,
/// which it takes for a heredoc; and a `<<\EOF` heredoc, which it doesn't recognise.
///
/// Compound commands and `$( )` are reparse boundaries. Each parses the same wherever it is, except
/// inside backticks or on a line whose heredoc bodies are still to come: there the parse carries
/// state in, so the node gets a twin kind that isn't a boundary, and an edit reparses around it.
public struct ShellParser: IncrementalParser {
    public init() {}

    public var reparseBoundaries: Set<SyntaxKind> { ShellKind.boundaries }

    public func parse(_ builder: TreeBuilder) { ShellParse(builder).program() }

    public func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { ShellParse(builder).block(kind) }
}

/// The node kinds the shell parser makes. Highlight queries match on these names.
enum ShellKind {
    // Compound commands and `$( )`: the reparse boundaries.
    static let braceGroup = SyntaxKind("braceGroup")
    static let subshell = SyntaxKind("subshell")
    static let ifCommand = SyntaxKind("ifCommand")
    static let whileCommand = SyntaxKind("whileCommand")
    static let forCommand = SyntaxKind("forCommand")
    static let caseCommand = SyntaxKind("caseCommand")
    static let commandSubstitution = SyntaxKind("commandSubstitution")

    static let boundaries: Set<SyntaxKind> = [braceGroup, subshell, ifCommand, whileCommand, forCommand, caseCommand,
                                               commandSubstitution]
    /// The kind a boundary gets where its parse depends on what is around it: not a boundary.
    static let twins: [SyntaxKind: SyntaxKind] = Dictionary(uniqueKeysWithValues: boundaries.map {
        ($0, SyntaxKind($0.name + "InContext"))
    })

    // Commands.
    static let command = SyntaxKind("command")
    static let pipeline = SyntaxKind("pipeline")
    static let andOr = SyntaxKind("andOr")
    static let redirected = SyntaxKind("redirected")
    static let functionDefinition = SyntaxKind("functionDefinition")
    static let functionName = SyntaxKind("functionName")
    static let arithmeticCommand = SyntaxKind("arithmeticCommand")
    static let testCommand = SyntaxKind("testCommand")
    static let caseItem = SyntaxKind("caseItem")
    static let casePattern = SyntaxKind("casePattern")

    // Words.
    static let word = SyntaxKind("word")
    static let commandName = SyntaxKind("commandName")
    static let builtinName = SyntaxKind("builtinName")
    static let option = SyntaxKind("option")
    static let assignment = SyntaxKind("assignment")
    static let variableName = SyntaxKind("variableName")
    static let arrayValue = SyntaxKind("arrayValue")
    static let redirect = SyntaxKind("redirect")
    static let heredocBody = SyntaxKind("heredocBody")
    static let backtickSubstitution = SyntaxKind("backtickSubstitution")
    static let processSubstitution = SyntaxKind("processSubstitution")
    static let arithmeticExpansion = SyntaxKind("arithmeticExpansion")
    static let arithmetic = SyntaxKind("arithmetic")
    static let expansion = SyntaxKind("expansion")
    static let testOperator = SyntaxKind("testOperator")
    static let regex = SyntaxKind("regex")
}

/// One parse: the builder, plus what the parser tracks on top of it.
final class ShellParse {
    private typealias K = ShellKind

    private let b: TreeBuilder
    /// Where the last significant token this parser consumed ends, or -1 before the first one.
    /// Words are runs of adjacent tokens, and a line break ends a command.
    private var lastEnd = -1
    /// Where a `\` that ends its line ends: the line break after it joins the two lines.
    private var continuationEnd = -1
    /// Heredoc bodies still to come, one per operator read: they start on the next line.
    private var pendingHeredocs = 0
    /// Inside `` ` ` ``, where a backtick closes rather than opens.
    private var inBacktick = false
    /// Where the text ends: the "next character" checks read past a token without lookahead.
    private let textEnd: Int
    private var textCache: (location: Int, text: String) = (-1, "")

    /// Past this many open nodes the parser stops nesting and skips the rest of the construct, so
    /// hostile input can't run a background thread's stack out. The limit is on the tree's depth,
    /// so a block's reparse stops exactly where a whole parse does.
    static let maxDepth = 64
    /// Stack the parser keeps free, as a last guard: a debug build's frames are several times a
    /// release build's, and a background thread may have only 512 KB.
    static let stackReserve: UInt = 160 * 1024
    private let stackFloor: UInt

    init(_ builder: TreeBuilder) {
        b = builder
        textEnd = builder.tokens.last?.end ?? 0
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        stackFloor = top > size + Self.stackReserve ? top - size + Self.stackReserve : 0
        #else
        stackFloor = 0
        #endif
    }

    private var stackIsLow: Bool {
        var marker = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) } < stackFloor
    }

    // MARK: Entry points

    func program() {
        while b.current != nil {
            list()
            if let token = b.current { errorAndBump("unexpected `\(text(token))`") }
        }
    }

    /// One boundary node, from its first token. A construct that turns out to be something else
    /// here makes another kind of node, so the reparse falls back.
    func block(_ kind: SyntaxKind) {
        if kind == K.commandSubstitution {
            dollarParen()
        } else if !compoundCommand() {
            simpleCommand()
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

    private func bump() {
        guard let token = cur else { return }
        if isHeredocOperator(token) { pendingHeredocs += 1 }
        lastEnd = token.end
        b.bump()
    }

    private func bumpSpelling(_ spelling: String) {
        guard let token = cur, b.bump(spelling) else { return }
        lastEnd = token.location + spelling.utf16.count
    }

    private func errorAndBump(_ message: String) {
        if let token = cur { lastEnd = token.end }
        b.errorAndBump(message)
    }

    private func node(_ kind: SyntaxKind, _ body: () -> Void) {
        b.startNode(kind)
        body()
        b.finishNode()
    }

    /// `kind`, or its twin where the parse carries state into the node.
    private func boundary(_ kind: SyntaxKind) -> SyntaxKind {
        pendingHeredocs > 0 || inBacktick ? K.twins[kind]! : kind
    }

    /// The UTF-16 unit at `location`, or nil at the end of the text. Reads the text directly, so
    /// deciding what a token is from the character after it doesn't count as lookahead: a
    /// boundary's parse makes the same decision again, so an edit that changes it falls back.
    private func unit(at location: Int) -> UInt16? {
        guard location < textEnd else { return nil }
        return b.text(of: SyntaxToken(kind: .symbol, location: location, length: 1)).utf16.first
    }

    private static let wordEnders = Set("\t\n\r ;&|<>()".utf16)

    /// Whether a word ends at `location`: a space, a line break, a metacharacter or the end.
    private func wordEnds(at location: Int) -> Bool {
        guard let unit = unit(at: location) else { return true }
        return Self.wordEnders.contains(unit) || (inBacktick && unit == 96)
    }

    private func isSymbol(_ token: SyntaxToken?, _ value: String) -> Bool {
        guard let token, token.kind == .symbol else { return false }
        return text(token) == value
    }

    /// A reserved word: a keyword the lexer found, standing alone as a word.
    private func isReserved(_ token: SyntaxToken?, _ words: Set<String>) -> Bool {
        guard let token else { return false }
        if token.kind == .symbol {
            guard token.length == 1, words.contains(text(token)) else { return false }
        } else {
            guard token.kind == .lexeme, token.scope == "keyword", words.contains(text(token)) else { return false }
        }
        return wordEnds(at: token.end)
    }

    private func isReserved(_ token: SyntaxToken?, _ word: String) -> Bool { isReserved(token, [word]) }

    private func isEmbedded(_ token: SyntaxToken?, _ value: String) -> Bool {
        guard let token, token.kind == .lexeme, token.scope == "punctuation.section.embedded" else { return false }
        return text(token) == value
    }

    /// `<<EOF`, `<<-'EOF'`: the lexer reads the body from the next line.
    private func isHeredocOperator(_ token: SyntaxToken) -> Bool {
        guard token.kind == .lexeme, token.scope == "keyword", token.length > 2 else { return false }
        let value = text(token)
        return value.hasPrefix("<<") && !value.hasPrefix("<<<")
    }

    /// Whether a line break separates the last consumed token from `token`. One right after a
    /// `\` that ends its line doesn't count.
    private func lineBreakBefore(_ token: SyntaxToken) -> Bool {
        guard lastEnd >= 0 else { return true }
        guard token.location > lastEnd else { return false }
        var gap = b.text(of: SyntaxToken(kind: .space, location: lastEnd, length: token.location - lastEnd)).utf16[...]
        if lastEnd == continuationEnd {
            if gap.first == 13 { gap = gap.dropFirst() }
            if gap.first == 10 { gap = gap.dropFirst() }
        }
        return gap.contains(10) || gap.contains(13)
    }

    /// A `\` the lexer left alone: one at the end of a line, which continues it.
    private func isContinuation(_ token: SyntaxToken) -> Bool { token.kind == .symbol && text(token) == "\\" }

    private func bumpContinuation() {
        bump()
        continuationEnd = lastEnd
    }

    /// Reads the heredoc bodies waiting for this line, when the next token is on a new one.
    private func heredocsIfDue() {
        while pendingHeredocs > 0, let token = cur, lineBreakBefore(token) { heredocBodies() }
    }

    /// Line breaks are trivia; this reads the heredoc bodies and `\` continuations among them.
    private func skipLineBreaks() {
        heredocsIfDue()
        while let token = cur, isContinuation(token) {
            bumpContinuation()
            heredocsIfDue()
        }
    }

    private func tooDeep() -> Bool {
        guard b.depth >= Self.maxDepth || stackIsLow else { return false }
        b.recover("nesting too deep", until: [])
        lastEnd = -1
        return true
    }

    // MARK: Lists

    /// Pipelines joined by `&&` and `||`, separated by `;`, `&` and line breaks, up to a word or
    /// symbol that closes the enclosing construct.
    private func list() {
        while true {
            skipLineBreaks()
            guard let token = cur, !endsList(token) else { return }
            if b.at(";") || (b.at("&") && !redirectionAhead(token)) {
                errorAndBump("expected a command before `\(text(token))`")
                continue
            }
            andOr()
            guard let next = cur, !endsList(next) else { return }
            if b.at(";;") || b.at(";&") { return }
            if b.at(";") || (b.at("&") && !b.at("&&")) {
                bump()
            } else if !lineBreakBefore(next) && !isContinuation(next) {
                b.error("expected `;` or a line break")
            }
        }
    }

    private static let closingWords: Set<String> = ["then", "elif", "else", "fi", "do", "done", "esac", "}"]

    /// A word or symbol that ends a list: a closing reserved word, `)`, `;;`, or a closing backtick.
    private func endsList(_ token: SyntaxToken) -> Bool {
        if isReserved(token, Self.closingWords) { return true }
        if token.length == 1 && (token.kind == .symbol || token.scope == "punctuation.section.embedded") {
            switch text(token) {
            case ")": return true
            case "`": return inBacktick
            case ";": return b.at(";;") || b.at(";&")
            default: return false
            }
        }
        return false
    }

    private func andOr() {
        let start = b.checkpoint()
        pipeline()
        var joined = false
        while b.at("&&") || b.at("||") {
            bumpSpelling(b.at("&&") ? "&&" : "||")
            skipLineBreaks()
            pipeline()
            joined = true
        }
        if joined {
            b.startNode(K.andOr, at: start)
            b.finishNode()
        }
    }

    private func pipeline() {
        let start = b.checkpoint()
        var wrapped = false
        if isReserved(cur, "time") {
            bump()
            if let token = cur, isSymbol(token, "-"), !lineBreakBefore(token) { argument(.other) }
            wrapped = true
        }
        while let token = cur, isReserved(token, ["!", "coproc"]) {
            bump()
            wrapped = true
            // `coproc NAME { … }`: the name of the array that holds its file descriptors.
            if text(token) == "coproc", let name = cur, isName(name), wordEnds(at: name.end),
               let body = b.peek(1), isSymbol(body, "{") || isSymbol(body, "(") {
                node(K.variableName) { bump() }
            }
        }
        command()
        while b.at("|") && !b.at("||") {
            bumpSpelling(b.at("|&") ? "|&" : "|")
            skipLineBreaks()
            command()
            wrapped = true
        }
        if wrapped {
            b.startNode(K.pipeline, at: start)
            b.finishNode()
        }
    }

    /// A compound command (with its redirections), a function definition or a simple command.
    private func command() {
        guard let token = cur else {
            b.error("expected a command")
            return
        }
        if endsList(token) {
            b.error("expected a command")
            return
        }
        if b.at("|") || b.at("&&") {
            errorAndBump("expected a command before `\(text(token))`")
            return
        }
        let start = b.checkpoint()
        if compoundCommand() {
            redirections(wrapping: start)
        } else if !functionDefinition() {
            simpleCommand()
        }
    }

    /// Redirections after a compound command, wrapped with it.
    private func redirections(wrapping start: TreeBuilder.Checkpoint) {
        var any = false
        while let token = cur, !lineBreakBefore(token), redirection() { any = true }
        if any {
            b.startNode(K.redirected, at: start)
            b.finishNode()
        }
    }

    // MARK: Compound commands

    /// A compound command if one starts here. Decided from the current token and the character
    /// after it, never from lookahead, so each of them can be a reparse boundary.
    private func compoundCommand() -> Bool {
        guard let token = cur, !tooDeep() else { return false }
        if token.kind == .symbol && token.length == 1 {
            switch text(token) {
            case "{" where wordEnds(at: token.end): braceGroup()
            case "(" where unit(at: token.end) == 40: arithmeticCommand()
            case "(": subshell()
            case "[" where unit(at: token.end) == 91 && wordEnds(at: token.end + 1): testCommand()
            default: return false
            }
            return true
        }
        guard token.kind == .lexeme, token.scope == "keyword", wordEnds(at: token.end) else { return false }
        switch text(token) {
        case "if": ifCommand()
        case "while", "until": loop(K.whileCommand)
        case "for", "select": forCommand()
        case "case": caseCommand()
        default: return false
        }
        return true
    }

    private func expectReserved(_ word: String) -> Bool {
        if isReserved(cur, word) {
            bump()
            return true
        }
        b.error("expected `\(word)`")
        return false
    }

    private func braceGroup() {
        node(boundary(K.braceGroup)) {
            bump()
            list()
            _ = expectReserved("}")
        }
    }

    private func subshell() {
        node(boundary(K.subshell)) {
            bump()
            list()
            closeParen()
        }
    }

    private func closeParen() {
        if let token = cur, token.length == 1, text(token) == ")" {
            bump()
        } else {
            b.error("expected `)`")
        }
    }

    private func ifCommand() {
        node(boundary(K.ifCommand)) {
            bump()
            list()
            _ = expectReserved("then")
            list()
            while isReserved(cur, "elif") {
                bump()
                list()
                _ = expectReserved("then")
                list()
            }
            if isReserved(cur, "else") {
                bump()
                list()
            }
            _ = expectReserved("fi")
        }
    }

    /// `while` and `until`.
    private func loop(_ kind: SyntaxKind) {
        node(boundary(kind)) {
            bump()
            list()
            doGroup()
        }
    }

    private func doGroup() {
        skipLineBreaks()
        if expectReserved("do") {
            list()
            _ = expectReserved("done")
        }
    }

    /// `for name [in words]`, `for ((;;))` and `select`; the body is `do … done` or `{ … }`.
    private func forCommand() {
        node(boundary(K.forCommand)) {
            bump()
            if let token = cur, isSymbol(token, "("), unit(at: token.end) == 40 {
                bump()
                bump()
                arithmetic()
                expectDoubleParen()
            } else if let token = cur, !lineBreakBefore(token), isName(token) {
                node(K.variableName) { bump() }
                skipLineBreaks()
                if isReserved(cur, "in") {
                    bump()
                    while let token = cur, !lineBreakBefore(token), !isWordEnd(token) { word() }
                }
            } else {
                b.error("expected a variable name")
            }
            if b.at(";") && !b.at(";;") { bump() }
            skipLineBreaks()
            if let token = cur, isSymbol(token, "{"), wordEnds(at: token.end) {
                braceGroup()
            } else {
                doGroup()
            }
        }
    }

    private func caseCommand() {
        node(boundary(K.caseCommand)) {
            bump()
            if let token = cur, !lineBreakBefore(token), !isWordEnd(token) { word() } else { b.error("expected a word") }
            skipLineBreaks()
            _ = expectReserved("in")
            while true {
                skipLineBreaks()
                guard let token = cur else { break }
                if isReserved(token, "esac") { break }
                if b.at(";;") || b.at(";&") {
                    errorAndBump("expected a pattern")
                    continue
                }
                if endsList(token) && !isSymbol(token, ")") { break }
                caseItem()
            }
            _ = expectReserved("esac")
        }
    }

    private func caseItem() {
        node(K.caseItem) {
            if isSymbol(cur, "(") { bump() }
            while true {
                if let token = cur, !isWordEnd(token) {
                    node(K.casePattern) { wordPieces() }
                } else {
                    b.error("expected a pattern")
                }
                guard b.at("|") else { break }
                bump()
            }
            // Inside `$( )` the lexer takes the pattern's `)` for the substitution's end.
            if let token = cur, isEmbedded(token, ")") { b.relex(as: "caseClose") }
            closeParen()
            list()
            if b.at(";;&") {
                bumpSpelling(";;&")
            } else if b.at(";;") || b.at(";&") {
                bumpSpelling(b.at(";;") ? ";;" : ";&")
            } else if !isReserved(cur, "esac") {
                b.error("expected `;;`")
            }
        }
    }

    /// `(( expression ))`.
    private func arithmeticCommand() {
        node(K.arithmeticCommand) {
            bump()
            bump()
            arithmetic()
            expectDoubleParen()
        }
    }

    private func expectDoubleParen() {
        if b.at("))") {
            bumpSpelling("))")
        } else {
            b.error("expected `))`")
        }
    }

    /// The inside of `(( ))` or `$(( ))`, up to its closing `))`. Names in it are variables.
    private func arithmetic() {
        node(K.arithmetic) {
            var depth = 0
            while let token = cur {
                if depth == 0 && b.at("))") { break }
                if token.kind == .symbol && token.length == 1 {
                    switch text(token) {
                    case "(": depth += 1
                    case ")":
                        if depth == 0 { return }
                        depth -= 1
                    default: break
                    }
                    bump()
                } else if isHeredocOperator(token) {
                    // `1 << x` is a shift, though the lexer reads a heredoc. Without the re-lex the
                    // lexer's heredoc stands, and so does the parser's.
                    if !b.relex(as: "shiftOperator") { bump() }
                } else if isName(token) {
                    if token.kind == .lexeme { b.relex(as: "plainWord") }
                    node(K.variableName) { bump() }
                } else if !wordPiece(token) {
                    bump()
                }
            }
        }
    }

    private func testCommand() {
        node(K.testCommand) {
            bump()
            bump()
            // A line break may follow `&&`, `||`, `!` or `(`; anywhere else it ends the test, unclosed.
            var open = false
            while let token = cur {
                if lineBreakBefore(token) && !open { break }
                open = false
                if b.at("]]") && token.location != lastEnd {
                    bumpSpelling("]]")
                    return
                }
                if (b.at(";") && !lineBreakBefore(token)) || endsList(token) && !isSymbol(token, ")") { break }
                if let spelling = ["&&", "||", "==", "!=", "=~", "=", "<", ">", "!"].first(where: { b.at($0) }),
                   spelling.count == 2 || wordEnds(at: token.end) {
                    node(K.testOperator) { bumpSpelling(spelling) }
                    open = spelling == "&&" || spelling == "||" || spelling == "!"
                    if spelling == "=~", let next = cur, !b.at("]]") { regex(next) }
                } else if isSymbol(token, "(") || isSymbol(token, ")") {
                    open = isSymbol(token, "(")
                    bump()
                } else if isSymbol(token, "-"), let next = b.peek(1), next.location == token.end,
                          next.kind == .word || next.kind == .lexeme, wordEnds(at: next.end) {
                    node(K.testOperator) {
                        bump()
                        if next.kind == .lexeme { b.relex(as: "plainWord") }
                        bump()
                    }
                } else if isWordEnd(token) {
                    errorAndBump("unexpected `\(text(token))` in `[[ ]]`")
                } else {
                    word()
                }
            }
            b.error("expected `]]`")
        }
    }

    /// The pattern after `=~`: one word, in which `(`, `)` and `|` are part of the regex.
    private func regex(_ first: SyntaxToken) {
        node(K.regex) {
            var depth = 0
            while let token = cur, token.location == lastEnd || token.location == first.location {
                if token.kind == .symbol, token.length == 1 {
                    let value = text(token)
                    if value == "(" {
                        depth += 1
                    } else if value == ")" {
                        guard depth > 0 else { break }
                        depth -= 1
                    } else if value != "|" && isWordEnd(token) {
                        break
                    }
                    bump()
                } else if !wordPiece(token) {
                    bump()
                }
            }
        }
    }

    // MARK: Function definitions

    /// `name() body` or `function name [()] body`.
    private func functionDefinition() -> Bool {
        guard let token = cur else { return false }
        let keyword = isReserved(token, "function")
        guard keyword || functionNameAhead() else { return false }
        node(K.functionDefinition) {
            if keyword { bump() }
            if let name = cur, !isWordEnd(name), !keyword || !lineBreakBefore(name) {
                node(K.functionName) {
                    bump()
                    while let piece = cur, piece.location == lastEnd, !isWordEnd(piece) { bump() }
                }
            } else {
                b.error("expected a function name")
            }
            if isSymbol(cur, "("), let close = b.peek(1), isSymbol(close, ")") {
                bump()
                bump()
            }
            skipLineBreaks()
            let start = b.checkpoint()
            if compoundCommand() {
                redirections(wrapping: start)
            } else {
                b.error("expected a function body")
            }
        }
        return true
    }

    /// A name made of plain pieces, then `(` and `)`: `f()`, `my-func ()`.
    private func functionNameAhead() -> Bool {
        var offset = 0
        var previous: SyntaxToken?
        while let token = b.peek(offset), previous == nil || token.location == previous!.end {
            guard !isWordEnd(token) else { break }
            switch token.kind {
            case .word: break
            case .symbol: if text(token) == "=" || text(token) == "\\" { return false }
            case .lexeme:
                guard ["keyword", "support.function", "entity.name.function"].contains(token.scope ?? "") else { return false }
            default: return false
            }
            previous = token
            offset += 1
            guard offset < 64 else { return false }
        }
        guard offset > 0, isSymbol(b.peek(offset), "("), isSymbol(b.peek(offset + 1), ")") else { return false }
        return true
    }

    // MARK: Simple commands

    /// What a command does with its arguments, for the ones that name variables.
    private enum Role {
        case other
        /// `export`, `local`, `declare`, `typeset`, `readonly`: assignments and names.
        case declaration
        /// `read`, `mapfile`, `readarray`, `unset`: names, after options (some of which take a value).
        case names(valued: Set<Character>, arrays: Set<Character>)
        /// `getopts optstring name`.
        case getopts
        /// `printf -v name`.
        case printf
    }

    private static let builtins: Set<String> = [
        ":", ".", "[", "alias", "bg", "bind", "break", "builtin", "caller", "cd", "command", "compgen", "complete",
        "compopt", "continue", "declare", "dirs", "disown", "echo", "enable", "eval", "exec", "exit", "export", "false",
        "fc", "fg", "getopts", "hash", "help", "history", "jobs", "kill", "let", "local", "logout", "mapfile", "popd",
        "printf", "pushd", "pwd", "read", "readarray", "readonly", "return", "set", "shift", "shopt", "source", "suspend",
        "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "wait"
    ]

    private static func role(of name: String) -> Role {
        switch name {
        case "export", "local", "declare", "typeset", "readonly": .declaration
        case "read": .names(valued: Set("adinNptu"), arrays: ["a"])
        case "mapfile", "readarray": .names(valued: Set("dnOsuCc"), arrays: [])
        case "unset": .names(valued: [], arrays: [])
        case "getopts": .getopts
        case "printf": .printf
        default: .other
        }
    }

    /// Assignments and redirections, then the command name and its arguments, to the end of the line
    /// or a metacharacter.
    private func simpleCommand() {
        guard let first = cur else { return }
        if isWordEnd(first) && !redirectionAhead(first) && !processSubstitutionAhead(first) {
            errorAndBump("unexpected `\(text(first))`")
            return
        }
        node(K.command) {
            var started = false
            var role = Role.other
            while let token = cur, !started || !lineBreakBefore(token) {
                if isContinuation(token) {
                    bumpContinuation()
                } else if redirection() || assignment() {
                    started = true
                } else {
                    break
                }
            }
            if let token = cur, !started || !lineBreakBefore(token), !isWordEnd(token) || processSubstitutionAhead(token) {
                role = commandName()
                started = true
            }
            guard started else { return }
            var state = ArgumentState()
            while let token = cur, !lineBreakBefore(token) {
                if isContinuation(token) {
                    bumpContinuation()
                } else if redirection() {
                    continue
                } else if processSubstitutionAhead(token) {
                    node(K.word) { processSubstitution() }
                } else if isSymbol(token, "(") {
                    errorAndBump("unexpected `(`")
                } else if isWordEnd(token) {
                    break
                } else {
                    argument(role, &state)
                }
            }
        }
    }

    /// The command name: a builtin's own node, or any other command's.
    private func commandName() -> Role {
        guard let token = cur else { return .other }
        let value = text(token)
        if wordEnds(at: token.end), Self.builtins.contains(value) || token.scope == "support.function" {
            node(K.builtinName) { bump() }
            return Self.role(of: value)
        }
        node(K.commandName) { wordPieces() }
        return .other
    }

    /// What the arguments so far mean for the next one.
    private struct ArgumentState {
        /// The next word is an option's value; `true` when it names an array.
        var value: Bool?
        var operands = 0
        var functions = false
    }

    private func argument(_ role: Role) {
        var state = ArgumentState()
        argument(role, &state)
    }

    private func argument(_ role: Role, _ state: inout ArgumentState) {
        guard let token = cur else { return }
        if let array = state.value {
            state.value = nil
            if array && isName(token) && wordEnds(at: token.end) {
                node(K.variableName) { bump() }
            } else {
                word()
            }
            return
        }
        if isSymbol(token, "-"), let after = unit(at: token.end), after == 45 || isOptionCharacter(after) {
            let letters = option()
            switch role {
            case .names(let valued, let arrays):
                if letters == "f" { state.functions = true }
                if let last = letters.last, valued.contains(last) { state.value = arrays.contains(last) }
            case .printf:
                if letters == "v" { state.value = true }
            default: break
            }
            return
        }
        switch role {
        case .declaration:
            if assignment() { return }
            if isName(token) && wordEnds(at: token.end) {
                node(K.variableName) { bump() }
                return
            }
        case .names:
            if !state.functions && isName(token) && wordEnds(at: token.end) {
                node(K.variableName) { bump() }
                return
            }
        case .getopts:
            state.operands += 1
            if state.operands == 2 && isName(token) && wordEnds(at: token.end) {
                node(K.variableName) { bump() }
                return
            }
        case .printf, .other: break
        }
        word()
    }

    private func isOptionCharacter(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit)
    }

    /// `-x`, `--flag`, `--`: the dashes and the name after them, in an `option` node. The rest of
    /// the word (`=value`) goes in a `word` around it. Returns the option's letters.
    @discardableResult
    private func option() -> String {
        let start = b.checkpoint()
        var letters = ""
        node(K.option) {
            bump()
            if let token = cur, token.location == lastEnd, isSymbol(token, "-") { bump() }
            while let token = cur, token.location == lastEnd {
                if token.kind == .word || (token.kind == .lexeme && isName(token)) {
                    if token.kind == .lexeme { b.relex(as: "plainWord") }
                    if letters.isEmpty { letters = text(token) }
                    bump()
                } else if isSymbol(token, "-") {
                    bump()
                } else {
                    break
                }
            }
        }
        if let token = cur, token.location == lastEnd, !isWordEnd(token) {
            b.startNode(K.word, at: start)
            wordPieces(continuing: true)
            b.finishNode()
        }
        return letters
    }

    /// `name=value`, `name+=value`, `name[index]=value`, `name=(a b c)`, if one comes next.
    private func assignment() -> Bool {
        guard let token = cur, isName(token), let equals = assignmentEquals() else { return false }
        node(K.assignment) {
            node(K.variableName) { bump() }
            while let next = cur, next.location < equals { bump() }
            bumpSpelling("=")
            guard let value = cur, value.location == lastEnd else { return }
            if isSymbol(value, "(") {
                arrayValue()
            } else if !isWordEnd(value) {
                node(K.word) { wordPieces() }
            }
        }
        return true
    }

    /// Where the `=` of an assignment starting here is: right after the name, after a `+`, or
    /// after a `[index]`.
    private func assignmentEquals() -> Int? {
        guard let name = cur, var next = b.peek(1), next.location == name.end else { return nil }
        if isSymbol(next, "=") { return next.location }
        if isSymbol(next, "+") {
            guard let equals = b.peek(2), equals.location == next.end, isSymbol(equals, "=") else { return nil }
            return equals.location
        }
        guard isSymbol(next, "[") else { return nil }
        var offset = 2
        var depth = 1
        while depth > 0 {
            guard let token = b.peek(offset), token.location == next.end, offset < 256 else { return nil }
            if isSymbol(token, "[") { depth += 1 } else if isSymbol(token, "]") { depth -= 1 }
            next = token
            offset += 1
        }
        guard let equals = b.peek(offset), equals.location == next.end else { return nil }
        if isSymbol(equals, "=") { return equals.location }
        guard isSymbol(equals, "+"), let after = b.peek(offset + 1), after.location == equals.end, isSymbol(after, "=") else { return nil }
        return after.location
    }

    private func arrayValue() {
        node(K.arrayValue) {
            bump()
            while true {
                skipLineBreaks()
                guard let token = cur else { break }
                if isSymbol(token, ")") {
                    bump()
                    return
                }
                if isWordEnd(token) {
                    // `x=(a b; next`: the array is unclosed, and the command after it is a command.
                    break
                } else {
                    word()
                }
            }
            b.error("expected `)`")
        }
    }

    // MARK: Redirections

    private func redirectionAhead(_ token: SyntaxToken) -> Bool {
        if isHeredocOperator(token) || text(token) == "<<<" { return true }
        guard token.kind == .symbol, token.length == 1 else { return digitsBeforeRedirection(token) }
        switch text(token) {
        case "<", ">": return unit(at: token.end) != 40
        case "&": return unit(at: token.end) == 62
        default: return false
        }
    }

    /// `2>`: a file descriptor number right before a redirection operator.
    private func digitsBeforeRedirection(_ token: SyntaxToken) -> Bool {
        guard token.kind == .word, text(token).utf16.allSatisfy({ (48...57).contains($0) }),
              let next = unit(at: token.end) else { return false }
        return next == 60 || next == 62
    }

    private static let operators = ["&>>", "&>", ">>", ">&", ">|", "<<", "<&", "<>", ">", "<"]

    /// A redirection, if one comes next: `> file`, `2>&1`, `<<EOF`, `<<< word`.
    private func redirection() -> Bool {
        guard let token = cur, redirectionAhead(token) else { return false }
        node(K.redirect) {
            if digitsBeforeRedirection(token) { bump() }
            if let next = cur, isSymbol(next, "<"), b.at("<<"), let after = b.peek(2), after.location == next.end + 1,
               after.scope == "constant.character.escape" {
                // `<<\EOF`, which the lexer doesn't take for a heredoc.
                b.relex(as: "escapedHeredoc")
            }
            if let next = cur, isHeredocOperator(next) {
                bump()
                return
            }
            if let next = cur, text(next) == "<<<" {
                bump()
            } else if let spelling = Self.operators.first(where: { b.at($0) }) {
                bumpSpelling(spelling)
            } else {
                b.error("expected a redirection")
                return
            }
            if let target = cur, !lineBreakBefore(target), !isWordEnd(target) || processSubstitutionAhead(target) {
                if processSubstitutionAhead(target) {
                    node(K.word) { processSubstitution() }
                } else {
                    word()
                }
            } else {
                b.error("expected a word after the redirection")
            }
        }
        return true
    }

    private func heredocBodies() {
        let count = pendingHeredocs
        pendingHeredocs = 0
        for _ in 0..<count {
            guard cur != nil else { return }
            node(K.heredocBody) {
                while let token = cur {
                    // The lexer's only keyword in a body is the closing delimiter.
                    if token.kind == .lexeme && token.scope == "keyword" {
                        bump()
                        return
                    }
                    if !wordPiece(token) { bump() }
                }
            }
        }
    }

    // MARK: Words

    /// A symbol or token that ends a word: a metacharacter, `)` closing a substitution, a closing
    /// backtick, a heredoc or here-string operator.
    private func isWordEnd(_ token: SyntaxToken) -> Bool {
        switch token.kind {
        case .symbol:
            guard token.length == 1 else { return false }
            return Self.wordEnders.contains(text(token).utf16.first!)
        case .lexeme:
            switch token.scope {
            case "punctuation.section.embedded":
                let value = text(token)
                return value == ")" || (value == "`" && inBacktick)
            case "keyword":
                return text(token).hasPrefix("<<")
            default: return false
            }
        case .word: return false
        case .space, .newline: return true
        }
    }

    /// A name: `[A-Za-z_][A-Za-z0-9_]*`, plain or a word the lexer scoped (`test`, `local`).
    private func isName(_ token: SyntaxToken) -> Bool {
        guard token.kind == .word || (token.kind == .lexeme && ["keyword", "support.function", "entity.name.function"].contains(token.scope ?? "")) else { return false }
        let units = text(token).utf16
        guard let first = units.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return units.allSatisfy { $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    private func word(_ kind: SyntaxKind = K.word) {
        node(kind) { wordPieces() }
    }

    /// Adjacent pieces up to a metacharacter, a space or a line break. A quoted string may run over
    /// a line break. Keywords and builtin names the lexer found are re-lexed as plain text: a word
    /// here is never one.
    private func wordPieces(continuing: Bool = false) {
        var quote: UInt16?
        var first = !continuing
        while let token = cur {
            if !first {
                guard token.location == lastEnd || (quote != nil && onlyLineBreaks(before: token)) else { break }
            }
            guard !isWordEnd(token), !isContinuation(token) else { break }
            first = false
            if token.kind == .lexeme {
                if token.scope == "string.quoted" {
                    track(token, &quote)
                } else if quote == nil, isName(token) {
                    b.relex(as: "plainWord")
                }
            }
            if !wordPiece(token) { bump() }
        }
    }

    private func onlyLineBreaks(before token: SyntaxToken) -> Bool {
        guard lastEnd >= 0, token.location > lastEnd else { return false }
        return b.text(of: SyntaxToken(kind: .space, location: lastEnd, length: token.location - lastEnd))
            .utf16.allSatisfy { $0 == 10 || $0 == 13 }
    }

    /// Follows a quoted string's pieces, so one that spans lines stays one word.
    private func track(_ token: SyntaxToken, _ quote: inout UInt16?) {
        var units = text(token).utf16[...]
        if let open = quote {
            if units.last == open { quote = nil }
            return
        }
        if units.starts(with: "$'".utf16) { units = units.dropFirst() }
        guard let open = units.first, open == 34 || open == 39 else { return }
        let rest = units.dropFirst()
        if rest.last != open { quote = open }
    }

    /// A piece that is a construct of its own: `$( )`, `$(( ))`, `` ` ` ``, `${ }`. Returns false,
    /// consuming nothing, for any other token.
    private func wordPiece(_ token: SyntaxToken) -> Bool {
        if token.kind == .lexeme {
            switch token.scope {
            case "punctuation.section.embedded":
                let value = text(token)
                if value == "$" {
                    dollarParen()
                    return true
                }
                if value == "`" && !inBacktick {
                    backtickSubstitution()
                    return true
                }
            case "variable.other":
                let value = text(token)
                if value.hasPrefix("${") && !value.hasSuffix("}") {
                    expansion()
                    return true
                }
            default: break
            }
        }
        return false
    }

    /// `$( … )` or `$(( … ))`, at the `$`.
    private func dollarParen() {
        guard let dollar = cur, !tooDeep() else { return }
        if unit(at: dollar.end + 1) == 40 {
            node(K.arithmeticExpansion) {
                bump()
                bump()
                bump()
                arithmetic()
                expectDoubleParen()
            }
            return
        }
        node(boundary(K.commandSubstitution)) {
            bump()
            bump()
            let outer = inBacktick
            inBacktick = false
            list()
            inBacktick = outer
            closeParen()
        }
    }

    private func backtickSubstitution() {
        guard !tooDeep() else { return }
        node(K.backtickSubstitution) {
            bump()
            let outer = inBacktick
            inBacktick = true
            list()
            inBacktick = outer
            if let token = cur, isEmbedded(token, "`") { bump() } else { b.error("expected a closing backtick") }
        }
    }

    /// `${ … }` with a substitution inside, which the lexer splits: up to the piece ending in `}`.
    private func expansion() {
        node(K.expansion) {
            bump()
            while let token = cur, token.location == lastEnd {
                if token.kind == .lexeme, token.scope == "variable.other", text(token).hasSuffix("}") {
                    bump()
                    return
                }
                if !wordPiece(token) { bump() }
            }
        }
    }

    private func processSubstitutionAhead(_ token: SyntaxToken) -> Bool {
        (isSymbol(token, "<") || isSymbol(token, ">")) && unit(at: token.end) == 40
    }

    /// `<( … )` or `>( … )`.
    private func processSubstitution() {
        guard !tooDeep() else { return }
        node(K.processSubstitution) {
            bump()
            bump()
            let outer = inBacktick
            inBacktick = false
            list()
            inBacktick = outer
            closeParen()
        }
    }
}
