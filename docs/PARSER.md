# Parser layer

Lexer grammars ([GRAMMAR.md](GRAMMAR.md)) give every language instant, linear highlighting. Languages where
context changes what a token means get a parser on top ([bundled parsers](#bundled-parsers)). It's hand-written recursive descent that builds a
lossless syntax tree, which highlight queries then use to refine scopes. This file covers the core the
parsers share, from tokens to incremental reparsing.

## Tokens

`Highlighter.syntaxTokens` is the stream a parser reads. It is the lexer's tokens, with the gaps
between them filled. Parsers never run a second tokenizer.

| Kind | What |
|------|------|
| `lexeme` | A token the lexer scoped; `scope` names it (`keyword`, `string.quoted`, `comment.line`…). Punctuation-scoped tokens are split one per character, because the lexer merges runs like `]}],`. |
| `word` | An unscoped run of the grammar's `wordCharacters`, or of any non-ASCII character: identifiers. |
| `symbol` | One unscoped character that isn't a word character or a space: operators and brackets. |
| `space` | A run of spaces and tabs. |
| `newline` | `\n`, `\r` or `\r\n`. |

The tokens tile the text: every UTF-16 unit is in exactly one, in order. Spaces, line breaks and
comments are **trivia** (`isTrivia`). The stream is rebuilt from the highlighter's per-line state, so it
follows `replaceCharacters`.

## Building a tree

```swift
let builder = TreeBuilder(highlighter: highlighter)
builder.startNode(SyntaxKind("member"))
builder.bump()                 // the key
builder.expect(":")            // consumes it, or records "expected `:`"
parseValue(builder)
builder.finishNode()
let tree = builder.finish()
```

- **Reading:** `current`, `peek(n)`, `at("text")`, `at(scope:)` and `isAtEnd` only ever see
  significant tokens. `at("->")` also matches a run of adjacent tokens that spell it, since
  multi-character operators arrive as one-character symbols; trivia between them never matches. `at` compares whole tokens, so it never matches part of a longer lexeme, and it never matches trivia (`at(" ")`, `at("//")`).
- **Trivia:** trivia before a consumed token goes into the node that is open at the time. A node starts
  at its first significant token, so the trivia in front of it stays with its parent.
- **Left-associative operators:** take a `checkpoint()` before the left operand, then
  `startNode(kind, at: checkpoint)` wraps everything parsed since then, as rowan does. Trivia in front
  of the checkpoint stays outside the wrapper. Taking a checkpoint changes nothing in the tree, so one
  you never use costs nothing. A checkpoint is valid only in the node it was taken in, while that node
  is open; using it anywhere else stops the program.
- **Losslessness:** `finish()` puts every token the parser didn't consume into the root, so walking the
  leaves always gives the text back, even after a parser bug or an early stop.

`TreeBuilder(tokens:text:)` requires tokens that tile the text, as `syntaxTokens` does, and stops the program otherwise.

`SyntaxTree` is immutable and `Sendable`. `SyntaxNode` is a cheap handle that gives `kind`, `range`
(UTF-16), `text`, `parent`, `children`, `childNodes` and `tokens`. Kinds are names
(`SyntaxKind("call")`) that each parser declares, and highlight queries match on those names.

## Lines and indentation

Trivia never reaches a parser, so a language where line breaks or indentation are syntax asks the
builder about them:

| Member | Gives |
|--------|-------|
| `indentation(of: token)` | The spaces and tabs in front of `token` when it starts a fresh line: first on its line, and the line doesn't continue a token from the one before (a multi-line string). `nil` otherwise. It reads the text, so it works on a block reparse's first token too. |
| `previous` | The last significant token added to the tree: what the line before the next token ended with. |
| `isAtBlockEnd` | In a block reparse, whether every token of the block is consumed; always `false` in a whole parse. See [below](#when-a-block-is-enough). |

## Highlight queries

Highlight queries are data that map tree patterns (a node kind, a child's position, its ancestors,
a token's text or lexer scope) to scopes. They only give existing tokens a new scope, so they never
re-tokenise. Format v1 is specified in [QUERIES.md](QUERIES.md).

## Errors and recovery

A parser never throws or stops at bad input. It records an error, wraps what it can't place in an
`error` node and carries on, so one typo costs the highlighting of one construct, not the rest of the
file. Errors are in `tree.errors`, in the order found. Each one's range is the significant token the
parser was looking at, or an empty range at the end of the text.

| Call | Does |
|------|------|
| `error("message")` | Records an error and consumes nothing. |
| `expect(")")` | Consumes `)` if it comes next; otherwise records "expected `)`" and consumes nothing. |
| `errorAndBump("message")` | Records an error and wraps the next significant token in an `error` node. |
| `recover("message", until: [";"])` | Records an error, then wraps everything up to the next `;` in an `error` node. |

`recover` skips `( )`, `[ ]` and `{ }` whole, so a `;` inside brackets doesn't stop it. It also never
consumes a closing bracket it didn't open, because that bracket belongs to an enclosing construct: a
block's statement loop gets its `}` back, even from `{ a ( b }` where the `(` is never closed. (A
closer for an outer bracket it did open closes the unclosed ones inside it.) At a stop token, a closing bracket or the end, it records
the error and skips nothing. So a loop that calls it must also handle a stray closing bracket itself,
usually with `errorAndBump`, or it makes no progress.

**A stuck parser stops.** After `TreeBuilder.maxStall` (4096) lookahead calls with nothing consumed,
the builder records "the parser stopped making progress here" and reads as at the end from then on.
A loop that never advances terminates, and `finish()` still puts every token in the tree.

**Nesting.** `depth` counts the open nodes. A recursive parser checks it and stops nesting (recording
an error) before its own call stack runs out on input like 100,000 `[`.

## Re-lexing

The lexer guesses context from the previous character: in JS, `/` after `)` reads as division. The
parser knows better. After `if (x)`, an expression starts, so that `/` opens a regex. `relex(as:)`
tells the lexer to read the next significant token starting with another grammar state's rules:

```swift
if builder.at("/"), expressionStarts { builder.relex(as: "regexStart") }
```

The grammar declares the state, like any other:

```json
"regexStart": { "rules": [{ "match": { "literal": "/" }, "scope": "string.regexp", "push": "regex" }] }
```

At that token, the lexer tries the state's rules before its current state's. Pushes and pops act on
the real stack. The lexer re-scans from the start of the line until its state matches what it had
before, which is usually the same line. The tokens the parser hasn't consumed yet are replaced.
`relex` returns `false` and changes nothing when:

- the builder has no highlighter, or the parser is at the end (or stuck),
- the grammar has no such state,
- none of the state's rules match at the token,
- the lexer doesn't start a step there, like the `>` of a `=>` it matched in one step,
- or the parse has used its budget, about four re-scans of the whole text. A request that is refused
  after the lexer looked still counts against it.

The budget keeps a hostile file linear. A real file needs a handful of re-lexes.

Re-lexing applies to the host grammar only, not to grammars embedded in it. A re-lexed token that
turns out to be trivia (a comment) is skipped like any other.

**Applying it to the highlight.** The tree carries the lexing it ended with.
`highlighter.applyRelexing(of: tree)` makes the highlight match the tree and returns the ranges to
re-colour. Every parse starts from the lexer's own reading, so a token the previous parse re-lexed
and this one didn't goes back to normal. Edits move re-lexed tokens with their text, and drop one when
the edit replaces its first character. A tree from an older revision or another highlighter isn't
applied: `applyRelexing` returns `nil`.

## Off the main thread

`highlighter.snapshot` is a `Sendable` copy of the text and its lexing. Parse it anywhere with
`TreeBuilder(snapshot:)`, then hand the tree back to the highlighter's thread for `applyRelexing`:

```swift
let snapshot = highlighter.snapshot
let tree = await Task.detached { parse(TreeBuilder(snapshot: snapshot)) }.value
if let changed = highlighter.applyRelexing(of: tree) { recolour(changed) }
```

## Incremental reparsing

After an edit, a parser reparses only the smallest block around it, and the result is exactly the
tree a whole parse would build. A language opts in with `IncrementalParser`:

```swift
struct SwiftParser: IncrementalParser {
    var reparseBoundaries: Set<SyntaxKind> { [codeBlock, arrayLiteral] }
    func parse(_ builder: TreeBuilder) { /* the whole file */ }
    func parseBlock(_ kind: SyntaxKind, _ builder: TreeBuilder) { /* one `kind` node, from its first token */ }
}

let result = parser.reparse(oldTree, after: highlighter.edit(since: oldTree.textRevision)!, in: highlighter.snapshot)
result.tree        // the new tree
result.changed     // the node that was rebuilt: re-run highlight queries on just this
```

A **reparse boundary** is a node kind whose parse depends only on its own tokens: a `{ }` body, an
array literal. `parseBlock` must parse one such node exactly as `parse` would have, whatever is
around it, and must start it with `startNode(kind)`, not at a checkpoint.

`Highlighter.edit(since:)` folds the edits since a revision into one `TextEdit`: the range it replaced in
the old text and how long the new text is. It remembers the last 1024 edits.

### When a block is enough

The reparse walks from the innermost node around the edit outwards and takes the first boundary
where every one of these holds. If none does, it parses the whole text.

- The edit is strictly inside the block: its first and last tokens (`{` and `}`) are untouched and
  lex the same. Typing just before `{` or just after `}` belongs to the enclosing block.
- Lookahead before the block started read no further than its first token, so the parse leading up
  to it decided nothing from the edited text.
- The block's parse ends exactly at its old last token and never looks past it. Inserting a stray
  `}` ends the block early, and an extra `[` in a list takes its `]` and reads on, so both fall back. An
  unclosed `(` that recovery closes at the list's `]` stays inside it.
- The lexer agrees about what follows: the rest of the block's last line lexes as before, and that
  line hands the next one the same state. Opening a string that runs past the block falls back.
- Re-lexing stays inside: the block's own requests re-scan no line past its last, no request made
  outside it re-scanned the edited text, and the whole parse stays inside its re-lex budget.

A block that ends at a token outside it, as a Python suite ends at the first line indented less,
can't look at that token in a reparse: looking past the block falls back. Where only that token's
line decides whether the block goes on, the parser asks `isAtBlockEnd` first. The block ended there
before and what follows is unchanged, so the line after it ends it again; if the block's parse now
wants to read on (an unclosed bracket), it looks, and falls back.

Then everything after the block parses as before, so its nodes are moved by the edit's length, not
rebuilt. The tree stores what the checks need on each node (its depth, how far lookahead had read,
the errors and re-lex requests made inside it), so they cost the block, not the file.

**Cost.** Parser work is proportional to the block: a one-line edit in a 2,000-block file does
about 1/1000 of a whole parse's lookahead. Splicing the subtree in copies the tree's flat tables
and moving the offsets after it is linear in the file, but that is memory work, far cheaper than parsing.

### Parsing in the background

`ParseSession` keeps a tree for a highlighter, parsing on a background task:

```swift
let session = ParseSession(highlighter: highlighter, parser: SwiftParser())
session.onUpdate = { update in
    recolour(update.relexed)                   // re-lexing the tree asked for, already applied
    rerunQueries(on: update.changed)           // the rebuilt block, or the root
}
highlighter.replaceCharacters(in: range, with: text)
session.textDidChange()
```

`textDidChange()` takes a `Sendable` snapshot, cancels the parse that is running, and starts one
that covers every edit since the last published tree. A result is published, on the main actor, only if
it is the newest parse and the text is still the revision it was parsed from. Anything older is
dropped, never applied over newer text.

#### Cancelling

A parse is cancelled when a newer `textDidChange()` supersedes it, when the host calls `cancel()`
(the editor is closing), and when the session is released. A cancelled parse never publishes, and
the tree stays the last one published, so the next `textDidChange()` covers every edit since it.

Cancelling is cooperative, and lives in `TreeBuilder`, so every parser gets it without code of its
own. Every token a parser looks at or consumes goes through the builder's lookahead, which checks
`Task.isCancelled` on its first call and then once every 1,024 calls. Once it is set, the builder
reads as at the end of the text: the parser's loops end and its recursion unwinds as it would at
the end of a file, a few steps for each node still open. A re-lex request reads as
refused, so nothing is re-scanned. The check never blocks, takes no lock and allocates nothing.

So a cancelled parse stops within a bounded amount of parser work, whatever the file's size. What
is left is linear memory work: `finish()` puts the tokens not yet read into the root, so even a
cancelled tree is lossless. A block reparse checks between its attempts and, cancelled, doesn't
fall back to a whole parse: the parser isn't started again. The tests cancel each bundled
parser partway through a large file and count the lookahead it took after noticing.

## Bundled parsers

`LanguageSupport` pairs a language's parser with its highlight queries (`Queries/<grammar>.json`):

```swift
let tokens = LanguageSupport.highlight(text, grammar: try Grammar.bundled("swift"))  // lex, parse, re-lex, refine
let swift = LanguageSupport.bundled(for: "swift")!   // nil for a lexer-only language
let session = ParseSession(highlighter: highlighter, parser: SwiftParser())
```

`LanguageSupport.highlight` falls back to the lexer for a language without a parser. The fixture
tests go through it, so a language's `.expected` files show what an app would draw.

CSS and HTML are lexer-only. Every construct either has a fixed opener (`@`, `.`, `#`, `[`, `<`,
`</`, `<!--`) or is told apart by the state it's in, so the lexer already scopes it from local
context. The one ambiguity, a declaration versus a nested selector inside a style block, is settled
by looking ahead for a `{` on the line; a parser would only add the rare case of a selector list
split across lines. See [Known limits](GRAMMAR.md#known-limits).

PHP is lexer-only too. Its fixtures needed no context the lexer lacks: casts, `?->`, `::class`, `fn`,
`match`, enum cases, attributes and named arguments all have a local shape, and heredoc markers are
remembered delimiters. What a parser could add is small (a `goto` label versus a named argument, a
lower-case class name), so it isn't worth a second tokenizer's worth of code.

### Swift

`SwiftParser` reads declarations (with generics, `where` clauses, attributes and modifiers),
statements, expressions by operator precedence, closures and trailing closures, key paths, string
interpolation, patterns and types. Its queries refine:

| What | Scope |
|------|-------|
| A declared type, generic parameter, `typealias` or `associatedtype` | `entity.name.type` |
| A declared function, operator or macro | `entity.name.function` |
| A parameter's label and name, an argument label | `variable.parameter` |
| A declared variable, property or pattern binding | `variable.other` |
| An enum case, declared or as `.member` | `variable.other.enummember` |
| The function called: `f(…)`, `a.f(…)`, `f { … }` | `support.function` |
| A contextual keyword used as a name (`let some = 1`) | `variable.other`, or its role above |
| A lowercase name in a type position | `entity.name.type` |

It re-lexes `t.0.1` as two tuple indices, a `/` right after a postfix `!` or `?` as division, and
the `/` in an operator's name as an operator character (`infix operator /+/`).

Its reparse boundaries are code blocks, type and extension bodies, accessor blocks and closures.
Each resets every flag the parse carries at its `{`, so it parses the same anywhere. Whether a `{`
starts a trailing closure (not in an `if` condition, not before a variable's `willSet`) is decided
without looking past it.

Nesting stops at 64 open nodes, or sooner when less than 160 KB of the thread's stack is left (a
debug build's frames are several times a release build's). The rest of that construct goes into
an `error` node and keeps the lexer's colours.

### JavaScript and TypeScript

One parser reads both, and JSX and TSX ([below](#jsx-and-tsx)). The TypeScript dialect adds types, interfaces, enums, namespaces, `declare`,
generics, `as`/`satisfies`, `!`, access modifiers and decorators; declaration files are the same grammar.

Its reparse boundaries are statement blocks, class bodies, object literals, switch bodies, object
types and enum bodies. None of them depends on anything around its `{`: flags like `in` being an
operator are arguments, reset inside brackets.

**Re-lexing.** Three grammar states exist only for the parser's requests. `regexStart` re-reads a `/`
where an operand starts as a regex (`if (ok) /x/.test(s)`, where the lexer saw `)`); `divisionStart`
re-reads a regex the lexer started where an operator belongs as division (`total\n  / count`,
`` `${a}` / 2 ``, `i++ / 2`); `identifierStart` re-reads a contextual keyword used as a name, because the
lexer matches `of /` as a keyword and a regex in one step (`const half = of / 2`). TypeScript needs
no re-lexing for generics: `<` and `>` arrive as one-character symbols, so `f<T>(x)` versus `a < b` is the
parser's decision alone, and `Map<K, Array<V>>` closes one `>` at a time.

**Lookahead.** Whether `(` starts an arrow function's parameters, and whether `<` starts type
arguments, is decided by a scan of at most 256 tokens that gives up at anything a parameter list or a
type can't hold. A parameter list too long for the scan still parses: `(…)` followed by `=>` becomes an
arrow function after the fact.

**Names** are wrapped in a node of their own, so the queries colour them by role:

| Node | What | Scope |
|------|------|-------|
| `function_name`, `method_name` | `function f`, `f() {}` in a class or object | `entity.name.function` |
| `type_name` | a declared class, interface, type alias, enum, namespace or type parameter | `entity.name.type` |
| `type_identifier` | a type used in TypeScript (`x: Foo`) | `entity.name.type` |
| `property_name` | an object key, class field, enum member, interface property, tuple label | `support.type.property-name` |
| `binding`, `identifier` | a declared name (variable, parameter, import), a name used as a value | `variable.other` |
| `label` | `outer:` and `break outer` | `variable.other` |
| `decorator` | `@name`, `@a.b(…)` | `entity.other.attribute` |

A contextual keyword in one of these positions (`get`, `of`, `type`, `async`…) takes the position's
scope, so `a ? get : set` and `{ default: 1 }` aren't keywords; a capitalised name keeps the lexer's
`entity.name.type`. In TypeScript, `void` as an operator (`void 0`) is a keyword, and a primitive type's
name used as a value (`const string = 1`) is a variable.

**Depth.** Constructs nest at most 200 nodes deep (`JSParse.maxDepth`): deeper, the parser records an
error and stops nesting, so a parse fits a background thread's 512 KB stack even in a debug build.

### JSX and TSX

The `jsx` and `tsx` languages (`.jsx`, `.tsx`) are the JavaScript and TypeScript parser in its JSX
dialects (`JSParser(dialect: .jsx)`, `.tsx`). Their grammars are `javascript.json` and
`typescript.json` plus JSX states ([GRAMMAR.md](GRAMMAR.md#jsx-and-tsx)).

**Deciding `<`.** Where an expression starts, `<` opens an element; after an operand it is a
comparison, or in TSX type arguments (`f<T>(x)`). The lexer guesses from the character before it,
as it does for a regex: an element after `(`, `=`, `=>`, `,`, `?`, `:`, `{`, `&&`, a line start or
`return`, and not after a name, a number, `)`, `]` or a quote. The parser corrects a wrong guess
with a re-lex request: `jsxStart` reads a `<` as an element's, `jsxLessThan` as the operator (in
`total\n  <limit`, or a type such as `type F = <T>(x: T) => T`). In TSX there are no `<T>x`
assertions, so `<T>…` where an expression starts is always an element, while `<T,>(x) =>` and
`<T extends U>(x) =>` are generic arrows; the lexer leaves those two alone. `.js` and `.ts` are
unchanged.

**Elements.** Elements and fragments (`<>…</>`), self-closing tags, intrinsic names (`div`,
`my-element`, `svg:rect`), components (`Button`, `Foo.Bar`, `this.Item`), TSX type arguments
(`<List<T> …>`), attributes (string, `{expression}`, `{...spread}`, boolean, `aria-label`,
`xlink:href`), text with entities, and `{expressions}` holding any JS or TS, JSX nested in them
included. Comments go in `{/* */}` or between attributes.

| Node | What | Scope |
|------|------|-------|
| `jsx_tag_name` | an intrinsic element's name: lowercase, dashed or namespaced | `entity.name.tag` |
| `jsx_component_name` | a component's name; `this` in `<this.Item>` is `variable.language` | `entity.name.type` |
| `jsx_attribute_name` | `className`, `aria-label`, `xlink:href` | `entity.other.attribute` |
| `jsx_expression` | its `{` and `}` | `punctuation.section.embedded` |
| `jsx_text` | text between tags, lexed in a JSX state so keywords and quotes in it stay plain | none |

Tags (`jsx_opening_tag`, `jsx_closing_tag`, `jsx_self_closing_tag`) sit in a `jsx_element`. The
lexer scopes their `<`, `/` and `>` as `punctuation` and entities (`&amp;`, `&#169;`, `&#xA9;`) as
`constant.character.escape`.

**Recovery.** The lexer's stack holds a state per open element, so a broken element would make it
read the rest of the file as JSX. The parser ends the element, records an error, and re-lexes the
next token after popping the element's states (`jsxPop1`…`jsxPop32`), so what follows is code again.
Pops asked for at the same token add up (a tag broken at a `}`, then the elements the `}` ends). So
that every pop fits, a root nests at most 31 elements: a `<` deeper than that is re-lexed as text,
with an error. The cases:

- A tag that meets anything an attribute can't start with (`<div className=` and a `}`) ends there.
- A quoted value that runs past its line and holds `<`, `>`, `{`, `}` or `=`, or doesn't close,
  is a quote left open: it ends at the line end (`jsxLineString`). A long `className` spanning
  lines still parses.
- A `}` in text can't be JSX, so the root's open elements end before it, and it closes the block.
- A closing tag naming an outer element (`<div><p>x</div>`) closes the ones inside it; one that
  names nothing open closes the innermost.
- Where an expression starts, a `<` the lexer left as an operator opens an element only when a
  name or `>` follows it directly: `< b` is a comparison being typed, not `<b`.

**Cost.** A re-lex re-scans from its line until the lexer's state meets the old reading, so a
correct guess costs nothing and a wrong one usually its element's lines. One the old reading never
meets again (an element left open) re-scans to the end of the file. The re-lex budget keeps that
linear: past it, later elements keep the lexer's guess.

### Shell

`ShellParser` reads POSIX sh and bash: simple commands with their assignments and redirections,
pipelines (`|`, `|&`, `!`, `time`, `coproc`), `&&`/`||` lists, every compound command (`{ }`, `( )`,
`if`, `while`, `until`, `for`, `select`, `case`, `(( ))`, `[[ ]]`), both forms of function
definition, `$( )`, backticks, `<( )`, `${ }`, `$(( ))` and heredoc bodies, which it reads after the
line their operator is on. It knows **command position**, so a reserved word is a keyword only where
a command starts, and it re-lexes keywords and builtin names in an argument as plain words: in
`echo if then done`, only `echo` is coloured. Its queries refine:

| What | Scope |
|------|-------|
| A builtin used as a command (`echo`, `cd`, `[`, `.`) | `support.function`; `local`, `export`, `return`… keep `keyword` |
| Any other command name (`ls`, `./configure`, `git-lfs`) | `entity.name.function` |
| A declared function's name, `my-tool::run` included | `entity.name.function` |
| A variable assigned, or named by `for`, `select`, `read`, `export`, `local`, `declare`, `unset`, `getopts`, `mapfile`, `printf -v`; a name in `(( ))` | `variable.other` |
| An option: `-x`, `--flag` (not its `=value`), `--` | `variable.parameter` |
| A `case` pattern, the regex after `=~` | `string.regexp` |
| A test operator in `[[ ]]`: `-f`, `==`, `&&`, `!` | `keyword` |

It also re-lexes the `)` ending a `case` pattern inside `$( )`, which the lexer takes for the
substitution's end; a `<<` shift in `$(( ))` or `(( ))`, which the lexer takes for a heredoc; and a
`<<\EOF` heredoc, which the lexer doesn't recognise.

Its reparse boundaries are the compound commands and `$( )`, so a function body is one. Whether a
token starts one is decided from the token and the character after it, never from lookahead, and
`parseBlock` decides it again, so an edit that changes the decision falls back. Inside backticks, or
on a line whose heredoc bodies are still to come, a compound command gets a twin kind
(`braceGroupInContext`…) that isn't a boundary, because its parse depends on what is around it.
Editing a heredoc's delimiter re-lexes the lines after it, so the lexer check sends that edit to a
bigger block or a whole parse.

Nesting stops at 64 open nodes, or sooner when less than 160 KB of the thread's stack is left.

### Python

`PythonParser` covers Python 3 up to 3.14, except template strings (`t"…"`), which the lexer
doesn't know yet: definitions with decorators, PEP 695 type parameters and `type`
aliases, every statement including `match` with its patterns, the full expression grammar with
lambdas, comprehensions, `:=` and star arguments, annotations, and f-string replacement fields with
their conversions and format specs.

- **Logical lines.** A token that starts a line ends the logical line, unless brackets are open or a
  backslash continues it. A line break inside a multi-line string or f-string field isn't a line
  start at all. Indentation opens and closes `block` nodes; a tab counts to the next multiple of 8.
- **Recovery.** Inside brackets, a keyword that only starts a statement (`def`, `return`, `elif`…)
  at the start of a line ends them, as does a line no deeper than the statement's when the line
  before didn't end in a comma, operator or opening bracket. So a half-typed `f(1, 2` costs its
  own statement, not the rest of the file. A missing `:` or `)` is reported and the block after
  it still parses.
- **Soft keywords.** `match` starts a match statement only when its logical line ends in `:` (a header too long
  to scan, past 2048 tokens, goes by the lexer's reading);
  `case` only in a match block; `type` only before a name and `=` or `[`; `_` is a keyword only as
  a wildcard pattern. A `match` or `case` the lexer took for a keyword elsewhere is re-lexed as a
  name (state `softKeywordName`), as are builtins and `self` after a `.` (`identifier`), and `@b`
  in `a @b` (`matmulOperator`).
- **Reparse boundaries:** `block` (an indented suite) and `case_block` (a match statement's cases).
  An edit to a block's first or last line, or one that moves the line after it, reparses the
  block around it.
- **Queries** colour function, class, alias and type-parameter names; parameters and keyword
  argument names (`variable.parameter`, as in Swift), with `self` and `cls` kept; decorators; names in annotations
  and type positions (`entity.name.type`); a builtin bound by an assignment, `for`, `as` or
  parameter as a variable; format specs as string text.
